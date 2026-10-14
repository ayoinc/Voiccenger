import Foundation
import VCModels

/// Guardrails for one request: the model's standard ones, or the permissive mode a refused request is retried in.
enum ReportGuardrails: Sendable {
    case standard
    case permissive
}

/// One report request and the transcript lines it carries (none for a merge).
struct ReportRequest: Sendable {
    var kind: ReportRequestKind
    var prompt: String
    var lines: [NumberedLine]
    /// Overview paragraphs a summary asks for.
    var paragraphs: ClosedRange<Int>

    /// The `L` numbers the request covers; nil for a merge.
    var span: ClosedRange<Int>? {
        guard let first = lines.first, let last = lines.last else { return nil }
        return first.number...last.number
    }
}

/// The language model a map-reduce report is written with. Answers come as raw notes: a summary fills the title,
/// overview, topics and participants; lists the lists; an outline `outline`; a merge the title, overview and
/// topics. A declined request throws `IntelligenceError.refused`; one too large for the context window throws an
/// error `isContextOverflow` recognises.
protocol ReportModel: Sendable {
    /// Whether a refused request is worth retrying with `.permissive` guardrails.
    var hasPermissiveGuardrails: Bool { get }
    func respond(to request: ReportRequest, guardrails: ReportGuardrails) async throws -> RawReport
    /// Whether `lines` fit `budget` transcript tokens.
    func fits(_ lines: [NumberedLine], budget: Int) async -> Bool
    func isContextOverflow(_ error: any Error) -> Bool
}

/// Transcript tokens one request of each kind can carry.
struct ReportBudgets: Sendable, Equatable {
    /// A summary or lists request.
    var notes: Int
    /// Rendered part summaries in one merge request.
    var merge: Int
    /// An outline request.
    var outline: Int
}

/// Transcript lines (0-based index ranges, sorted and disjoint) whose requests the model declined, by section.
struct DeclinedLines: Equatable, Sendable {
    var summary: [Range<Int>] = []
    var lists: [Range<Int>] = []
    var outline: [Range<Int>] = []
    /// Merges of part summaries the model declined; those parts' summaries were set side by side instead.
    var merges = 0

    /// Every declined line, whatever it was declined for.
    var all: [Range<Int>] { Self.union(summary + lists + outline) }

    var isEmpty: Bool { all.isEmpty && merges == 0 }

    /// `ranges` sorted, overlapping and touching ones joined.
    static func union(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in ranges.filter({ !$0.isEmpty }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}

/// Writes a report over a small context window, map-reduce, so that a refusal never costs the whole report.
///
/// The report comes from three kinds of requests, run side by side: the summary (title, overview, topics,
/// participants) and the lists (decisions, action items and the rest), one request each or per chunk and then
/// merged, and the conversation outline, one request per chunk. Whenever the model reports that a request
/// overflowed its window, the request is shrunk and retried.
///
/// A request the model declines is retried once with permissive guardrails. Still declined, its lines are halved
/// and each half asked for on its own, down to `smallestPiece` lines; what is still declined at that size is
/// handled without AI (`declined`): the outline quotes those lines, the lists take the questions and possible
/// action items found in them by word cues, and a summary declined everywhere becomes the transcript overview.
/// A declined merge sets the parts' summaries side by side.
final class ReportComposer: Sendable {
    /// A declined chunk is halved until a piece has at most this many lines.
    static let smallestPiece = 3

    let model: any ReportModel
    /// The smallest transcript budget worth a request; shrinking stops there.
    let minimumBudget: Int

    private struct State {
        var answered = 0
        var declined = DeclinedLines()
    }

    private let state = Mutex(State())

    init(model: any ReportModel, minimumBudget: Int) {
        self.model = model
        self.minimumBudget = minimumBudget
    }

    /// Requests answered so far (first try or retry).
    var answeredRequests: Int { state.withLock { $0.answered } }

    /// Lines declined so far, by section.
    var declined: DeclinedLines {
        state.withLock { state in
            var declined = state.declined
            declined.summary = DeclinedLines.union(declined.summary)
            declined.lists = DeclinedLines.union(declined.lists)
            declined.outline = DeclinedLines.union(declined.outline)
            return declined
        }
    }

    // MARK: Report

    /// The grounded report of `transcript`. Throws `IntelligenceError.refused` when `modelName` declined every
    /// request (nothing in the report would be its own), and rethrows any other failure.
    func report(
        transcript: [ContextLine], participants: [String], meetingTitle: String?, budgets: ReportBudgets,
        generatedBy: String, modelName: String
    ) async throws -> MeetingReport {
        let participants = TranscriptFormatter.speakingParticipants(participants, transcript: transcript)
        guard !transcript.isEmpty else {
            return ResultAssembler.report(
                from: RawReport(overview: "No speech was transcribed."), transcript: transcript, participants: participants,
                meetingTitle: meetingTitle, generatedBy: generatedBy)
        }
        async let written = reportNotes(
            transcript: transcript, participants: participants, meetingTitle: meetingTitle, budget: budgets.notes, mergeBudget: budgets.merge)
        async let outlined = outline(
            NumberedLine.numbering(transcript), participants: participants, meetingTitle: meetingTitle, budget: budgets.outline)
        var notes = try await written
        notes.outline = try await outlined
        guard answeredRequests > 0 else {
            throw IntelligenceError.refused("\(modelName) declined every request for this meeting.")
        }
        let declined = self.declined
        var report = ResultAssembler.report(
            from: notes, transcript: transcript, participants: participants, meetingTitle: meetingTitle,
            generatedBy: generatedBy, declined: declined)
        if let notice = Self.notice(declined, transcript: transcript, modelName: modelName) {
            report.notices.append(notice)
        }
        return report
    }

    /// What the reader is told when `declined` is not empty: how much of the meeting the safety filter declined,
    /// for how long, and how those parts were written instead.
    static func notice(_ declined: DeclinedLines, transcript: [ContextLine], modelName: String) -> ReportNotice? {
        let all = declined.all.filter { $0.upperBound <= transcript.count }
        guard !all.isEmpty else {
            guard declined.merges > 0 else { return nil }
            return ReportNotice(
                reason: .safetyFilter,
                message: "\(modelName)'s safety filter declined to combine the summaries of this meeting's parts, so the overview and topics give each part's summary in turn. Everything else was written by \(modelName) as usual.")
        }
        let time = all.reduce(0) { total, range in
            let (start, end) = TranscriptOutliner.times(of: range, in: transcript)
            return total + (end - start)
        }
        let passages = all.count == 1 ? "one passage" : "\(all.count) passages"
        var message = "\(modelName)'s safety filter declined \(passages) of this meeting (\(durationText(time)))."
        if !declined.outline.isEmpty {
            message += " In the outline, those lines are quoted from the transcript instead of summarised."
        }
        if !declined.summary.isEmpty {
            message += " The summary covers the rest of the meeting."
        }
        if !declined.lists.isEmpty {
            message += " Questions and possible action items from those lines were found by phrases such as “I'll” or “can you”, without AI."
        }
        message += " Everything else was written by \(modelName) as usual."
        return ReportNotice(reason: .safetyFilter, message: message, timeWithoutAI: time)
    }

    /// "under a minute", "about 1 minute", "about 4 minutes".
    static func durationText(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes < 1 ? "under a minute" : "about \(minutes) minute\(minutes == 1 ? "" : "s")"
    }

    // MARK: Notes

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
        let lines = TranscriptChunker.splitLongLines(numbered, maxTokens: max(minimumBudget / 2, budget / 2))
        var parts: [RawReport]?
        if await model.fits(lines, budget: budget) {
            do {
                parts = try await notes(lines, participants: participants, meetingTitle: meetingTitle, part: nil)
            } catch let error where model.isContextOverflow(error) {
                budget = try shrunk(budget)
            }
        }
        if parts == nil {
            parts = try await partNotes(numbered, participants: participants, meetingTitle: meetingTitle, budget: budget)
        }
        let all = parts ?? []
        let summaries = all.map(ReportNotes.summary).filter(ReportNotes.hasSummary)
        let summary = summaries.count > 1
            ? try await merged(summaries, participants: participants, meetingTitle: meetingTitle, budget: mergeBudget)
            : summaries.first ?? RawReport()
        return ReportNotes.joined(all, summary: summary)
    }

    /// Notes on `lines` (the meeting, or `part` of it) from a summary request and a lists request, run side by
    /// side, each halved where declined. The overview has two to four paragraphs for a whole meeting with
    /// substance, one or two for a part (the merge writes the meeting's), and one for a thin meeting. Returns one
    /// part per summary answered, the lists joined onto the first (or a part of lists alone when every summary
    /// request was declined).
    func notes(_ lines: [NumberedLine], participants: [String], meetingTitle: String?, part: (index: Int, count: Int)?) async throws -> [RawReport] {
        let isThin = ReportShape(Grounding.substance(lines.map(\.line))).isThin
        func request(_ kind: ReportRequestKind) -> @Sendable ([NumberedLine], (index: Int, count: Int)?) -> ReportRequest {
            { piece, position in
                // A half of the whole meeting is a part of it; a half of a part stays that part.
                let pieceOf = part ?? position
                let paragraphs: ClosedRange<Int> = (pieceOf?.count ?? 1) > 1 ? 1...2 : isThin ? 1...1 : 2...4
                let prompt = IntelligencePrompts.reportPrompt(
                    transcript: piece, participants: participants, meetingTitle: meetingTitle, part: pieceOf)
                return ReportRequest(kind: kind, prompt: prompt, lines: piece, paragraphs: paragraphs)
            }
        }
        async let summaries = bisected(lines, kind: .summary, request: request(.summary))
        async let lists = bisected(lines, kind: .lists, request: request(.lists))
        let (written, listed) = try await (summaries, lists)
        decline(written.declined, for: .summary)
        decline(listed.declined, for: .lists)
        let joinedLists = ReportNotes.joined(listed.answers, summary: RawReport())
        guard let first = written.answers.first else { return [joinedLists] }
        return [ReportNotes.joined([first, joinedLists], summary: first)] + written.answers.dropFirst()
    }

    /// Map step: notes for consecutive chunks. A chunk that overflows is retried smaller; finished parts are kept.
    func partNotes(_ transcript: [NumberedLine], participants: [String], meetingTitle: String?, budget initialBudget: Int) async throws -> [RawReport] {
        var budget = initialBudget
        var remaining = TranscriptChunker.splitLongLines(transcript, maxTokens: max(minimumBudget / 2, budget / 2))[...]
        var parts: [RawReport] = []
        var done = 0
        while !remaining.isEmpty {
            let chunks = TranscriptChunker.balancedChunk(Array(remaining), tokenBudget: budget)
            let chunk = chunks[0]
            do {
                parts += try await notes(
                    chunk, participants: participants, meetingTitle: meetingTitle, part: (index: done, count: done + chunks.count))
                done += 1
                remaining = remaining.dropFirst(chunk.count)
            } catch let error where model.isContextOverflow(error) {
                budget = try shrunk(budget)
                remaining = TranscriptChunker.splitLongLines(Array(remaining), maxTokens: max(minimumBudget / 2, budget / 2))[...]
            }
        }
        return parts
    }

    // MARK: Outline

    /// Outline map step: the outline of each consecutive chunk, concatenated in order and never merged or
    /// compacted, so a long meeting keeps all its detail. A chunk that overflows is retried smaller; one declined
    /// is halved until the declined lines are isolated.
    func outline(_ transcript: [NumberedLine], participants: [String], meetingTitle: String?, budget initialBudget: Int) async throws -> [RawOutlineSegment] {
        var budget = initialBudget
        var remaining = TranscriptChunker.splitLongLines(transcript, maxTokens: max(minimumBudget / 2, budget / 2))[...]
        var segments: [RawOutlineSegment] = []
        var done = 0
        while !remaining.isEmpty {
            let chunks = await model.fits(Array(remaining), budget: budget)
                ? [Array(remaining)] : TranscriptChunker.balancedChunk(Array(remaining), tokenBudget: budget)
            let chunk = chunks[0]
            let part = (index: done, count: done + chunks.count)
            do {
                let outlined = try await bisected(chunk, kind: .outline) { piece, position in
                    // Halves of a meeting outlined in one request are parts of it.
                    let pieceOf = part.count > 1 ? part : position ?? part
                    let prompt = IntelligencePrompts.reportPrompt(
                        transcript: piece, participants: participants, meetingTitle: meetingTitle, part: pieceOf)
                    return ReportRequest(kind: .outline, prompt: prompt, lines: piece, paragraphs: 1...1)
                }
                segments += outlined.answers.flatMap(\.outline)
                decline(outlined.declined, for: .outline)
                done += 1
                remaining = remaining.dropFirst(chunk.count)
            } catch let error where model.isContextOverflow(error) {
                budget = try shrunk(budget)
                remaining = TranscriptChunker.splitLongLines(Array(remaining), maxTokens: max(minimumBudget / 2, budget / 2))[...]
            }
        }
        return segments
    }

    // MARK: Merge

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

    /// One merge request; declined, the group's summaries side by side.
    private func merge(_ group: [RawReport], participants: [String], meetingTitle: String?) async throws -> RawReport {
        var group = group
        while true {
            let prompt = IntelligencePrompts.mergePrompt(
                renderedNotes: group.map(ReportNotes.render), participants: participants, meetingTitle: meetingTitle)
            do {
                if let merged = try await answer(ReportRequest(kind: .merge, prompt: prompt, lines: [], paragraphs: 2...4)) {
                    return ReportNotes.summary(merged)
                }
                state.withLock { $0.declined.merges += 1 }
                return ReportNotes.concatenated(group)
            } catch let error where model.isContextOverflow(error) {
                let smaller = group.map { ReportNotes.compacted($0) }
                guard smaller.contains(where: { $0 != nil }) else { throw IntelligenceError.contextWindowExceeded }
                group = zip(group, smaller).map { $1 ?? $0 }
            }
        }
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

    private func shrunk(_ budget: Int) throws -> Int {
        guard budget > minimumBudget else { throw IntelligenceError.contextWindowExceeded }
        return max(minimumBudget, budget * 2 / 3)
    }

    // MARK: Refusals

    /// Answers for `lines`: one request for all of them; when the model declines it, one per half, recursively,
    /// down to `smallestPiece` lines. Pieces still declined at that size come back in `declined`, in order.
    /// `position` places a half among the original lines (nil for the original); `request` builds each request.
    func bisected(
        _ lines: [NumberedLine], kind: ReportRequestKind, position: (index: Int, count: Int)? = nil,
        request: @escaping @Sendable ([NumberedLine], (index: Int, count: Int)?) -> ReportRequest
    ) async throws -> (answers: [RawReport], declined: [[NumberedLine]]) {
        let built = request(lines, position)
        if let answer = try await answer(built) { return ([answer], []) }
        guard let span = built.span else { return ([], []) }
        guard lines.count > Self.smallestPiece else {
            ReportTrace.record(.withoutAI(kind, lines: span))
            intelligenceLog.info("\(kind.rawValue, privacy: .public) L\(span.lowerBound)–L\(span.upperBound): declined; handled without AI")
            return ([], [lines])
        }
        ReportTrace.record(.bisected(kind, lines: span))
        intelligenceLog.info("\(kind.rawValue, privacy: .public) L\(span.lowerBound)–L\(span.upperBound): declined; split in two")
        let half = lines.count / 2
        let at = position ?? (index: 0, count: 1)
        async let first = bisected(
            Array(lines[..<half]), kind: kind, position: (index: at.index * 2, count: at.count * 2), request: request)
        async let second = bisected(
            Array(lines[half...]), kind: kind, position: (index: at.index * 2 + 1, count: at.count * 2), request: request)
        let (a, b) = try await (first, second)
        return (a.answers + b.answers, a.declined + b.declined)
    }

    /// `request` answered, or nil when the model declined it on the first try and on a retry with permissive
    /// guardrails. Context overflow and other failures of the first try are rethrown (callers shrink and retry, or
    /// give up); any failure of the retry counts as declined.
    func answer(_ request: ReportRequest) async throws -> RawReport? {
        let span = request.span
        do {
            let answer = try await model.respond(to: request, guardrails: .standard)
            answered(request, .answered)
            return answer
        } catch IntelligenceError.refused {
            intelligenceLog.info("\(request.kind.rawValue, privacy: .public) request declined by the safety filter")
        }
        guard model.hasPermissiveGuardrails else {
            ReportTrace.record(.request(request.kind, lines: span, outcome: .refused))
            return nil
        }
        do {
            let answer = try await model.respond(to: request, guardrails: .permissive)
            answered(request, .answeredOnRetry)
            return answer
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            intelligenceLog.info("\(request.kind.rawValue, privacy: .public) permissive retry failed: \(error.localizedDescription, privacy: .public)")
            let refusedAgain = if case IntelligenceError.refused = error { true } else { false }
            ReportTrace.record(.request(request.kind, lines: span, outcome: refusedAgain ? .refusedAfterRetry : .retryFailed))
            return nil
        }
    }

    private func answered(_ request: ReportRequest, _ outcome: ReportTrace.Outcome) {
        state.withLock { $0.answered += 1 }
        ReportTrace.record(.request(request.kind, lines: request.span, outcome: outcome))
    }

    private func decline(_ pieces: [[NumberedLine]], for kind: ReportRequestKind) {
        let ranges = pieces.compactMap { piece -> Range<Int>? in
            guard let first = piece.first, let last = piece.last else { return nil }
            return (first.number - 1)..<last.number
        }
        guard !ranges.isEmpty else { return }
        state.withLock { state in
            switch kind {
            case .summary: state.declined.summary += ranges
            case .lists: state.declined.lists += ranges
            case .outline: state.declined.outline += ranges
            case .merge: break
            }
        }
    }
}
