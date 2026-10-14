import Foundation
import Testing
import VCModels
@testable import VCIntelligence

@Suite struct AppleAvailabilityTests {
    @Test func reasonIsGivenExactlyWhenUnavailable() async throws {
        let status = AppleIntelligenceStatus.current
        #expect(status.isAvailable == (status.reason == nil))
        #expect(status.isAvailable == (status.shortReason == nil))
        guard let reason = status.reason else { return }
        guard #available(macOS 26.0, *) else {
            #expect(IntelligenceFactory.make(kind: .apple) == nil)
            return
        }
        await #expect(throws: IntelligenceError.unavailable(reason)) {
            try await AppleIntelligenceEngine().report(transcript: [], participants: [], meetingTitle: nil)
        }
    }

    @Test func olderMacOSAndIntelExplainWhy() {
        let intel = MachineInfo(osMajor: 15, osMinor: 6, isAppleSilicon: false, processArchitecture: "x86_64", physicalMemory: 1 << 34)
        #expect(AppleIntelligenceStatus.status(machine: intel) == .needsAppleSilicon)
        let sonoma = MachineInfo(osMajor: 14, osMinor: 4, isAppleSilicon: true, processArchitecture: "arm64", physicalMemory: 1 << 34)
        #expect(AppleIntelligenceStatus.status(machine: sonoma) == .needsNewerMacOS)
        #expect(AppleIntelligenceStatus.needsNewerMacOS.shortReason == "Needs macOS 26")
    }
}

/// Runs against the real on-device model; skipped where Apple Intelligence is unavailable.
@Suite(.enabled(if: AppleIntelligenceStatus.current.isAvailable && Fixture.isAvailable), .serialized)
struct AppleIntelligenceEngineTests {
    // swift-testing can't take a `@Suite` type marked `@available`, so each test is gated instead.
    @available(macOS 26.0, *)
    var engine: AppleIntelligenceEngine { AppleIntelligenceEngine() }

    @available(macOS 26.0, *)
    @Test func correctsSelfCorrectedDate() async throws {
        let transcript = try Fixture.transcript()
        let insight = try await engine.analyze(utterance: transcript[4], recentContext: Array(transcript[0..<4]))
        let corrected = try #require(insight.correctedText)
        #expect(corrected.localizedCaseInsensitiveContains("Wednesday the fifteenth"))
        #expect(!corrected.localizedCaseInsensitiveContains("Tuesday"))
        #expect(insight.correctionReason != nil)
    }

    @available(macOS 26.0, *)
    @Test(arguments: [1, 2, 3, 9])
    func leavesCleanUtterancesUncorrected(index: Int) async throws {
        let transcript = try Fixture.transcript()
        let insight = try await engine.analyze(utterance: transcript[index], recentContext: Array(transcript[..<index]))
        #expect(insight.correctedText == nil, "over-corrected: \(insight.correctedText ?? "")")
    }

    @available(macOS 26.0, *)
    @Test func extractsCommitmentWithSpeakerAsOwner() async throws {
        let transcript = try Fixture.transcript()
        let insight = try await engine.analyze(utterance: transcript[6], recentContext: Array(transcript[..<6]))
        let item = try #require(insight.actionItem)
        #expect(item.owner == "Rishi")
        #expect(item.task.localizedCaseInsensitiveContains("budget"))
        #expect(item.sourceSegmentID == transcript[6].segmentID)
    }

    @available(macOS 26.0, *)
    @Test func analyzeStaysWithinWindowWithHugeContext() async throws {
        let transcript = try Fixture.transcript()
        // ~60k tokens of context: far beyond the window; only the recent tail may be sent.
        let context = (0..<200).flatMap { round in
            transcript.map { ContextLine(segmentID: UUID(), speaker: $0.speaker, time: $0.time + Double(round) * 60, text: $0.text) }
        }
        let insight = try await engine.analyze(utterance: transcript[9], recentContext: context)
        #expect(UtteranceIntent.allCases.contains(insight.intent))
    }

    @available(macOS 26.0, *)
    @Test func reportSinglePassCoversFixtureMeeting() async throws {
        let transcript = try Fixture.transcript()
        let report = try await engine.report(transcript: transcript, participants: try Fixture.speakers, meetingTitle: "Quarterly planning")
        try Self.expectFixtureReport(report, transcript: transcript)
    }

    @available(macOS 26.0, *)
    @Test func reportMapReduceCoversFixtureMeeting() async throws {
        let transcript = try Fixture.transcript()
        let budget = AppleIntelligenceEngine.minimumTranscriptBudget
        // The fixture costs more than the forced budget, so it must be split into parts and merged.
        #expect(TranscriptChunker.chunk(NumberedLine.numbering(transcript), tokenBudget: budget).count >= 2)
        let report = try await AppleIntelligenceEngine(transcriptTokenBudget: budget)
            .report(transcript: transcript, participants: try Fixture.speakers, meetingTitle: "Quarterly planning")
        try Self.expectFixtureReport(report, transcript: transcript)
    }

    /// The user's one-minute meeting: a blip participant, greetings, a request answered in the room.
    @available(macOS 26.0, *)
    @Test func regressionMeetingGetsABriefReportWithoutInventions() async throws {
        let report = try await engine.report(transcript: Regression.transcript, participants: ["Ayo", "Speaker 1"], meetingTitle: nil)
        #expect(report.decisions.isEmpty)
        #expect(report.actionItems.isEmpty)
        #expect(report.notesToRemember.isEmpty && report.missedOpportunities.isEmpty)
        #expect(report.participantSummaries.isEmpty)
        #expect(report.topics.count <= 1)
        #expect(report.outline.count <= 1 && report.outline.flatMap(\.points).count <= 2)
    }

    @available(macOS 26.0, *)
    @Test(arguments: 0..<8)
    func regressionLinesNeedNoCorrectionOrTask(index: Int) async throws {
        let t = Regression.transcript
        let insight = try await engine.analyze(utterance: t[index], recentContext: Array(t[..<index]))
        #expect(insight.correctedText == nil, "corrected to \(insight.correctedText ?? "")")
        #expect(insight.actionItem == nil)
    }

    @available(macOS 26.0, *)
    @Test func emptyTranscriptReportsNothingWithoutInventing() async throws {
        let report = try await engine.report(transcript: [], participants: ["Daniel"], meetingTitle: nil)
        #expect(report.actionItems.isEmpty && report.decisions.isEmpty && report.topics.isEmpty)
        #expect(report.overview == "No speech was transcribed.")
    }

    static func expectFixtureReport(_ report: MeetingReport, transcript: [ContextLine]) throws {
        #expect(report.title == "Quarterly planning")
        #expect(report.generatedBy == "Apple Intelligence (on-device)")
        #expect(!report.overview.isEmpty)
        #expect(!report.topics.isEmpty)
        #expect(report.decisions.contains { $0.localizedCaseInsensitiveContains("Wednesday") })
        let budget = try #require(report.actionItems.first { $0.task.localizedCaseInsensitiveContains("budget") })
        #expect(budget.owner == "Rishi")
        let pressKit = try #require(report.actionItems.first { $0.task.localizedCaseInsensitiveContains("press kit") })
        #expect(pressKit.owner == "Samantha")
        let speakers = Set(transcript.map(\.speaker))
        #expect(report.participantSummaries.allSatisfy { speakers.contains($0.name) })
        // The outline covers the meeting, every point by someone who spoke.
        #expect(!report.outline.isEmpty)
        #expect(report.outline.flatMap(\.points).allSatisfy { speakers.contains($0.speaker) })
        OutlineGroundingTests.expectCoverage(report.outline, of: transcript)
    }
}
