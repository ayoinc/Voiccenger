import AVFAudio
import Foundation
import Testing
import VCModels

@testable import VCPipeline

/// The journal, unsaved-recording detection and the quit flow that keep a meeting from being lost.
@Suite("Meeting recovery")
struct MeetingRecoveryTests {
    private static func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "vc-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func segment(_ channel: AudioChannel, _ key: String, _ start: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(
            channel: channel, speakerKey: key, range: TimeRange(start: start, end: start + 2), text: text, confidence: 0.9,
            localeID: "en-GB", engine: .cohere)
    }

    /// A 16-bit mono WAV of `seconds` of a quiet tone, as `AudioRecorder` writes it.
    private static func writeWAV(_ url: URL, seconds: Double, sampleRate: Double = 16_000) throws {
        let recorder = try AudioRecorder(url: url, sampleRate: sampleRate)
        let n = Int(seconds * sampleRate)
        recorder.append(
            AudioChunk(
                channel: .microphone, startTime: 0, sampleRate: sampleRate,
                samples: (0..<n).map { Float(sin(Double($0) * 0.05) * 0.1) }))
        recorder.close()
    }

    // MARK: Journal

    @Test("A journal replays to the meeting it recorded: re-transcribed lines replace, removed lines go, rekeys apply")
    func journalRoundTrip() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let journal = try MeetingJournal(directory: dir)
        journal.append(
            .header(.init(meetingID: id, title: nil, kind: .inPerson, appName: nil, startedAt: start, localeIDs: ["en-GB"])))
        var first = Self.segment(.microphone, "mic-1", 1, "first")
        let bleed = Self.segment(.microphone, "mic-1", 5, "bleed")
        let remote = Self.segment(.system, "sys-1", 5, "remote")
        journal.append(.segment(first))
        journal.append(.participants([Participant(id: "mic-1", displayName: "Speaker 1", channel: .microphone)]))
        journal.append(.segment(bleed))
        journal.append(.segment(remote))
        journal.append(.removed([bleed.id]))
        first.text = "first, re-transcribed"
        journal.append(.segment(first))
        journal.append(.rekey(from: "mic-1", to: "profile:X"))
        journal.append(.participants([Participant(id: "profile:X", displayName: "Ada", channel: .microphone)]))
        // The app became an online meeting mid-recording.
        journal.append(
            .header(.init(meetingID: id, title: nil, kind: .online, appName: "Zoom", startedAt: start, localeIDs: ["en-GB"])))
        journal.close()

        let replay = try MeetingJournal.replay(journal.url)
        #expect(replay.unreadableLines == 0)
        #expect(replay.segments.map(\.text) == ["first, re-transcribed", "remote"])
        #expect(replay.segments.map(\.speakerKey) == ["profile:X", "sys-1"])
        // The remote speaker had no roster entry yet: one is made for them.
        #expect(replay.participants.map(\.id) == ["profile:X", "sys-1"])
        #expect(replay.participants.last?.channel == .system)

        let meeting = replay.meeting(id: id, startedAt: Date(), audioFiles: ["microphone.wav"])
        #expect(meeting.id == id)
        #expect(meeting.kind == .online)
        #expect(meeting.appName == "Zoom")
        #expect(meeting.startedAt == start)
        #expect(meeting.endedAt == start.addingTimeInterval(7))
        #expect(meeting.title.hasPrefix("Zoom meeting, "))
        #expect(meeting.audioFiles == ["microphone.wav"])
    }

    @Test("A write cut short by a crash loses only that line")
    func truncatedJournal() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try MeetingJournal(directory: dir)
        journal.append(.segment(Self.segment(.microphone, "mic-1", 0, "kept")))
        journal.close()
        let handle = try FileHandle(forWritingTo: journal.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"segment":{"channel":"micro"#.utf8))
        try handle.close()

        let replay = try MeetingJournal.replay(journal.url)
        #expect(replay.segments.map(\.text) == ["kept"])
        #expect(replay.unreadableLines == 1)
    }

    @Test("Saving the meeting deletes its journal")
    func saveDeletesJournal() async throws {
        let root = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(directory: root)
        let meeting = Meeting(title: "Saved", kind: .inPerson)
        let journal = try MeetingJournal(directory: store.directory(for: meeting.id))
        journal.append(.segment(Self.segment(.microphone, "mic-1", 0, "line")))
        #expect(FileManager.default.fileExists(atPath: journal.url.path))
        try await store.save(meeting)
        #expect(!FileManager.default.fileExists(atPath: journal.url.path))
        #expect(try await store.meeting(id: meeting.id).title == "Saved")
    }

    // MARK: Unsaved recordings

    @Test("Unsaved recordings: folders with audio or a journal and no meeting.json, except the one recording")
    func orphanDetection() async throws {
        let root = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(directory: root)
        func folder(_ id: UUID = UUID()) throws -> URL {
            let dir = store.directory(for: id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        // Saved: not unsaved, audio or not.
        let saved = Meeting(title: "Saved", kind: .inPerson)
        try Self.writeWAV(try folder(saved.id).appending(path: "microphone.wav"), seconds: 1)
        try await store.save(saved)
        // Audio only, both channels: duration is the longer one.
        let audio = try folder()
        try Self.writeWAV(audio.appending(path: "microphone.wav"), seconds: 2)
        try Self.writeWAV(audio.appending(path: "system.wav"), seconds: 3)
        // A journal only (recording audio was off).
        let journaled = try folder()
        let journal = try MeetingJournal(directory: journaled)
        let journalStart = Date(timeIntervalSinceReferenceDate: 790_000_000)
        journal.append(
            .header(.init(meetingID: UUID(), title: nil, kind: .inPerson, appName: nil, startedAt: journalStart, localeIDs: [])))
        journal.append(.segment(Self.segment(.microphone, "mic-1", 10, "line")))
        journal.close()
        // Nothing worth recovering: an empty recording, a journal without lines, an empty folder.
        try Self.writeWAV(try folder().appending(path: "microphone.wav"), seconds: 0)
        let headerOnly = try MeetingJournal(directory: try folder())
        headerOnly.append(
            .header(.init(meetingID: UUID(), title: nil, kind: .inPerson, appName: nil, startedAt: Date(), localeIDs: [])))
        headerOnly.close()
        _ = try folder()
        // Not a meeting folder.
        let stray = root.appending(path: "Not a meeting", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try Self.writeWAV(stray.appending(path: "microphone.wav"), seconds: 1)
        // The meeting recording now.
        let activeID = UUID()
        try Self.writeWAV(try folder(activeID).appending(path: "microphone.wav"), seconds: 1)

        let found = store.unsavedRecordings(excluding: activeID)
        #expect(Set(found.map(\.directory.lastPathComponent)) == [audio.lastPathComponent, journaled.lastPathComponent])
        let fromAudio = try #require(found.first { $0.id.uuidString == audio.lastPathComponent })
        #expect(fromAudio.audioFiles == ["microphone.wav", "system.wav"])
        #expect(abs(fromAudio.duration - 3) < 0.01)
        #expect(!fromAudio.hasJournal)
        let fromJournal = try #require(found.first { $0.id.uuidString == journaled.lastPathComponent })
        #expect(fromJournal.hasJournal)
        #expect(fromJournal.audioFiles.isEmpty)
        #expect(fromJournal.startedAt == journalStart)
        #expect(fromJournal.duration == 12)
        // Without the exclusion the recording meeting shows; a quiet period leaves out folders written just now.
        #expect(store.unsavedRecordings().count == 3)
        #expect(store.unsavedRecordings(quietFor: 60).isEmpty)
        #expect(store.unsavedRecordings(quietFor: 60, now: Date().addingTimeInterval(120)).count == 3)
    }

    @Test("A recording whose app crashed (header never finalized) is found with its length, then repaired")
    func crashedRecording() throws {
        let root = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "microphone.wav")
        try Self.writeWAV(url, seconds: 2)
        // What a crash leaves: the audio, with the RIFF and data sizes as they were when the file was opened.
        let info = try WAVHeader.read(url)
        #expect(!info.needsRepair)
        let handle = try FileHandle(forUpdating: url)
        try handle.seek(toOffset: info.dataOffset - 4)
        try handle.write(contentsOf: Data([0, 0, 0, 0]))
        try handle.close()
        #expect(try AVAudioFileLength(url) == 0)

        let recording = try #require(UnsavedRecording.inspect(dir))
        #expect(abs(recording.duration - 2) < 0.01)
        #expect(try WAVHeader.read(url).needsRepair)
        #expect(try WAVHeader.repair(url))
        #expect(try !WAVHeader.repair(url))
        #expect(try AVAudioFileLength(url) == 32_000)
    }

    // MARK: Quitting

    @Test("Quitting while recording waits for the save, then quits")
    func quitWhileRecording() {
        var flow = TerminationFlow(cap: 120)
        let now = Date()
        let (reply, action) = flow.requestQuit(session: .recording, now: now)
        #expect(reply == .terminateLater)
        #expect(action == .stopAndSave)
        #expect(flow.remaining(now: now.addingTimeInterval(20)) == 100)
        #expect(flow.tick(now: now.addingTimeInterval(60)) == nil)
        // Asked again while waiting: still waiting, nothing new to do.
        #expect(flow.requestQuit(session: .finishing, now: now).reply == .terminateLater)
        #expect(flow.requestQuit(session: .finishing, now: now).action == nil)
        #expect(flow.saveEnded() == .quit)
        #expect(flow.phase == .done)
        #expect(flow.requestQuit(session: .finished, now: now).reply == .terminateNow)
    }

    @Test("Quitting while the meeting is already saving waits for that save; at the cap, what's there is saved")
    func quitWhileFinishingHitsCap() {
        var flow = TerminationFlow(cap: 120)
        let now = Date()
        #expect(flow.requestQuit(session: .finishing, now: now) == (.terminateLater, .awaitSave))
        #expect(flow.tick(now: now.addingTimeInterval(119)) == nil)
        #expect(flow.tick(now: now.addingTimeInterval(120)) == .saveSnapshot)
        #expect(flow.phase == .savingSnapshot)
        #expect(flow.tick(now: now.addingTimeInterval(200)) == nil)
        #expect(flow.remaining(now: now) == nil)
        #expect(flow.saveEnded() == .quit)
    }

    @Test("Quit Now saves what's transcribed; a recording still starting is stopped too; no meeting quits at once")
    func quitNowAndIdle() {
        var flow = TerminationFlow()
        #expect(flow.requestQuit(session: .starting, now: Date()) == (.terminateLater, .stopAndSave))
        #expect(flow.quitNow() == .saveSnapshot)
        #expect(flow.quitNow() == nil)
        #expect(flow.saveEnded() == .quit)

        for state: MeetingSession.State? in [nil, .idle, .finished, .failed("x")] {
            var idle = TerminationFlow()
            #expect(idle.requestQuit(session: state, now: Date()) == (.terminateNow, nil))
            #expect(idle.saveEnded() == nil)
        }
    }

    // MARK: Pacing

    @Test("Offline channels replay on one clock: nothing is forwarded more than the lead ahead of the slowest consumer")
    func pacer() {
        let pacer = ReplayPacer(lead: 4)
        #expect(!pacer.mayForward(0), "nothing moves until every consumer is registered")
        let mic = pacer.register()
        let system = pacer.register()
        pacer.open()
        #expect(pacer.mayForward(4))
        #expect(!pacer.mayForward(4.1))
        pacer.consumed(mic, through: 30)
        #expect(!pacer.mayForward(5), "the system channel's consumer holds the microphone back")
        pacer.consumed(system, through: 10)
        #expect(pacer.mayForward(14))
        #expect(!pacer.mayForward(14.1))
        pacer.finish(system)
        #expect(pacer.mayForward(34) && !pacer.mayForward(34.1), "a finished consumer holds nothing back")
        pacer.finish(mic)
        #expect(pacer.mayForward(10_000))
    }
}

/// Frames AVFoundation reads from `url` (what every player and the pipeline see).
private func AVAudioFileLength(_ url: URL) throws -> Int64 {
    try AVAudioFile(forReading: url).length
}
