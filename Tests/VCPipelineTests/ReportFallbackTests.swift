import Foundation
import Testing
import VCIntelligence
import VCModels

@testable import VCPipeline

/// An engine whose report fails with `error`, or succeeds when `error` is nil.
private final class StubEngine: MeetingIntelligence {
    let engineName: String
    let error: IntelligenceError?
    let calls = Mutex(0)

    init(_ name: String, failing error: IntelligenceError? = nil) {
        engineName = name
        self.error = error
    }

    func analyze(utterance: ContextLine, recentContext: [ContextLine]) async throws -> UtteranceInsight {
        UtteranceInsight(intent: .statement)
    }

    func report(transcript: [ContextLine], participants: [String], meetingTitle: String?) async throws -> MeetingReport {
        calls.withLock { $0 += 1 }
        if let error { throw error }
        return MeetingReport(
            title: meetingTitle ?? "Stand-in", overview: "Written by \(engineName).", topics: [], decisions: [], actionItems: [],
            notesToRemember: [], missedOpportunities: [], openQuestions: [], corrections: [], participantSummaries: [],
            generatedBy: engineName)
    }
}

private func meeting() -> Meeting {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let texts = [
        "We need to settle the venue for the offsite before the end of the month.",
        "I'll call the hotel in Porto tomorrow and ask about the conference rooms.",
        "Can you send me the budget for catering by Friday?",
        "Sure, I'll send the catering budget on Thursday.",
    ]
    let segments = texts.enumerated().map { index, text in
        TranscriptSegment(
            channel: .microphone, speakerKey: index.isMultiple(of: 2) ? "mic:1" : "mic:2",
            range: TimeRange(start: Double(index) * 30, end: Double(index) * 30 + 20), text: text, confidence: nil, localeID: "en")
    }
    return Meeting(
        title: "Offsite planning", kind: .inPerson, startedAt: start, endedAt: start.addingTimeInterval(120),
        participants: [
            Participant(id: "mic:1", displayName: "Ana", channel: .microphone, colorIndex: 0),
            Participant(id: "mic:2", displayName: "Ben", channel: .microphone, colorIndex: 1),
        ],
        segments: segments, localeIDs: ["en"])
}

/// The user always gets a report: a failed engine hands over to the next (the other language model, then the
/// transcript outline), and the report says so.
@Suite struct ReportFallbackTests {
    let declined = IntelligenceError.refused("Apple Intelligence declined every request for this meeting.")

    @Test func aWorkingEngineNeedsNoFallback() async throws {
        let standIn = StubEngine("Claude")
        let report = try await ReportWriter.report(for: meeting(), engine: StubEngine("Apple Intelligence"), title: nil, fallbacks: [standIn])
        #expect(report.generatedBy == "Apple Intelligence" && report.notices.isEmpty)
        #expect(standIn.calls.withLock { $0 } == 0)
    }

    @Test func aDeclinedMeetingGoesToClaudeFirst() async throws {
        let claude = StubEngine("Claude")
        let outline = TranscriptOutlineEngine()
        let trace = ReportTrace()
        let report = try await ReportTrace.$current.withValue(trace) {
            try await ReportWriter.report(
                for: meeting(), engine: StubEngine("Apple Intelligence", failing: declined), title: "Offsite", fallbacks: [claude, outline])
        }
        #expect(report.generatedBy == "Claude" && report.kind == .languageModel)
        #expect(report.notices == [ReportNotice(
            reason: .engineFallback, message: "Apple Intelligence declined to write a report for this meeting, so Claude wrote it instead.")])
        #expect(trace.summary.engineFallbacks == 1)
    }

    @Test func withoutClaudeTheTranscriptOutlineWritesIt() async throws {
        let failingClaude = StubEngine("Claude", failing: .http(status: 529, type: "overloaded_error", message: "Overloaded"))
        let trace = ReportTrace()
        let report = try await ReportTrace.$current.withValue(trace) {
            try await ReportWriter.report(
                for: meeting(), engine: StubEngine("Apple Intelligence", failing: declined), title: "Offsite",
                fallbacks: [failingClaude, TranscriptOutlineEngine()])
        }
        #expect(report.kind == .transcriptOutline && report.title == "Offsite")
        let notice = try #require(report.notices.first)
        #expect(notice.reason == .engineFallback)
        #expect(notice.message == "Apple Intelligence declined to write a report for this meeting, so this report was built from the transcript without AI (1 min).")
        #expect(notice.timeWithoutAI == 110)
        #expect(trace.events.count == 2)
        #expect(ReportRenderer.markdown({ var m = meeting(); m.report = report; return m }()).contains("- **Report note:** \(notice.message)\n"))
    }

    @Test func otherFailuresAreNamedInTheNotice() async throws {
        let report = try await ReportWriter.report(
            for: meeting(), engine: StubEngine("Apple Intelligence", failing: .contextWindowExceeded), title: nil,
            fallbacks: [TranscriptOutlineEngine()])
        #expect(report.notices.first?.message.hasPrefix(
            "Apple Intelligence couldn't write this report (The text does not fit in the model's context window), so this report was built") == true)
    }

    @Test func onlyWhenEveryEngineFailsIsThereAnError() async throws {
        await #expect(throws: IntelligenceError.truncatedResponse) {
            _ = try await ReportWriter.report(
                for: meeting(), engine: StubEngine("Apple Intelligence", failing: declined), title: nil,
                fallbacks: [StubEngine("Claude", failing: .truncatedResponse)])
        }
    }

    @Test func defaultFallbacksEndWithTheTranscriptOutline() {
        #expect(ReportWriter.fallbacks(after: TranscriptOutlineEngine()).isEmpty)
        let afterApple = ReportWriter.fallbacks(after: StubEngine("Apple Intelligence"))
        #expect(afterApple.last is TranscriptOutlineEngine)
        #expect(afterApple.dropLast().allSatisfy { $0 is ClaudeEngine }, "only Claude stands in before the outline")
    }

    @Test func declinedSegmentsAndNoticesAreRendered() throws {
        var m = meeting()
        let id = m.segments[1].id
        m.report = MeetingReport(
            title: "Offsite", overview: "Venue and catering.", topics: [], decisions: [], actionItems: [], notesToRemember: [],
            missedOpportunities: [], openQuestions: [], corrections: [], participantSummaries: [],
            outline: [
                OutlineSegment(heading: "Venue", start: 0, end: 29, points: [OutlinePoint(speaker: "Ana", text: "Ana wants the venue settled.", time: 0, segmentIDs: [m.segments[0].id])]),
                OutlineSegment(
                    heading: "Porto hotel", start: 30, end: 59,
                    points: [OutlinePoint(speaker: "Ben", text: "I'll call the hotel in Porto tomorrow.", time: 30, segmentIDs: [id], isQuote: true)],
                    isDeclined: true),
            ],
            generatedBy: "Apple Intelligence (on-device)",
            notices: [ReportNotice(reason: .safetyFilter, message: "Apple Intelligence's safety filter declined one passage of this meeting (under a minute).", timeWithoutAI: 20)])
        let md = ReportRenderer.markdown(m)
        #expect(md.contains("- **Report note:** Apple Intelligence's safety filter declined one passage of this meeting (under a minute).\n"))
        #expect(md.contains("### [00:30–00:59] Porto hotel\n\n_Apple Intelligence's safety filter declined this part; quoted from the transcript._\n"))
        #expect(!md.contains(ReportRenderer.extractedSegmentNote))
        #expect(m.report?.outline[1].isExtracted == true)
    }

    @Test func reportsSavedBeforeNoticesStillDecode() throws {
        var m = meeting()
        m.report = MeetingReport(
            title: "Offsite", overview: "", topics: [], decisions: [], actionItems: [], notesToRemember: [], missedOpportunities: [],
            openQuestions: [], corrections: [], participantSummaries: [],
            outline: [OutlineSegment(heading: "Venue", start: 0, end: 29, points: [], isExtracted: true)], generatedBy: "Claude")
        var json = try JSONSerialization.jsonObject(with: MeetingStore.encoder.encode(m)) as! [String: Any]
        var report = json["report"] as! [String: Any]
        report["notices"] = nil
        var segment = (report["outline"] as! [[String: Any]])[0]
        segment["isDeclined"] = nil
        report["outline"] = [segment]
        json["report"] = report
        let decoded = try MeetingStore.decoder.decode(Meeting.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.report?.notices == [])
        #expect(decoded.report?.outline.first?.isDeclined == false && decoded.report?.outline.first?.isExtracted == true)
    }
}
