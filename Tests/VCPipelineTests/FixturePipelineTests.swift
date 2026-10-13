import Foundation
import Testing
import VCModels

@testable import VCPipeline

/// End-to-end run of `MeetingSession.processFile` (the live pipeline fed from a file) on the generated
/// fixtures. Needs speech and diarization models (downloaded on first use), so it only runs when
/// `VOICCENGER_INTEGRATION=1` and the fixtures exist.
@Suite("Fixture pipeline", .serialized)
struct FixturePipelineTests {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: ".fixtures", directoryHint: .isDirectory)
    static let voices = ["Daniel", "Samantha", "Rishi", "Karen"]

    static var enabled: Bool {
        ProcessInfo.processInfo.environment["VOICCENGER_INTEGRATION"] == "1"
            && FileManager.default.fileExists(atPath: fixtures.appending(path: "meeting.wav").path)
            && FileManager.default.fileExists(atPath: fixtures.appending(path: "meeting.truth.json").path)
    }

    private struct Truth: Decodable {
        let start: Double
        let end: Double
        let speaker: String
    }

    @MainActor
    @Test("Enrolled voices are named on the right turns of the fixture meeting", .enabled(if: enabled), .timeLimit(.minutes(10)))
    func meetingAttribution() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "vc-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpeakerProfileStore(directory: root.appending(path: "profiles"))
        try await SpeakerModels.prepare()
        for name in Self.voices {
            let samples = try AudioResampler.load16kMono(url: Self.fixtures.appending(path: "enroll_\(name).wav"))
            _ = try await EnrollmentService.enroll(name: name, samples16k: samples, store: store, accentCandidates: [])
        }
        let profiles = await store.all()
        #expect(profiles.count == 4)

        let config = MeetingSession.Config(
            title: "Fixture", localeID: "en-GB", autoLanguage: false, recordAudio: false,
            meetingsDirectory: root.appending(path: "meetings"), liveAnalysis: false)
        let meeting = try await MeetingSession.processFile(
            url: Self.fixtures.appending(path: "meeting.wav"), config: config, profiles: profiles)

        #expect(!meeting.segments.isEmpty)
        #expect(meeting.duration > 40 && meeting.duration < 60, "offline meetings last as long as their audio")
        let saved = try await MeetingStore(directory: config.meetingsDirectory).meeting(id: meeting.id)
        #expect(saved.segments == meeting.segments)

        // Per true turn, the speaker credited with most transcript time inside it.
        let truth = try JSONDecoder().decode(
            [Truth].self, from: Data(contentsOf: Self.fixtures.appending(path: "meeting.truth.json")))
        var correct = 0
        for t in truth {
            var credit: [String: Double] = [:]
            for s in meeting.segments {
                let overlap = s.range.overlap(with: TimeRange(start: t.start, end: t.end))
                if overlap > 0 { credit[ReportRenderer.displayName(for: s.speakerKey, in: meeting), default: 0] += overlap }
            }
            if credit.max(by: { $0.value < $1.value })?.key == t.speaker { correct += 1 }
        }
        let accuracy = Double(correct) / Double(truth.count)
        #expect(accuracy >= 0.7, "per-turn speaker accuracy \(correct)/\(truth.count)")
    }
}
