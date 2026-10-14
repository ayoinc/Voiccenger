import Foundation
import FoundationModels
import VCModels

/// On-device engine on Apple's system language model (guided generation).
///
/// Every request uses a fresh `LanguageModelSession`, so calls are independent and can run concurrently.
/// The model's context window is small (4,096 tokens on macOS 26), so reports over long transcripts are
/// built map-reduce: notes per transcript chunk, then merges of those notes until one set remains.
/// Whenever the model reports that a request overflowed its window, the request is shrunk and retried.
@available(macOS 26.0, *)
public final class AppleIntelligenceEngine: MeetingIntelligence {
    /// Upper bound for transcript tokens in one notes request (summary or lists).
    static let maximumTranscriptBudget = 2_000
    /// Tokens kept free for the answer of a summary request (detailed overview, topics, participants).
    static let summaryResponseReserve = 1_300
    /// Tokens kept free for the answer of a lists request.
    static let listsResponseReserve = 1_100
    /// Tokens kept free for the answer of a merge request (title, up to eight topics, a multi-paragraph overview).
    static let mergeResponseReserve = 1_400
    /// Upper bound for transcript tokens in one outline request: its answer restates every chunk in detail.
    static let maximumOutlineBudget = 1_500
    /// Tokens kept free for the answer of an outline request (four segments of six points).
    static let outlineResponseReserve = 1_500
    /// Upper bound for recent-context tokens in one live-analysis request.
    static let maximumContextBudget = 1_200
    /// Below this, a report request cannot carry enough transcript to be worth sending.
    static let minimumTranscriptBudget = 250

    private let transcriptBudgetOverride: Int?

    public var engineName: String { "Apple Intelligence (on-device)" }

    public init() {
        transcriptBudgetOverride = nil
    }

    /// `transcriptTokenBudget` forces the per-request transcript size (exercises map-reduce on short transcripts).
    init(transcriptTokenBudget: Int) {
        precondition(transcriptTokenBudget >= Self.minimumTranscriptBudget, "budget below minimum")
        transcriptBudgetOverride = transcriptTokenBudget
    }

    public static var isAvailable: Bool { AppleIntelligenceStatus.current.isAvailable }

    public static var unavailableReason: String? { AppleIntelligenceStatus.current.reason }

    private static var generationOptions: GenerationOptions {
        // The macOS 27 SDK (Swift 6.4) renamed `sampling:` to `samplingMode:`.
        #if compiler(>=6.4)
        GenerationOptions(samplingMode: .greedy)
        #else
        GenerationOptions(sampling: .greedy)
        #endif
    }

    // MARK: Live analysis

    public func analyze(utterance: ContextLine, recentContext: [ContextLine]) async throws -> UtteranceInsight {
        try Self.requireAvailable()
        var budget = Self.maximumContextBudget
        while true {
            let context = budget > 0 ? TranscriptChunker.tail(recentContext, tokenBudget: budget) : []
            let prompt = IntelligencePrompts.analysisPrompt(utterance: utterance, recentContext: context)
            do {
                let insight = try await Self.generate(GenInsight.self, instructions: IntelligencePrompts.analysisInstructions, prompt: prompt)
                return ResultAssembler.insight(from: insight.raw, utterance: utterance, context: context)
            } catch let error where Self.isContextOverflow(error) {
                // Less context first; an utterance that does not fit even alone cannot be analysed.
                guard !context.isEmpty else { throw IntelligenceError.contextWindowExceeded }
                budget = budget >= 200 ? budget / 2 : 0
            }
        }
    }

    // MARK: Report

    /// The report in three kinds of requests over the transcript, run side by side: the summary (title, overview,
    /// topics, participants) and the lists (decisions, action items and the rest) — one request each, or per chunk
    /// and then merged — and the conversation outline, one request per chunk, every chunk's outline kept as written.
    public func report(transcript: [ContextLine], participants: [String], meetingTitle: String?) async throws -> MeetingReport {
        try Self.requireAvailable()
        let participants = TranscriptFormatter.speakingParticipants(participants, transcript: transcript)
        var notes: RawReport
        if transcript.isEmpty {
            notes = RawReport(overview: "No speech was transcribed.")
        } else {
            let budget = await transcriptBudget()
            let mergeBudget = await mergeBudget()
            let outlineTokens = await outlineBudget()
            async let written = reportNotes(
                transcript: transcript, participants: participants, meetingTitle: meetingTitle,
                budget: budget, mergeBudget: mergeBudget)
            async let outlined = outline(
                NumberedLine.numbering(transcript), participants: participants, meetingTitle: meetingTitle, budget: outlineTokens)
            notes = try await written
            notes.outline = try await outlined
        }
        return ResultAssembler.report(
            from: notes, transcript: transcript, participants: participants, meetingTitle: meetingTitle, generatedBy: engineName)
    }

    /// Notes in one pass when the whole transcript fits `budget`, map-reduce otherwise: notes per chunk, then the
    /// parts' summaries (title, overview, topics) merged by the model while their lists and participant points are
    /// joined as they are. Lines are numbered over the whole meeting so every request cites the same `L` numbers.
    /// `mergeBudget` bounds the summaries sent to one merge request; it comes from the context window, not from
    /// the transcript budget.
    func reportNotes(
        transcript: [ContextLine], participants: [String], meetingTitle: String?, budget initialBudget: Int, mergeBudget: Int
    ) async throws -> RawReport {
        var budget = initialBudget
        let numbered = NumberedLine.numbering(transcript)
        let lines = TranscriptChunker.splitLongLines(numbered, maxTokens: max(Self.minimumTranscriptBudget / 2, budget / 2))
        if await Self.fits(lines, budget: budget) {
            do {
                return try await notes(lines, participants: participants, meetingTitle: meetingTitle, part: nil)
            } catch let error where Self.isContextOverflow(error) {
                budget = try Self.shrunk(budget)
            }
        }
        let parts = try await partNotes(numbered, participants: participants, meetingTitle: meetingTitle, budget: budget)
        let summary = try await merged(parts.map(ReportNotes.summary), participants: participants, meetingTitle: meetingTitle, budget: mergeBudget)
        return ReportNotes.joined(parts, summary: summary)
    }

    /// Notes on `lines` (the meeting, or `part` of it) from a summary request and a lists request, run side by side.
    /// The overview has two to four paragraphs for a whole meeting with substance, one or two for a part (the merge
    /// writes the meeting's), and one for a thin meeting.
    func notes(_ lines: [NumberedLine], participants: [String], meetingTitle: String?, part: (index: Int, count: Int)?) async throws -> RawReport {
        let prompt = IntelligencePrompts.reportPrompt(transcript: lines, participants: participants, meetingTitle: meetingTitle, part: part)
        let paragraphs: ClosedRange<Int> =
            (part?.count ?? 1) > 1 ? 1...2 : ReportShape(Grounding.substance(lines.map(\.line))).isThin ? 1...1 : 2...4
        async let summary = Self.generate(
            GenSummary.self, schema: GenSummary.schema(paragraphs: paragraphs), instructions: IntelligencePrompts.summaryInstructions, prompt: prompt)
        async let lists = Self.generate(GenLists.self, instructions: IntelligencePrompts.listsInstructions, prompt: prompt)
        let (written, listed) = try await (summary, lists)
        return listed.notes(with: written)
    }

    /// Outline map step: the outline of each consecutive chunk, concatenated in order and never merged or
    /// compacted, so a long meeting keeps all its detail. A chunk that overflows is retried smaller.
    func outline(_ transcript: [NumberedLine], participants: [String], meetingTitle: String?, budget initialBudget: Int) async throws -> [RawOutlineSegment] {
        var budget = initialBudget
        var remaining = TranscriptChunker.splitLongLines(transcript, maxTokens: max(Self.minimumTranscriptBudget / 2, budget / 2))[...]
        var segments: [RawOutlineSegment] = []
        var done = 0
        while !remaining.isEmpty {
            let chunks = await Self.fits(Array(remaining), budget: budget)
                ? [Array(remaining)] : TranscriptChunker.balancedChunk(Array(remaining), tokenBudget: budget)
            let chunk = chunks[0]
            let prompt = IntelligencePrompts.reportPrompt(
                transcript: chunk, participants: participants, meetingTitle: meetingTitle, part: (index: done, count: done + chunks.count))
            do {
                segments += try await Self.generate(GenOutline.self, instructions: IntelligencePrompts.outlineInstructions, prompt: prompt).raw
                done += 1
                remaining = remaining.dropFirst(chunk.count)
            } catch let error where Self.isContextOverflow(error) {
                budget = try Self.shrunk(budget)
                remaining = TranscriptChunker.splitLongLines(Array(remaining), maxTokens: max(Self.minimumTranscriptBudget / 2, budget / 2))[...]
            }
        }
        return segments
    }

    /// Map step: notes for consecutive chunks. A chunk that overflows is retried smaller; finished parts are kept.
    func partNotes(_ transcript: [NumberedLine], participants: [String], meetingTitle: String?, budget initialBudget: Int) async throws -> [RawReport] {
        var budget = initialBudget
        var remaining = TranscriptChunker.splitLongLines(transcript, maxTokens: max(Self.minimumTranscriptBudget / 2, budget / 2))[...]
        var parts: [RawReport] = []
        while !remaining.isEmpty {
            let chunks = TranscriptChunker.balancedChunk(Array(remaining), tokenBudget: budget)
            let chunk = chunks[0]
            do {
                parts.append(try await notes(
                    chunk, participants: participants, meetingTitle: meetingTitle, part: (index: parts.count, count: parts.count + chunks.count)))
                remaining = remaining.dropFirst(chunk.count)
            } catch let error where Self.isContextOverflow(error) {
                budget = try Self.shrunk(budget)
                remaining = TranscriptChunker.splitLongLines(Array(remaining), maxTokens: max(Self.minimumTranscriptBudget / 2, budget / 2))[...]
            }
        }
        return parts
    }

    /// Whether `lines` fit `budget` transcript tokens: by the estimate, or else (macOS 26.4 and later) by the
    /// model's own count, since the estimate runs about 20% high and the budget itself comes from exact counts.
    static func fits(_ lines: [NumberedLine], budget: Int) async -> Bool {
        if lines.reduce(0, { $0 + TranscriptChunker.defaultCost($1) }) <= budget { return true }
        if #available(macOS 26.4, *), let exact = try? await SystemLanguageModel.default.tokenCount(for: TranscriptFormatter.format(lines)) {
            return exact <= budget
        }
        return false
    }

    /// Reduce step: merges part summaries in groups that fit `budget` until one remains. Summaries too large to
    /// share a request are compacted first; a merge that overflows is retried on compacted summaries.
    func merged(_ parts: [RawReport], participants: [String], meetingTitle: String?, budget: Int) async throws -> RawReport {
        var level = parts
        while level.count > 1 {
            // Every note at most half the budget, so any two fit together and each level makes progress.
            level = try level.map { try Self.fitted($0, within: budget / 2) }
            var next: [RawReport] = []
            var index = level.startIndex
            while index < level.endIndex {
                var group = [level[index]]
                var used = Self.cost(of: level[index])
                index += 1
                while index < level.endIndex, used + Self.cost(of: level[index]) <= budget {
                    used += Self.cost(of: level[index])
                    group.append(level[index])
                    index += 1
                }
                if group.count == 1 {
                    next.append(group[0])
                } else {
                    next.append(try await merge(group, participants: participants, meetingTitle: meetingTitle))
                }
            }
            level = next
        }
        return level[0]
    }

    private func merge(_ group: [RawReport], participants: [String], meetingTitle: String?) async throws -> RawReport {
        var group = group
        while true {
            let prompt = IntelligencePrompts.mergePrompt(
                renderedNotes: group.map(ReportNotes.render), participants: participants, meetingTitle: meetingTitle)
            do {
                return try await Self.generate(
                    GenSummary.self, schema: GenSummary.mergeSchema, instructions: IntelligencePrompts.mergeSummaryInstructions, prompt: prompt
                ).raw
            } catch let error where Self.isContextOverflow(error) {
                let smaller = group.map { ReportNotes.compacted($0) }
                guard smaller.contains(where: { $0 != nil }) else { throw IntelligenceError.contextWindowExceeded }
                group = zip(group, smaller).map { $1 ?? $0 }
            }
        }
    }

    // MARK: Budgets

    /// Transcript tokens per notes request: the window-derived budget unless an override forces smaller requests.
    func transcriptBudget() async -> Int {
        if let transcriptBudgetOverride { return transcriptBudgetOverride }
        return await windowBudget()
    }

    /// Transcript tokens a summary request and a lists request can both carry: what the window leaves after each
    /// one's instructions, schema and answer.
    func windowBudget() async -> Int {
        let summary = await Self.overhead(IntelligencePrompts.summaryInstructions, GenSummary.generationSchema, estimatedSchema: 470)
            + Self.summaryResponseReserve
        let lists = await Self.overhead(IntelligencePrompts.listsInstructions, GenLists.generationSchema, estimatedSchema: 740)
            + Self.listsResponseReserve
        let available = SystemLanguageModel.default.contextSize - max(summary, lists)
        return min(Self.maximumTranscriptBudget, max(Self.minimumTranscriptBudget, available))
    }

    /// Rendered part summaries one merge request can carry.
    func mergeBudget() async -> Int {
        let overhead = await Self.overhead(IntelligencePrompts.mergeSummaryInstructions, GenSummary.mergeSchema, estimatedSchema: 350)
        let available = SystemLanguageModel.default.contextSize - overhead - Self.mergeResponseReserve
        return min(Self.maximumTranscriptBudget, max(Self.minimumTranscriptBudget, available))
    }

    /// Transcript tokens per outline request: what the window leaves after the outline instructions, schema and
    /// answer, at most `maximumOutlineBudget` (and at most a forced transcript budget).
    func outlineBudget() async -> Int {
        let overhead = await Self.overhead(IntelligencePrompts.outlineInstructions, GenOutline.generationSchema, estimatedSchema: 350)
        let available = SystemLanguageModel.default.contextSize - overhead - Self.outlineResponseReserve
        let budget = min(Self.maximumOutlineBudget, max(Self.minimumTranscriptBudget, available))
        return transcriptBudgetOverride.map { min($0, budget) } ?? budget
    }

    /// Tokens of a request's instructions and schema plus the prompt header: counted by the model on macOS 26.4 and
    /// later, else estimated (`estimatedSchema` is the schema's count measured on macOS 26.4).
    static func overhead(_ instructions: String, _ schema: GenerationSchema, estimatedSchema: Int) async -> Int {
        if #available(macOS 26.4, *) {
            let model = SystemLanguageModel.default
            if let instructionTokens = try? await model.tokenCount(for: Instructions(instructions)),
                let schemaTokens = try? await model.tokenCount(for: schema)
            {
                return instructionTokens + schemaTokens + 100
            }
        }
        return TokenEstimator.estimate(instructions) + estimatedSchema + 100
    }

    private static func shrunk(_ budget: Int) throws -> Int {
        guard budget > minimumTranscriptBudget else { throw IntelligenceError.contextWindowExceeded }
        return max(minimumTranscriptBudget, budget * 2 / 3)
    }

    static func cost(of notes: RawReport) -> Int {
        TokenEstimator.estimate(ReportNotes.render(notes)) + 8
    }

    /// Compacts `notes` until they cost at most `limit`; throws when they cannot shrink that far.
    static func fitted(_ notes: RawReport, within limit: Int) throws -> RawReport {
        var notes = notes
        while cost(of: notes) > limit {
            guard let smaller = ReportNotes.compacted(notes) else { throw IntelligenceError.contextWindowExceeded }
            notes = smaller
        }
        return notes
    }

    // MARK: Model calls

    private static func requireAvailable() throws {
        if let reason = unavailableReason { throw IntelligenceError.unavailable(reason) }
    }

    /// One request in a fresh session, answered in `schema` (by default `Content`'s own).
    private static func generate<Content: Generable>(
        _ type: Content.Type, schema: GenerationSchema = Content.generationSchema, instructions: String, prompt: String
    ) async throws -> Content {
        let session = LanguageModelSession(instructions: instructions)
        do {
            let content = try await session.respond(to: prompt, schema: schema, includeSchemaInPrompt: true, options: generationOptions).content
            return try Content(content)
        } catch {
            throw mapped(error)
        }
    }

    static func isContextOverflow(_ error: any Error) -> Bool {
        if let error = error as? LanguageModelSession.GenerationError, case .exceededContextWindowSize = error { return true }
        #if compiler(>=6.4)
        // macOS 27 reports errors as `LanguageModelError`; the type only exists in its SDK.
        if #available(macOS 27.0, *), let error = error as? LanguageModelError, case .contextSizeExceeded = error { return true }
        #endif
        return false
    }

    /// Context overflow passes through untouched (callers shrink and retry); refusals, guardrails and
    /// missing assets become `IntelligenceError`; anything else is rethrown as is.
    private static func mapped(_ error: any Error) -> any Error {
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal:
                return IntelligenceError.refused(error.errorDescription)
            case .assetsUnavailable:
                return IntelligenceError.unavailable(unavailableReason ?? "The Apple Intelligence model assets are not available.")
            case .unsupportedLanguageOrLocale:
                return IntelligenceError.unavailable("Apple Intelligence does not support this transcript's language.")
            default:
                return error
            }
        }
        #if compiler(>=6.4)
        if #available(macOS 27.0, *), let error = error as? LanguageModelError {
            switch error {
            case .guardrailViolation, .refusal:
                return IntelligenceError.refused(error.errorDescription)
            case .unsupportedLanguageOrLocale:
                return IntelligenceError.unavailable("Apple Intelligence does not support this transcript's language.")
            default:
                return error
            }
        }
        #endif
        return error
    }
}
