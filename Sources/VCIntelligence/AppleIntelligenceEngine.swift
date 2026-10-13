import Foundation
import FoundationModels
import VCModels

/// On-device engine on Apple's system language model (guided generation).
///
/// Every request uses a fresh `LanguageModelSession`, so calls are independent and can run concurrently.
/// The model's context window is small (4,096 tokens on macOS 26), so reports over long transcripts are
/// built map-reduce: notes per transcript chunk, then merges of those notes until one set remains.
/// Whenever the model reports that a request overflowed its window, the request is shrunk and retried.
public final class AppleIntelligenceEngine: MeetingIntelligence {
    /// Upper bound for transcript tokens (estimated by `TokenEstimator`) in one report request.
    static let maximumTranscriptBudget = 2_000
    /// Tokens kept free for the answer of a report or merge request.
    static let reportResponseReserve = 1_200
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

    public static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    public static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            nil
        case .unavailable(.deviceNotEligible):
            "This Mac does not support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            "Apple Intelligence is turned off. Turn it on in System Settings › Apple Intelligence & Siri."
        case .unavailable(.modelNotReady):
            "The Apple Intelligence model is still downloading or preparing. Try again later."
        case .unavailable:
            "Apple Intelligence is not available right now."
        }
    }

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

    public func report(transcript: [ContextLine], participants: [String], meetingTitle: String?) async throws -> MeetingReport {
        try Self.requireAvailable()
        let participants = TranscriptFormatter.speakingParticipants(participants, transcript: transcript)
        let notes: RawReport
        if transcript.isEmpty {
            notes = RawReport(overview: "No speech was transcribed.")
        } else {
            let budget = await transcriptBudget()
            notes = try await reportNotes(
                transcript: transcript, participants: participants, meetingTitle: meetingTitle,
                budget: budget, mergeBudget: await windowBudget())
        }
        return ResultAssembler.report(
            from: notes, transcript: transcript, participants: participants, meetingTitle: meetingTitle, generatedBy: engineName)
    }

    /// One pass when the whole transcript fits `budget`, map-reduce otherwise. Lines are numbered over the whole
    /// meeting so every request cites the same `L` numbers. `mergeBudget` bounds the notes sent to one merge
    /// request; it comes from the context window, not from the transcript budget.
    func reportNotes(
        transcript: [ContextLine], participants: [String], meetingTitle: String?, budget initialBudget: Int, mergeBudget: Int
    ) async throws -> RawReport {
        var budget = initialBudget
        let numbered = NumberedLine.numbering(transcript)
        let lines = TranscriptChunker.splitLongLines(numbered, maxTokens: max(Self.minimumTranscriptBudget / 2, budget / 2))
        if lines.reduce(0, { $0 + TranscriptChunker.defaultCost($1) }) <= budget {
            let prompt = IntelligencePrompts.reportPrompt(transcript: lines, participants: participants, meetingTitle: meetingTitle)
            do {
                return try await Self.generate(GenNotes.self, instructions: IntelligencePrompts.reportInstructions, prompt: prompt).raw
            } catch let error where Self.isContextOverflow(error) {
                budget = try Self.shrunk(budget)
            }
        }
        let parts = try await partNotes(numbered, participants: participants, meetingTitle: meetingTitle, budget: budget)
        return try await merged(parts, participants: participants, meetingTitle: meetingTitle, budget: max(mergeBudget, budget))
    }

    /// Map step: notes for consecutive chunks. A chunk that overflows is retried smaller; finished parts are kept.
    func partNotes(_ transcript: [NumberedLine], participants: [String], meetingTitle: String?, budget initialBudget: Int) async throws -> [RawReport] {
        var budget = initialBudget
        var remaining = TranscriptChunker.splitLongLines(transcript, maxTokens: max(Self.minimumTranscriptBudget / 2, budget / 2))[...]
        var parts: [RawReport] = []
        while !remaining.isEmpty {
            let chunks = TranscriptChunker.chunk(Array(remaining), tokenBudget: budget)
            let chunk = chunks[0]
            let prompt = IntelligencePrompts.reportPrompt(
                transcript: chunk, participants: participants, meetingTitle: meetingTitle,
                part: (index: parts.count, count: parts.count + chunks.count))
            do {
                parts.append(try await Self.generate(GenNotes.self, instructions: IntelligencePrompts.partNotesInstructions, prompt: prompt).raw)
                remaining = remaining.dropFirst(chunk.count)
            } catch let error where Self.isContextOverflow(error) {
                budget = try Self.shrunk(budget)
                remaining = TranscriptChunker.splitLongLines(Array(remaining), maxTokens: max(Self.minimumTranscriptBudget / 2, budget / 2))[...]
            }
        }
        return parts
    }

    /// Reduce step: merges notes in groups that fit `budget` until a single set remains. Notes too large to
    /// share a request are compacted first; a merge that overflows is retried on compacted notes.
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
                return try await Self.generate(GenNotes.self, instructions: IntelligencePrompts.mergeNotesInstructions, prompt: prompt).raw
            } catch let error where Self.isContextOverflow(error) {
                let smaller = group.map { ReportNotes.compacted($0) }
                guard smaller.contains(where: { $0 != nil }) else { throw IntelligenceError.contextWindowExceeded }
                group = zip(group, smaller).map { $1 ?? $0 }
            }
        }
    }

    // MARK: Budgets

    /// Transcript tokens per report request: the window-derived budget unless an override forces smaller requests.
    func transcriptBudget() async -> Int {
        if let transcriptBudgetOverride { return transcriptBudgetOverride }
        return await windowBudget()
    }

    /// Input tokens one report or merge request can carry: what the window leaves after instructions, schema and answer.
    func windowBudget() async -> Int {
        let model = SystemLanguageModel.default
        var overhead = TokenEstimator.estimate(IntelligencePrompts.reportInstructions) + 900
        if #available(macOS 26.4, *) {
            if let instructions = try? await model.tokenCount(for: Instructions(IntelligencePrompts.partNotesInstructions)),
                let schema = try? await model.tokenCount(for: GenNotes.generationSchema)
            {
                overhead = instructions + schema + 100
            }
        }
        let available = model.contextSize - overhead - Self.reportResponseReserve
        return min(Self.maximumTranscriptBudget, max(Self.minimumTranscriptBudget, available))
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

    private static func generate<Content: Generable>(_ type: Content.Type, instructions: String, prompt: String) async throws -> Content {
        let session = LanguageModelSession(instructions: instructions)
        do {
            return try await session.respond(to: prompt, generating: type, includeSchemaInPrompt: true, options: generationOptions).content
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
