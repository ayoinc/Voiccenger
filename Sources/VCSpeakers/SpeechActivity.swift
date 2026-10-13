import Accelerate
import Foundation

/// Energy voice-activity detection used for enrollment clips: 20 ms frames, adaptive threshold
/// (10 dB over the noise floor, capped 20 dB under the loud end, never below −50 dBFS) and a
/// 100 ms hangover on both sides so word onsets and tails survive.
enum SpeechActivity {
    static let frameSeconds = 0.02
    static let hangoverFrames = 5

    /// Per-frame speech flags; frame `i` covers samples `i*frameLength ..< (i+1)*frameLength`.
    static func speechFrames(_ samples: [Float], sampleRate: Double) -> (flags: [Bool], frameLength: Int) {
        let frameLength = max(1, Int(sampleRate * frameSeconds))
        let frameCount = samples.count / frameLength
        guard frameCount > 0 else { return ([], frameLength) }

        var levels = [Float](repeating: 0, count: frameCount)
        samples.withUnsafeBufferPointer { buffer in
            for i in 0..<frameCount {
                let frame = UnsafeBufferPointer(rebasing: buffer[(i * frameLength)..<((i + 1) * frameLength)])
                levels[i] = 10 * log10(vDSP.meanSquare(frame) + 1e-12)
            }
        }

        let sorted = levels.sorted()
        let floor = sorted[sorted.count / 10]
        let loud = sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
        let threshold = max(-60, min(max(-50, floor + 10), loud - 20))

        let raw = levels.map { $0 > threshold }
        var flags = raw
        for i in raw.indices where raw[i] {
            let lo = max(0, i - hangoverFrames)
            let hi = min(raw.count - 1, i + hangoverFrames)
            for j in lo...hi { flags[j] = true }
        }
        return (flags, frameLength)
    }

    /// The clip with non-speech frames removed (speech regions concatenated in order).
    static func compactSpeech(_ samples: [Float], sampleRate: Double) -> [Float] {
        let (flags, frameLength) = speechFrames(samples, sampleRate: sampleRate)
        var out: [Float] = []
        out.reserveCapacity(samples.count)
        for (i, isSpeech) in flags.enumerated() where isSpeech {
            out.append(contentsOf: samples[(i * frameLength)..<((i + 1) * frameLength)])
        }
        return out
    }
}
