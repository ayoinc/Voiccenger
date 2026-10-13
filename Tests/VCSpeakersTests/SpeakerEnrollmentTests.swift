import Foundation
import Testing
@testable import VCSpeakers

@Suite("SpeakerEnrollment")
struct SpeakerEnrollmentTests {
    /// Voice-like test signal: a 150 Hz tone with harmonics, gated on/off like syllables.
    static func voicedBurst(seconds: Double) -> [Float] {
        (0..<Int(16_000 * seconds)).map { i in
            let t = Double(i) / 16_000
            let gate = sin(2 * .pi * 3 * t) > -0.3 ? 1.0 : 0.15
            return Float(gate * 0.2 * (sin(2 * .pi * 150 * t) + 0.5 * sin(2 * .pi * 300 * t) + 0.25 * sin(2 * .pi * 450 * t)))
        }
    }

    @Test func rejectsClipWithTooLittleSpeechEvenIfLong() async {
        let clip = [Float](repeating: 0, count: 16_000 * 4) + Self.voicedBurst(seconds: 3)
            + [Float](repeating: 0, count: 16_000 * 8)
        await #expect {
            _ = try await SpeakerEnrollment.embeddings(samples16k: clip)
        } throws: { error in
            guard case .insufficientSpeech(let seconds, let required) = error as? SpeakerEnrollmentError else { return false }
            // 3 s of voice plus VAD hangover, well short of the 5 s requirement.
            return seconds > 2.8 && seconds < 3.6 && required == 5
        }
    }

    @Test func rejectsSilenceAndEmptyInput() async {
        for clip in [[Float](repeating: 0, count: 16_000 * 20), []] {
            await #expect(throws: SpeakerEnrollmentError.self) {
                _ = try await SpeakerEnrollment.embeddings(samples16k: clip)
            }
        }
    }

    @Test func insufficientSpeechErrorExplainsWhatToDo() {
        let message = SpeakerEnrollmentError.insufficientSpeech(seconds: 3.2, required: 5).errorDescription ?? ""
        #expect(message.contains("3.2"))
        #expect(message.contains("5 s"))
    }

    @Test(arguments: [16_000 * 5, 16_000 * 7, 16_000 * 19 + 123])
    func windowsOverlapByHalfAndCoverTheWholeClip(count: Int) {
        let windows = SpeakerEnrollment.windows(count: count)
        let length = 16_000 * 5
        #expect(windows.first?.lowerBound == 0)
        #expect(windows.allSatisfy { $0.count == length })
        // Nothing longer than a quarter window is left uncovered at the end.
        #expect(count - (windows.last?.upperBound ?? 0) <= length / 4)
        for (a, b) in zip(windows, windows.dropFirst()) {
            #expect(b.lowerBound - a.lowerBound <= length / 2)
        }
    }

    @Test(.enabled { await Fixtures.modelsAndFixturesAvailable() })
    func fixtureClipYieldsSeveralUnitEmbeddings() async throws {
        let clip = try Fixtures.load("enroll_Daniel.wav")
        let embeddings = try await SpeakerEnrollment.embeddings(samples16k: clip.samples)
        // ~19 s clip ⇒ several overlapping 5 s windows.
        #expect(embeddings.count >= 3)
        for e in embeddings {
            #expect(e.count == 256)
            #expect(e.allSatisfy { $0.isFinite })
            let norm = e.reduce(0) { $0 + Double($1) * Double($1) }.squareRoot()
            #expect(abs(norm - 1) < 1e-3)
        }
        // Windows of one person agree with each other.
        let first = embeddings[0]
        for e in embeddings.dropFirst() {
            #expect(SpeakerMatcher.cosine(first, e) > 0.5)
        }
    }
}
