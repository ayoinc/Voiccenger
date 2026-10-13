import Foundation
import Synchronization
import Testing
import VCModels

@testable import VCPipeline

/// A fully populated meeting: enrolled and unknown speakers, both channels, an insight with a correction.
private func sampleMeeting() -> Meeting {
    let rishiProfile = UUID()
    let rishiKey = SpeakerTurn.profileKey(rishiProfile)
    let participants = [
        Participant(id: rishiKey, displayName: "Rishi", profileID: rishiProfile, channel: .microphone, localeID: "en-IN",
                    seatAzimuthDegrees: 42, speakingTime: 61, colorIndex: 2),
        Participant(id: "mic:3", displayName: "Speaker 1", channel: .microphone, localeID: "en-GB", speakingTime: 30, colorIndex: 0),
        Participant(id: "sys:1", displayName: "Remote | 1", channel: .system, localeID: "en-US", speakingTime: 12, colorIndex: 1),
    ]
    let corrected = TranscriptSegment(
        channel: .microphone, speakerKey: rishiKey, range: TimeRange(start: 65, end: 70),
        text: "We finished the payment integration last weak.", confidence: 0.7, localeID: "en-IN",
        direction: DirectionEstimate(azimuthDegrees: 41, confidence: 0.8, time: 66),
        insight: UtteranceInsight(
            intent: .statement, correctedText: "We finished the payment integration last week.",
            correctionReason: "Likely recognition error"))
    let segments = [
        corrected,
        TranscriptSegment(channel: .system, speakerKey: "sys:1", range: TimeRange(start: 3, end: 5),
                          text: "Can everyone hear me?", confidence: 0.9, localeID: "en-US"),
        TranscriptSegment(channel: .microphone, speakerKey: "mic:3", range: TimeRange(start: 3_700, end: 3_702),
                          text: "Let's wrap up.", confidence: nil, localeID: "en-GB"),
    ]
    let report = MeetingReport(
        title: "Quarterly planning review", overview: "The team agreed the mobile launch timeline.",
        topics: [TopicSummary(title: "Launch date", summary: "Mobile app launch timing.", speakers: ["Rishi", "Speaker 1"])],
        decisions: ["Launch on 14 November"],
        actionItems: [ActionItem(task: "Send the launch brief to marketing", owner: "Rishi", due: "Friday")],
        notesToRemember: ["Marketing needs three weeks' notice"],
        missedOpportunities: ["Nobody confirmed the QA sign-off date"],
        openQuestions: ["Who owns the app store listing?"],
        corrections: [CorrectionNote(speaker: "Rishi", original: "last weak", corrected: "last week", reason: "Recognition error")],
        participantSummaries: [ParticipantSummary(name: "Rishi", keyPoints: ["Payment integration is done"])],
        generatedBy: "Test engine", generatedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
    return Meeting(
        title: "Planning", kind: .online, appName: "Zoom", startedAt: Date(timeIntervalSinceReferenceDate: 799_999_000),
        endedAt: Date(timeIntervalSinceReferenceDate: 799_999_000 + 3_725), participants: participants, segments: segments,
        report: report, audioFiles: ["microphone.caf", "system.caf"], localeIDs: ["en-GB", "en-IN", "en-US"])
}

@Suite("MeetingStore")
struct MeetingStoreTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "vc-store-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test("A saved meeting reads back identically, from its own directory")
    func roundTrip() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingStore(directory: dir)
        let meeting = sampleMeeting()

        try await store.save(meeting)
        let file = store.directory(for: meeting.id).appending(path: MeetingStore.fileName)
        #expect(FileManager.default.fileExists(atPath: file.path))

        let all = try await store.all()
        #expect(all == [meeting])
        #expect(try await store.meeting(id: meeting.id) == meeting)
    }

    @Test("all() is newest first, skips unreadable directories, and delete removes the directory")
    func listingAndDelete() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingStore(directory: dir)
        #expect(try await store.all().isEmpty, "a missing store directory is an empty store")

        var older = sampleMeeting()
        older.id = UUID()
        older.startedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        var newer = sampleMeeting()
        newer.id = UUID()
        newer.startedAt = Date(timeIntervalSinceReferenceDate: 2_000)
        try await store.save(older)
        try await store.save(newer)
        // An interrupted recording leaves a directory without meeting.json.
        try FileManager.default.createDirectory(at: dir.appending(path: UUID().uuidString), withIntermediateDirectories: true)

        #expect(try await store.all().map(\.id) == [newer.id, older.id])

        try await store.delete(id: older.id)
        #expect(!FileManager.default.fileExists(atPath: store.directory(for: older.id).path))
        #expect(try await store.all().map(\.id) == [newer.id])
        try await store.delete(id: older.id)  // deleting twice is harmless
    }

    @Test("Saving again overwrites the meeting")
    func overwrite() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingStore(directory: dir)
        var meeting = sampleMeeting()
        try await store.save(meeting)
        meeting.title = "Renamed"
        meeting.report = nil
        try await store.save(meeting)
        #expect(try await store.all() == [meeting])
    }
}

@Suite("ReportRenderer")
struct ReportRendererTests {
    @Test("The Markdown has every report section and the content of each")
    func everySection() {
        let md = ReportRenderer.markdown(sampleMeeting())
        #expect(md.hasPrefix("# Quarterly planning review\n"))
        for heading in [
            "## Overview", "## Topics", "## Decisions", "## Action Items", "## Notes to Remember",
            "## Things That Could Have Been Said", "## Open Questions", "## Corrections", "## Participant Summaries",
            "## Participants", "## Transcript",
        ] {
            #expect(md.contains("\n\(heading)\n"), "missing \(heading)")
        }
        #expect(md.contains("The team agreed the mobile launch timeline."))
        #expect(md.contains("**Launch date**"))
        #expect(md.contains("- Launch on 14 November"))
        #expect(md.contains("- [ ] Send the launch brief to marketing — owner: **Rishi**, due: Friday"))
        #expect(md.contains("Marketing needs three weeks' notice"))
        #expect(md.contains("Nobody confirmed the QA sign-off date"))
        #expect(md.contains("Who owns the app store listing?"))
        #expect(md.contains("“last weak” → “last week”"))
        #expect(md.contains("### Rishi"))
        #expect(md.contains("- **Type:** Online (Zoom)"))
        #expect(md.contains("- **Duration:** 1 h 2 min"))
    }

    @Test("The transcript uses display names, timestamps, locale tags and inline corrections, in time order")
    func transcriptLines() throws {
        let md = ReportRenderer.markdown(sampleMeeting())
        let transcript = try #require(md.components(separatedBy: "## Transcript").last)
        let remote = try #require(transcript.range(of: "**[00:03] Remote | 1** `en-US`: Can everyone hear me?"))
        let rishi = try #require(transcript.range(of: "**[01:05] Rishi** `en-IN`: We finished the payment integration last weak."))
        let late = try #require(transcript.range(of: "**[1:01:40] Speaker 1** `en-GB`: Let's wrap up."))
        #expect(remote.lowerBound < rishi.lowerBound && rishi.lowerBound < late.lowerBound)
        #expect(transcript.contains("> *Correction:* “We finished the payment integration last week.” — Likely recognition error"))
        #expect(!transcript.contains("profile:"), "raw speaker keys must not leak into the transcript")
    }

    @Test("The participant table lists everyone, escapes pipes and marks enrolled voices")
    func participantTable() {
        let md = ReportRenderer.markdown(sampleMeeting())
        #expect(md.contains("| Rishi (enrolled) | In room | en-IN | 42° | 1 min |"))
        #expect(md.contains("| Speaker 1 | In room | en-GB | — | 30 s |"))
        #expect(md.contains("| Remote \\| 1 | Remote | en-US | — | 12 s |"))
    }

    @Test("Participants without transcript lines are left out, and the main voice model is named")
    func speakingParticipantsAndVoiceModel() {
        var m = sampleMeeting()
        // A one-second diarization blip that never produced a line.
        m.participants.append(Participant(id: "mic:9", displayName: "Speaker 2", channel: .microphone, speakingTime: 1))
        let plain = ReportRenderer.markdown(m)
        #expect(!plain.contains("Speaker 2"))
        #expect(plain.contains("- **Participants:** Rishi, Speaker 1, Remote | 1\n"))
        #expect(!plain.contains("Transcribed by"), "unknown voice model")
        #expect(ReportRenderer.speakingParticipants(m).map(\.displayName) == ["Rishi", "Speaker 1", "Remote | 1"])

        m.segments[0].engine = .apple
        m.segments[1].engine = .cohere
        m.segments[2].engine = .cohere
        #expect(ReportRenderer.markdown(m).contains("- **Transcribed by:** Cohere Transcribe\n"))
        m.segments[2].engine = nil
        // A tie goes to the engine listed first.
        #expect(ReportRenderer.transcriptionEngine(m) == .apple)
    }

    @Test("The report is asked about speakers only")
    func reportParticipantsAreSpeakers() async throws {
        var m = sampleMeeting()
        m.participants.append(Participant(id: "mic:9", displayName: "Speaker 2", channel: .microphone, speakingTime: 1))
        let engine = RecordingEngine()
        _ = try await ReportWriter.report(for: m, engine: engine, title: nil)
        #expect(engine.participants.withLock { $0 } == ["Rishi", "Speaker 1", "Remote | 1"])
    }

    @Test("A meeting without a report still renders participants and transcript")
    func noReport() {
        var m = sampleMeeting()
        m.report = nil
        let md = ReportRenderer.markdown(m)
        #expect(md.hasPrefix("# Planning\n"))
        #expect(md.contains("> No report was generated for this meeting."))
        #expect(!md.contains("## Decisions"))
        #expect(md.contains("## Transcript"))
        #expect(md.contains("Can everyone hear me?"))
    }

    @Test("Timestamps switch to hours past 59:59 and never go negative")
    func timestamps() {
        #expect(ReportRenderer.timestamp(0) == "00:00")
        #expect(ReportRenderer.timestamp(59.9) == "00:59")
        #expect(ReportRenderer.timestamp(3_599) == "59:59")
        #expect(ReportRenderer.timestamp(3_600) == "1:00:00")
        #expect(ReportRenderer.timestamp(-3) == "00:00")
    }
}

/// Records the participants a report was requested for.
private final class RecordingEngine: MeetingIntelligence {
    let participants = Mutex<[String]>([])
    var engineName: String { "Recorder" }

    func analyze(utterance: ContextLine, recentContext: [ContextLine]) async throws -> UtteranceInsight {
        UtteranceInsight(intent: .statement)
    }

    func report(transcript: [ContextLine], participants: [String], meetingTitle: String?) async throws -> MeetingReport {
        self.participants.withLock { $0 = participants }
        return MeetingReport(
            title: "", overview: "", topics: [], decisions: [], actionItems: [], notesToRemember: [], missedOpportunities: [],
            openQuestions: [], corrections: [], participantSummaries: [], generatedBy: engineName)
    }
}
