import Foundation
import Testing
import VCModels
import VCSpeakers
import VCTranscription

@testable import VCPipeline

/// Returns a fixed transcript (or fails), standing in for a voice model.
private struct ScriptedTranscriber: AccurateTranscriber {
    struct Failure: Error {}
    let kind: SpeechEngineKind
    let output: String?

    func transcribe(samples16k: [Float], languageCode: String, prompt: [String]) async throws -> EngineTranscript {
        guard let output else { throw Failure() }
        return EngineTranscript(text: output, words: nil, engine: kind, languageCode: languageCode)
    }
}

@Suite("Enrollment calibration")
struct EnrollmentCalibrationTests {
    static let expected = "Please call Stella. Ask Ngozi to bring these things with her from the store in Lekki."
    static let samples = [Float](repeating: 0, count: 16_000)

    static func transcribers(apple: String? = "Please call Stella. Ask goes to bring these things with her from the store in lucky.")
        -> [any AccurateTranscriber]
    {
        [
            ScriptedTranscriber(kind: .apple, output: apple),
            ScriptedTranscriber(kind: .whisper, output: "Please call Stella. Ask Ngozi to bring these things with her from the store in Leki."),
            ScriptedTranscriber(kind: .cohere, output: expected),
        ]
    }

    /// A temporary store holding one enrolled person.
    static func store(voice: VoiceSettings) async throws -> (SpeakerProfileStore, SpeakerProfile, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "vc-calibration-\(UUID().uuidString)")
        let store = SpeakerProfileStore(directory: dir)
        let profile = SpeakerProfile(name: "Ngozi", embeddings: [[0.25, 0.5, 0.75]], colorIndex: 2, voice: voice)
        try await store.upsert(profile)
        return (store, profile, dir)
    }

    @Test("Recalibration ranks engines by word error rate and picks the best for an automatic speaker")
    func ranksAndPicks() async throws {
        let (store, profile, dir) = try await Self.store(voice: VoiceSettings(accentRegionID: "ng", vocabulary: ["Lekki"]))
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcome = try await EnrollmentService.recalibrate(
            profileID: profile.id, samples16k: Self.samples, expected: Self.expected, store: store,
            transcribers: Self.transcribers())

        #expect(outcome.calibration.scores.map(\.engine) == [.cohere, .whisper, .apple])
        #expect(outcome.calibration.best?.wordErrorRate == 0)
        #expect(outcome.calibration.scores[1].wordErrorRate > 0)
        #expect(outcome.calibration.scores[2].wordErrorRate > outcome.calibration.scores[1].wordErrorRate)
        #expect(outcome.profile.voice.preferredEngine == .cohere)

        let saved = try #require(await store.all().first { $0.id == profile.id })
        #expect(saved.voice.calibration == outcome.calibration)
        #expect(saved.voice.preferredEngine == .cohere)
        #expect(saved.embeddings == profile.embeddings, "voice samples are untouched")
        #expect(saved.voice.accentRegionID == "ng" && saved.voice.vocabulary == ["Lekki"])
    }

    @Test("A manually chosen engine survives recalibration; one that followed the last calibration moves")
    func manualChoiceKept() async throws {
        let previous = VoiceCalibration(scores: [EngineScore(engine: .whisper, wordErrorRate: 0.03, transcript: "")])

        let (manualStore, manual, dir1) = try await Self.store(
            voice: VoiceSettings(preferredEngine: .apple, calibration: previous))
        defer { try? FileManager.default.removeItem(at: dir1) }
        let kept = try await EnrollmentService.recalibrate(
            profileID: manual.id, samples16k: Self.samples, expected: Self.expected, store: manualStore,
            transcribers: Self.transcribers())
        #expect(kept.profile.voice.preferredEngine == .apple)
        #expect(kept.profile.voice.calibration?.best?.engine == .cohere)

        let (autoStore, automatic, dir2) = try await Self.store(
            voice: VoiceSettings(preferredEngine: .whisper, calibration: previous))
        defer { try? FileManager.default.removeItem(at: dir2) }
        let moved = try await EnrollmentService.recalibrate(
            profileID: automatic.id, samples16k: Self.samples, expected: Self.expected, store: autoStore,
            transcribers: Self.transcribers())
        #expect(moved.profile.voice.preferredEngine == .cohere)
    }

    @Test("Engines that fail are left out; when all fail the profile is unchanged")
    func failures() async throws {
        let (store, profile, dir) = try await Self.store(voice: VoiceSettings(preferredEngine: .whisper))
        defer { try? FileManager.default.removeItem(at: dir) }

        let partial = try await EnrollmentService.recalibrate(
            profileID: profile.id, samples16k: Self.samples, expected: Self.expected, store: store,
            transcribers: Self.transcribers(apple: nil))
        #expect(partial.calibration.scores.map(\.engine) == [.cohere, .whisper])

        let before = try #require(await store.all().first { $0.id == profile.id })
        let none = try await EnrollmentService.recalibrate(
            profileID: profile.id, samples16k: Self.samples, expected: Self.expected, store: store,
            transcribers: [ScriptedTranscriber(kind: .cohere, output: nil)])
        #expect(none.calibration.scores.isEmpty)
        #expect(none.suggestedReplacements.isEmpty)
        #expect(none.profile.voice == before.voice)
    }

    @Test("Corrections are suggested for misheard names and places, not common words")
    func suggestions() async throws {
        let (store, profile, dir) = try await Self.store(voice: VoiceSettings(vocabulary: ["Lekki"]))
        defer { try? FileManager.default.removeItem(at: dir) }

        // The best engine still mishears the name and the place, and one common word.
        let outcome = try await EnrollmentService.recalibrate(
            profileID: profile.id, samples16k: Self.samples, expected: Self.expected, store: store,
            transcribers: [
                ScriptedTranscriber(
                    kind: .cohere, output: "Please call Stella. Ask and goes it to bring these thing with her from the store in Lucky.")
            ])
        let meant = Set(outcome.suggestedReplacements.map { $0.meant.lowercased() })
        #expect(meant.contains("ngozi"))
        #expect(meant.contains("lekki"))
        #expect(!meant.contains("things"))
        #expect(outcome.suggestedReplacements.allSatisfy { !$0.heard.isEmpty && $0.heard.lowercased() != $0.meant.lowercased() })
        // Suggestions are proposals: nothing is saved until the person accepts them.
        #expect(try #require(await store.all().first { $0.id == profile.id }).voice.replacements.isEmpty)
    }

    @Test("Recalibrating a voice that was deleted fails")
    func unknownProfile() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "vc-calibration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: EnrollmentService.EnrollmentServiceError.self) {
            try await EnrollmentService.recalibrate(
                profileID: UUID(), samples16k: Self.samples, expected: Self.expected,
                store: SpeakerProfileStore(directory: dir), transcribers: Self.transcribers())
        }
    }

    @Test("A new person's engine is the calibration's best even when settings named another")
    func newProfileTakesBest() {
        let calibration = VoiceCalibration(scores: [
            EngineScore(engine: .whisper, wordErrorRate: 0.02, transcript: ""),
            EngineScore(engine: .cohere, wordErrorRate: 0.05, transcript: ""),
        ])
        let voice = EnrollmentService.applying(calibration, to: VoiceSettings(preferredEngine: .apple), isNewProfile: true)
        #expect(voice.preferredEngine == .whisper)
        #expect(voice.calibration == calibration)
    }

    @Test("The best Deepgram model follows calibration unless the person chose another")
    func deepgramModelFollowsCalibration() {
        let first = VoiceCalibration(scores: [
            EngineScore(engine: .deepgram, wordErrorRate: 0.02, transcript: "", model: "nova-2-meeting"),
            EngineScore(engine: .cohere, wordErrorRate: 0.03, transcript: ""),
            EngineScore(engine: .deepgram, wordErrorRate: 0.04, transcript: "", model: "nova-3"),
        ])
        let calibrated = EnrollmentService.applying(first, to: VoiceSettings(), isNewProfile: true)
        #expect(calibrated.deepgramModel == "nova-2-meeting" && calibrated.preferredEngine == .deepgram)

        let second = VoiceCalibration(scores: [
            EngineScore(engine: .cohere, wordErrorRate: 0.01, transcript: ""),
            EngineScore(engine: .deepgram, wordErrorRate: 0.02, transcript: "", model: "nova-3"),
            EngineScore(engine: .deepgram, wordErrorRate: 0.03, transcript: "", model: "nova-2-meeting"),
        ])
        #expect(EnrollmentService.applying(second, to: calibrated, isNewProfile: false).deepgramModel == "nova-3")
        var chosen = calibrated
        chosen.deepgramModel = "whisper-large"
        #expect(EnrollmentService.applying(second, to: chosen, isNewProfile: false).deepgramModel == "whisper-large")
        // A calibration that scored one Deepgram model leaves the model alone.
        let single = VoiceCalibration(scores: [EngineScore(engine: .deepgram, wordErrorRate: 0.02, transcript: "", model: "nova-3")])
        #expect(EnrollmentService.applying(single, to: VoiceSettings(), isNewProfile: true).deepgramModel == nil)
    }
}
