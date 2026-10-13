import Foundation
import Testing
import VCModels

@testable import VCAudio

/// Deterministic Gaussian-ish noise (sum of uniforms) at the given RMS.
private func noise(seconds: Double, sampleRate: Double, rms: Float, seed: UInt64 = 7) -> [Float] {
    var state = seed
    func uniform() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(state >> 40) / Float(1 << 24) - 0.5
    }
    // Sum of 4 uniforms on [-0.5, 0.5] has variance 1/3.
    let scale = rms / (1.0 / 3.0).squareRoot()
    return (0..<Int(seconds * sampleRate)).map { _ in (uniform() + uniform() + uniform() + uniform()) * scale }
}

/// Feeds samples as 0.25 s chunks (like the app's microphone monitor); returns the times at which it fired.
private func run(_ detector: ConversationDetector, _ samples: [Float], sampleRate: Double, startTime: Double = 0) -> [Double] {
    let step = Int(0.25 * sampleRate)
    var fired: [Double] = []
    var i = 0
    while i < samples.count {
        let piece = Array(samples[i..<min(samples.count, i + step)])
        let chunk = AudioChunk(channel: .microphone, startTime: startTime + Double(i) / sampleRate, sampleRate: sampleRate, samples: piece)
        if detector.ingest(chunk) != nil { fired.append(chunk.range.end) }
        i += step
    }
    return fired
}

/// Speech-like bursts: 1 kHz tone syllables with pauses, over a quiet noise floor.
private func bursts(seconds: Double, sampleRate: Double, on: Double, off: Double) -> [Float] {
    let floor = noise(seconds: seconds, sampleRate: sampleRate, rms: 0.002)
    return floor.indices.map { i in
        let t = Double(i) / sampleRate
        let inBurst = t.truncatingRemainder(dividingBy: on + off) < on
        return floor[i] + (inBurst ? 0.2 * Float(sin(2 * .pi * 1_000 * t)) : 0)
    }
}

@Suite("Voice activity and conversation detection")
struct ConversationDetectorTests {
    @Test("Fires on the fixture meeting (48 s of four people talking)", .enabled(if: Fixtures.hasMeeting))
    func firesOnMeeting() throws {
        let samples = try AudioResampler.load16kMono(url: Fixtures.meeting)
        let fired = run(ConversationDetector(), samples, sampleRate: 16_000)
        #expect(fired.count == 1)
        // 30 s of speech can't accumulate in less than 30 s, and the meeting is mostly speech.
        if let t = fired.first { #expect(t >= 30 && t <= 45, "fired at \(t) s") }
    }

    @Test("Never fires on digital silence")
    func silence() {
        let fired = run(ConversationDetector(), [Float](repeating: 0, count: 16_000 * 90), sampleRate: 16_000)
        #expect(fired.isEmpty)
    }

    @Test("Never fires on steady background noise, quiet or loud")
    func steadyNoise() {
        #expect(run(ConversationDetector(), noise(seconds: 90, sampleRate: 16_000, rms: 0.003), sampleRate: 16_000).isEmpty)
        #expect(run(ConversationDetector(), noise(seconds: 90, sampleRate: 48_000, rms: 0.1, seed: 3), sampleRate: 48_000).isEmpty)
    }

    @Test("Sustained speech-like bursts fire; sparse ones don't reach the quota within the window")
    func burstDensity() {
        let dense = run(ConversationDetector(), bursts(seconds: 60, sampleRate: 16_000, on: 0.6, off: 0.2), sampleRate: 16_000)
        #expect(dense.count == 1)
        let sparse = run(ConversationDetector(), bursts(seconds: 120, sampleRate: 16_000, on: 0.3, off: 1.2), sampleRate: 16_000)
        #expect(sparse.isEmpty, "≈40% activity (with hangover) never reaches 30 s within 60 s")
    }

    @Test("After firing, it needs a fresh quota of speech before firing again")
    func refireNeedsNewQuota() {
        let fired = run(ConversationDetector(), bursts(seconds: 75, sampleRate: 16_000, on: 1, off: 0.1), sampleRate: 16_000)
        #expect(fired.count == 2)
        if fired.count == 2 { #expect(fired[1] - fired[0] >= 30) }
    }

    @Test("reset() forgets accumulated speech")
    func resetForgets() {
        let detector = ConversationDetector()
        let speech = bursts(seconds: 25, sampleRate: 16_000, on: 1, off: 0.1)
        #expect(run(detector, speech, sampleRate: 16_000).isEmpty)
        detector.reset()
        #expect(run(detector, speech, sampleRate: 16_000, startTime: 25).isEmpty, "25 s + 25 s would have fired without reset")
    }

    @Test("The VAD's noise floor adapts to a level change and stops flagging it")
    func floorAdapts() {
        var vad = VoiceActivityDetector()
        let quiet = noise(seconds: 5, sampleRate: 16_000, rms: 0.001)
        _ = vad.process(quiet, sampleRate: 16_000)
        let loud = noise(seconds: 60, sampleRate: 16_000, rms: 0.05, seed: 9)
        let decisions = vad.process(loud, sampleRate: 16_000)
        #expect(decisions.prefix(10).allSatisfy { $0 }, "a sudden level jump looks like activity at first")
        #expect(decisions.suffix(500).allSatisfy { !$0 }, "after adapting, steady noise is not speech")
        #expect(abs((vad.noiseFloorDB ?? 0) - 20 * log10(0.05)) < 3)
    }
}
