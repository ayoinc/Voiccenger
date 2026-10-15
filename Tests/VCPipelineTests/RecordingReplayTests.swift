import Foundation
import Testing
import VCModels

@testable import VCPipeline

/// `MeetingSession.processRecording` on a meeting folder recorded on two channels: synthetic speech from
/// `scripts/MakeFixtures.swift`, generated into a temporary directory, with two speakers in the room
/// (`microphone.wav`) and two remote (`system.wav`), written as the app records them (48 kHz, 16-bit).
/// Needs the speech and diarization models, so it only runs when `VOICCENGER_INTEGRATION=1`.
@Suite("Recording replay", .serialized)
struct RecordingReplayTests {
    static var enabled: Bool { ProcessInfo.processInfo.environment["VOICCENGER_INTEGRATION"] == "1" }

    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let inRoom: Set<String> = ["Daniel", "Samantha"]

    private struct Truth: Decodable {
        let speaker: String
        let start: Double
        let end: Double
    }

    /// Runs the fixture generator into `directory`.
    private static func generateFixtures(into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", repo.appending(path: "scripts/MakeFixtures.swift").path, directory.path]
        process.currentDirectoryURL = repo
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "MakeFixtures.swift failed")
    }

    @MainActor
    @Test(
        "Microphone and computer audio replay together: remote speech becomes .system lines, the room's .microphone",
        .enabled(if: enabled), .timeLimit(.minutes(15)))
    func twoChannelReplay() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "vc-replay-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = root.appending(path: "fixtures", directoryHint: .isDirectory)
        try Self.generateFixtures(into: fixtures)

        // Split the scripted meeting by who is where; each channel is silent while the other side talks.
        let meeting16k = try AudioResampler.load16kMono(url: fixtures.appending(path: "meeting.wav"))
        let truth = try JSONDecoder().decode([Truth].self, from: Data(contentsOf: fixtures.appending(path: "meeting.truth.json")))
        var mic = [Float](repeating: 0, count: meeting16k.count)
        var system = mic
        for turn in truth {
            let range = Int(turn.start * 16_000)..<min(meeting16k.count, Int(turn.end * 16_000))
            if Self.inRoom.contains(turn.speaker) {
                mic.replaceSubrange(range, with: meeting16k[range])
            } else {
                system.replaceSubrange(range, with: meeting16k[range])
            }
        }
        let id = UUID()
        let meetings = root.appending(path: "meetings", directoryHint: .isDirectory)
        let folder = meetings.appending(path: id.uuidString, directoryHint: .isDirectory)
        for (channel, samples) in [(AudioChannel.microphone, mic), (.system, system)] {
            let recorder = try AudioRecorder(url: folder.appending(path: "\(channel.rawValue).wav"), sampleRate: 48_000)
            recorder.append(AudioChunk(channel: channel, startTime: 0, sampleRate: 16_000, samples: samples))
            recorder.close()
        }
        let sizes = try ["microphone.wav", "system.wav"].map {
            try FileManager.default.attributesOfItem(atPath: folder.appending(path: $0).path)[.size] as? Int
        }

        let store = SpeakerProfileStore(directory: root.appending(path: "profiles"))
        try await SpeakerModels.prepare()
        for name in ["Daniel", "Samantha", "Rishi", "Karen"] {
            let samples = try AudioResampler.load16kMono(url: fixtures.appending(path: "enroll_\(name).wav"))
            _ = try await EnrollmentService.enroll(name: name, samples16k: samples, store: store)
        }

        let started = Date(timeIntervalSinceReferenceDate: 810_000_000)
        let config = MeetingSession.Config(
            localeID: "en-GB", autoLanguage: false, engineKind: .transcriptOutline, meetingsDirectory: meetings,
            liveAnalysis: false)
        var phases: [ProcessingProgress] = []
        let meeting = try await MeetingSession.processRecording(
            directory: folder, config: config, profiles: await store.all(), startedAt: started
        ) { phases.append($0) }

        // Saved in the recording's own folder, under its id; the recordings are untouched.
        #expect(meeting.id == id)
        let saved = try await MeetingStore(directory: meetings).meeting(id: id)
        #expect(saved.segments == meeting.segments)
        #expect(try ["microphone.wav", "system.wav"].map {
            try FileManager.default.attributesOfItem(atPath: folder.appending(path: $0).path)[.size] as? Int
        } == sizes)
        #expect(meeting.audioFiles == ["microphone.wav", "system.wav"])
        #expect(meeting.startedAt == started)
        #expect(meeting.duration > 40 && meeting.duration < 60, "the meeting lasts as long as its audio")
        #expect(meeting.kind == .online, "speech on the computer's audio makes it an online meeting")
        #expect(meeting.report != nil)
        #expect(phases.contains(.writingReport) && phases.last == .saving)

        // Each line is on the channel of the turn it transcribes.
        let systemLines = meeting.segments.filter { $0.channel == .system }
        let micLines = meeting.segments.filter { $0.channel == .microphone }
        #expect(!systemLines.isEmpty, "remote speech must produce .system lines")
        #expect(!micLines.isEmpty)
        func side(of segment: TranscriptSegment) -> Bool? {
            let best = truth.max { a, b in
                segment.range.overlap(with: TimeRange(start: a.start, end: a.end))
                    < segment.range.overlap(with: TimeRange(start: b.start, end: b.end))
            }
            return best.map { Self.inRoom.contains($0.speaker) }
        }
        #expect(systemLines.allSatisfy { side(of: $0) == false })
        #expect(micLines.allSatisfy { side(of: $0) == true })
        // Remote speakers are participants on the system channel, named from their enrolled voices.
        let remote = meeting.participants.filter { p in p.channel == .system && systemLines.contains { $0.speakerKey == p.id } }
        #expect(!remote.isEmpty)
        #expect(remote.contains { ["Rishi", "Karen"].contains($0.displayName) })
    }
}
