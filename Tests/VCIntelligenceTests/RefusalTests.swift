import Foundation
import Testing
import VCModels

@testable import VCIntelligence

/// A report model that declines every request carrying one of `flagged` lines (1-based `L` numbers), or every
/// request of the kinds in `refusedKinds`; with `permissiveAnswers`, the permissive retry answers anyway. Answers
/// are built from the request's own lines, so they pass grounding.
private final class RefusingModel: ReportModel {
    let flagged: Set<Int>
    let refusedKinds: Set<ReportRequestKind>
    let permissiveAnswers: Bool
    let hasPermissiveGuardrails: Bool
    /// The permissive retry answers something other than the JSON asked for.
    let unusableRetries: Bool
    /// Every request made: kind, `L` span, guardrails, and whether it was declined.
    let log = Mutex<[(kind: ReportRequestKind, span: ClosedRange<Int>?, guardrails: ReportGuardrails, declined: Bool)]>([])

    init(
        flagged: Set<Int> = [], refusedKinds: Set<ReportRequestKind> = [], permissiveAnswers: Bool = false,
        hasPermissiveGuardrails: Bool = true, unusableRetries: Bool = false
    ) {
        self.flagged = flagged
        self.refusedKinds = refusedKinds
        self.permissiveAnswers = permissiveAnswers
        self.hasPermissiveGuardrails = hasPermissiveGuardrails
        self.unusableRetries = unusableRetries
    }

    func respond(to request: ReportRequest, guardrails: ReportGuardrails) async throws -> RawReport {
        let declined = (refusedKinds.contains(request.kind) || request.lines.contains { flagged.contains($0.number) })
            && !(guardrails == .permissive && permissiveAnswers)
        log.withLock { $0.append((request.kind, request.span, guardrails, declined)) }
        if guardrails == .permissive, unusableRetries { throw IntelligenceError.malformedResponse("the answer is not one JSON object") }
        if declined { throw IntelligenceError.refused("Detected content likely to be unsafe") }
        let lines = request.lines
        switch request.kind {
        case .summary:
            return RawReport(
                title: "Team sync", overview: "The team went through \(lines.first.map { TranscriptOutliner.cleaned($0.line.text) } ?? "the meeting")",
                topics: lines.prefix(1).map { RawTopic(title: TranscriptOutliner.cleaned($0.line.text), summary: nil, speakers: [$0.line.speaker]) })
        case .lists:
            return RawReport(openQuestions: lines.filter { Grounding.isQuestion($0.line.text) }.map { RawItem(text: $0.line.text, lines: [$0.number]) })
        case .outline:
            let points = lines.filter { TranscriptOutliner.isSubstantive($0.line.text) }
                .map { RawOutlinePoint(speaker: $0.line.speaker, text: $0.line.text, lines: [$0.number]) }
            return RawReport(outline: [RawOutlineSegment(heading: nil, points: points)])
        case .merge:
            return RawReport(title: "Team sync", overview: "The team went through billing, the conference and the release estimate.")
        }
    }

    func fits(_ lines: [NumberedLine], budget: Int) async -> Bool {
        lines.reduce(0) { $0 + TranscriptChunker.defaultCost($1) } <= budget
    }

    func isContextOverflow(_ error: any Error) -> Bool { false }

    var requests: [(kind: ReportRequestKind, span: ClosedRange<Int>?, guardrails: ReportGuardrails, declined: Bool)] {
        log.withLock { $0 }
    }
}

/// A report survives refusals: a declined request is retried with permissive guardrails, then halved until the
/// declined lines are isolated, and those lines are handled without AI, with a note saying so.
@Suite struct RefusalTests {
    static let speakers = ["Maya", "Leo", "Tom", "Priya"]
    let t = TeamSync.transcript
    /// Leo's line about a duplicate-charge alert.
    let flaggedLine = 17
    /// Everything in one request per kind.
    let wide = ReportBudgets(notes: 4_000, merge: 2_000, outline: 4_000)
    /// Several chunks per kind, merged.
    let narrow = ReportBudgets(notes: 260, merge: 600, outline: 260)

    private func compose(
        _ model: RefusingModel, budgets: ReportBudgets
    ) async throws -> (report: MeetingReport, composer: ReportComposer, trace: ReportTrace) {
        let composer = ReportComposer(model: model, minimumBudget: 100)
        let trace = ReportTrace()
        let report = try await ReportTrace.$current.withValue(trace) {
            try await composer.report(
                transcript: t, participants: Self.speakers, meetingTitle: nil, budgets: budgets,
                generatedBy: "Test model", modelName: "Apple Intelligence")
        }
        return (report, composer, trace)
    }

    @Test func permissiveRetryAnswersADeclinedRequest() async throws {
        let model = RefusingModel(flagged: [flaggedLine], permissiveAnswers: true)
        let (report, composer, trace) = try await compose(model, budgets: wide)
        #expect(composer.declined.isEmpty)
        #expect(report.notices.isEmpty)
        #expect(!report.outline.contains { $0.isDeclined })
        // Summary, lists and outline each declined once, then answered on the retry; nothing was split.
        let summary = trace.summary
        #expect(summary.refusals == 3 && summary.retries == 3 && summary.answeredOnRetry == 3)
        #expect(summary.bisections == 0 && summary.linesWithoutAI.isEmpty)
        #expect(model.requests.filter { $0.guardrails == .permissive }.count == 3)
    }

    @Test(arguments: [true, false])
    func bisectionIsolatesTheDeclinedLines(wideBudgets: Bool) async throws {
        let model = RefusingModel(flagged: [flaggedLine])
        let (report, composer, trace) = try await compose(model, budgets: wideBudgets ? wide : narrow)
        let declined = composer.declined
        for (kind, ranges) in [("outline", declined.outline), ("summary", declined.summary), ("lists", declined.lists)] {
            #expect(ranges.count == 1, "\(kind)")
            let range = try #require(ranges.first)
            #expect(range.contains(flaggedLine - 1), "\(kind)")
            #expect(range.count <= ReportComposer.smallestPiece, "\(kind): \(range)")
        }
        // Every declined request was retried once before being split or given up.
        let summary = trace.summary
        #expect(summary.retries == summary.refusals)
        #expect(summary.bisections > 0)
        #expect(model.requests.allSatisfy { !$0.declined || $0.span.map { $0.contains(flaggedLine) } == true })
        // Nothing but the flagged stretch is handled without AI.
        #expect(summary.linesWithoutAI.values.allSatisfy { $0 <= ReportComposer.smallestPiece })

        // The outline: the flagged line sits in a declined segment quoting only declined lines; the rest is the model's.
        let flaggedID = t[flaggedLine - 1].segmentID
        let declinedSegments = report.outline.filter(\.isDeclined)
        #expect(declinedSegments.count == 1)
        let quoted = try #require(declinedSegments.first)
        #expect(quoted.isExtracted && quoted.points.allSatisfy(\.isQuote))
        let declinedIDs = Set(declined.outline.flatMap { t[$0].map(\.segmentID) })
        #expect(quoted.points.flatMap(\.segmentIDs).allSatisfy(declinedIDs.contains))
        #expect(!report.outline.filter { !$0.isDeclined }.flatMap(\.points).flatMap(\.segmentIDs).contains(flaggedID))
        #expect(report.outline.contains { !$0.isExtracted }, "the model's own segments are kept")
        OutlineGroundingTests.expectCoverage(report.outline, of: t)

        // Grounding still applies: every outline point cites real lines of its speaker.
        for point in report.outline.flatMap(\.points) {
            let cited = point.segmentIDs.compactMap { id in t.first { $0.segmentID == id } }
            #expect(!cited.isEmpty && cited.allSatisfy { $0.speaker == point.speaker })
        }
        #expect(!report.overview.isEmpty)
        #expect(report.title == "Team sync")

        let notice = try #require(report.notices.first)
        #expect(notice.reason == .safetyFilter)
        #expect(notice.message.hasPrefix("Apple Intelligence's safety filter declined one passage of this meeting (under a minute)."))
        #expect(notice.message.contains("quoted from the transcript"))
        #expect((notice.timeWithoutAI ?? 0) > 0 && (notice.timeWithoutAI ?? .infinity) < 60)
    }

    @Test func withoutPermissiveGuardrailsADeclinedRequestIsSplitStraightAway() async throws {
        let model = RefusingModel(flagged: [flaggedLine], hasPermissiveGuardrails: false)
        let (report, composer, trace) = try await compose(model, budgets: wide)
        #expect(model.requests.allSatisfy { $0.guardrails == .standard })
        #expect(trace.summary.retries == 0 && trace.summary.refusals > 0)
        #expect(composer.declined.outline.count == 1)
        #expect(report.outline.contains { $0.isDeclined })
    }

    @Test func declinedSummariesLeaveTheTranscriptOverviewAndQuestions() async throws {
        let model = RefusingModel(refusedKinds: [.summary, .lists])
        let (report, composer, _) = try await compose(model, budgets: wide)
        // Every summary and lists request declined: the outline still came from the model.
        #expect(composer.answeredRequests > 0)
        #expect(composer.declined.summary == [0..<t.count] && composer.declined.lists == [0..<t.count])
        #expect(report.overview.contains(" spoke \(t.count) lines over "), "the transcript overview")
        #expect(report.title == "Meeting")
        // Questions and possible action items found by word cues, as in the report without AI.
        let noAI = TranscriptOutliner.report(transcript: t, participants: Self.speakers, meetingTitle: nil)
        #expect(!report.openQuestions.isEmpty && Set(report.openQuestions).isSubset(of: Set(TranscriptOutliner.questions(t))))
        #expect(report.actionItems.map(\.task) == noAI.actionItems.map(\.task))
        let notice = try #require(report.notices.first)
        #expect(notice.message.contains("The summary covers the rest of the meeting."))
        #expect(notice.message.contains("Questions and possible action items from those lines were found"))
        #expect(!report.outline.contains { $0.isDeclined })
    }

    @Test func aDeclinedMergeSetsPartSummariesSideBySide() async throws {
        let model = RefusingModel(refusedKinds: [.merge])
        let (report, composer, _) = try await compose(model, budgets: narrow)
        #expect(composer.declined.merges > 0)
        #expect(composer.declined.all.isEmpty)
        #expect(report.overview.components(separatedBy: "\n\n").count > 1)
        #expect(report.notices.first?.message.contains("declined to combine the summaries") == true)
    }

    @Test func everyRequestDeclinedFailsTheEngineSoAnotherCanStandIn() async throws {
        let model = RefusingModel(flagged: Set(1...t.count))
        await #expect(throws: IntelligenceError.refused("Apple Intelligence declined every request for this meeting.")) {
            _ = try await compose(model, budgets: wide)
        }
    }

    @Test func anUnusableRetryAnswerCountsAsDeclined() async throws {
        let model = RefusingModel(flagged: [flaggedLine], unusableRetries: true)
        let (report, composer, trace) = try await compose(model, budgets: wide)
        #expect(composer.declined.outline.count == 1)
        #expect(report.outline.contains { $0.isDeclined })
        #expect(trace.details.contains("outline L1–L40: refused; the permissive retry's answer was unusable"))
        #expect(trace.summary.retries == trace.summary.refusals)
    }

    /// The permissive retry's text answer must be one complete JSON object with every required property.
    @Test func permissiveAnswersAreParsedStrictly() throws {
        guard #available(macOS 26.0, *) else { return }
        let schema = #"{"type":"object","properties":{"segments":{"type":"array"}},"required":["segments"]}"#
        let fenced = "```json\n{\"segments\": [{\"heading\": \"Billing\", \"points\": []}]}\n```"
        #expect(try GenOutline(AppleIntelligenceEngine.strictJSON(fenced, schema: schema)).segments.map(\.heading) == ["Billing"])
        for unusable in [#"{"segments": [{"heading": "Billing""#, #"{"heading": "Billing"}"#, "I can't help with that.", "[]"] {
            #expect(throws: IntelligenceError.self) { try AppleIntelligenceEngine.strictJSON(unusable, schema: schema) }
        }
    }

    @Test func noticeDurations() {
        #expect(ReportComposer.durationText(20) == "under a minute")
        #expect(ReportComposer.durationText(70) == "about 1 minute")
        #expect(ReportComposer.durationText(250) == "about 4 minutes")
        #expect(ReportComposer.notice(DeclinedLines(), transcript: t, modelName: "Apple Intelligence") == nil)
    }

    @Test func traceCountsAndDescribesRequests() {
        let trace = ReportTrace()
        trace.record(.request(.outline, lines: 1...40, outcome: .refusedAfterRetry))
        trace.record(.bisected(.outline, lines: 1...40))
        trace.record(.request(.outline, lines: 1...20, outcome: .answered))
        trace.record(.request(.outline, lines: 21...40, outcome: .answeredOnRetry))
        trace.record(.withoutAI(.lists, lines: 16...17))
        trace.record(.withoutAI(.lists, lines: 17...18))
        let summary = trace.summary
        #expect(summary.requests == 3 && summary.refusals == 2 && summary.retries == 2 && summary.answeredOnRetry == 1)
        #expect(summary.bisections == 1 && summary.linesWithoutAI == [.lists: 3])
        #expect(trace.details == [
            "outline L1–L40: refused, and refused again on the permissive retry",
            "outline L1–L40: split in two",
            "outline L21–L40: refused, answered on the permissive retry",
            "lists L16–L17: handled without AI",
            "lists L17–L18: handled without AI",
        ])
    }

    @Test func declinedLinesUnion() {
        #expect(DeclinedLines.union([5..<8, 0..<2, 2..<3, 7..<9]) == [0..<3, 5..<9])
    }
}
