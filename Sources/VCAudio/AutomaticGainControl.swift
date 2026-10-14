import Accelerate
import Foundation
import VCModels

/// Slow automatic gain control with a peak limiter, so quiet system audio (an HDMI monitor's tap measured
/// −41 dBFS speech RMS against −19 dBFS on the built-in speakers) reaches transcription and speaker
/// identification at a consistent level. Pure value type; recordings keep the raw audio.
///
/// Only speech moves the gain: each 20 ms block is classified by a `VoiceActivityDetector` (absolute floor
/// −55 dBFS, so −41 dBFS speech counts), speech blocks update a power average of the speech level
/// (`levelTimeConstant`), and the gain glides towards `targetDB − level` at most `slewDBPerSecond`, within
/// `minimumGainDB...maximumGainDB`. Silence and noise hold the gain. A limiter with instant attack and
/// `limiterRelease` keeps every sample within `ceiling`.
public struct AutomaticGainControl: Sendable {
    public var targetDB: Double = -20
    public var maximumGainDB: Double = 30
    public var minimumGainDB: Double = -20
    /// Speech-level averaging time; the first `warmUpSeconds` of speech use `warmUpTimeConstant`.
    public var levelTimeConstant: TimeInterval = 3
    public var warmUpSeconds: TimeInterval = 1
    public var warmUpTimeConstant: TimeInterval = 0.3
    public var slewDBPerSecond: Double = 10
    /// Peak ceiling (−1 dBFS).
    public var ceiling: Float = 0.891
    public var limiterRelease: TimeInterval = 0.2
    public var blockDuration: TimeInterval = 0.02

    /// Current gain in dB (excluding the limiter).
    public private(set) var gainDB: Double = 0
    /// Estimated speech level in dBFS (nil before any speech).
    public var speechLevelDB: Double? { speechPower.map { 10 * log10(max($0, 1e-12)) } }

    private var vad = VoiceActivityDetector()
    private var speechPower: Double?
    private var speechSeconds: TimeInterval = 0
    private var limiterGain: Float = 1

    public init() {}

    /// The chunk with gain and limiting applied (same timing and channel; `channelSamples` dropped).
    public mutating func process(_ chunk: AudioChunk) -> AudioChunk {
        AudioChunk(
            channel: chunk.channel, startTime: chunk.startTime, sampleRate: chunk.sampleRate,
            samples: process(chunk.samples, sampleRate: chunk.sampleRate))
    }

    public mutating func process(_ samples: [Float], sampleRate: Double) -> [Float] {
        guard sampleRate > 0, !samples.isEmpty else { return samples }
        vad.frameDuration = blockDuration
        let blockLength = max(1, Int(blockDuration * sampleRate))
        let release = Float(1 - exp(-1 / (limiterRelease * sampleRate)))
        var out = [Float](repeating: 0, count: samples.count)
        samples.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                var start = 0
                while start < src.count {
                    let end = min(src.count, start + blockLength)
                    let block = UnsafeBufferPointer(rebasing: src[start..<end])
                    let seconds = Double(end - start) / sampleRate
                    let power = Double(vDSP.meanSquare(block))
                    let before = gainDB
                    if vad.classify(energyDB: 10 * log10(max(power, 1e-12))) {
                        adapt(power: power, seconds: seconds)
                    }
                    // Ramp the gain across the block so changes don't click.
                    let g0 = Float(pow(10, before / 20)), g1 = Float(pow(10, gainDB / 20))
                    let step = (g1 - g0) / Float(end - start)
                    for i in start..<end {
                        let y = src[i] * (g0 + step * Float(i - start + 1))
                        let magnitude = abs(y)
                        if magnitude * limiterGain > ceiling {
                            limiterGain = ceiling / magnitude
                        } else {
                            limiterGain += (1 - limiterGain) * release
                        }
                        dst[i] = min(ceiling, max(-ceiling, y * limiterGain))
                    }
                    start = end
                }
            }
        }
        return out
    }

    private mutating func adapt(power: Double, seconds: TimeInterval) {
        let tau = speechSeconds < warmUpSeconds ? warmUpTimeConstant : levelTimeConstant
        speechSeconds += seconds
        if let current = speechPower {
            speechPower = current + (power - current) * min(1, seconds / tau)
        } else {
            speechPower = power
        }
        guard let level = speechLevelDB else { return }
        let desired = min(maximumGainDB, max(minimumGainDB, targetDB - level))
        let maxStep = slewDBPerSecond * seconds
        gainDB += min(maxStep, max(-maxStep, desired - gainDB))
    }
}

/// Time ranges of a chunk stream that carry speech, from `VoiceActivityDetector` frames (30 ms) with adjacent
/// speech frames joined. Pure value type.
public struct SpeechSpanDetector: Sendable {
    private var vad = VoiceActivityDetector()
    private var pending: [Float] = []
    private var pendingStart: TimeInterval = 0
    private var sampleRate: Double = 0

    public init() {}

    /// Speech ranges completed by `chunk` (frames straddling chunk boundaries are classified with the next chunk).
    public mutating func spans(in chunk: AudioChunk) -> [TimeRange] {
        guard chunk.sampleRate > 0 else { return [] }
        let expected = pendingStart + Double(pending.count) / max(sampleRate, 1)
        if chunk.sampleRate != sampleRate || abs(chunk.startTime - expected) > 0.05 {
            sampleRate = chunk.sampleRate
            pending = []
            pendingStart = chunk.startTime
        }
        pending.append(contentsOf: chunk.samples)
        let frameLength = max(1, Int((vad.frameDuration * sampleRate).rounded()))
        let frames = pending.count / frameLength
        guard frames > 0 else { return [] }
        let decisions = vad.process(Array(pending[0..<(frames * frameLength)]), sampleRate: sampleRate)
        let frameSeconds = Double(frameLength) / sampleRate
        var spans: [TimeRange] = []
        for (i, speech) in decisions.enumerated() where speech {
            let start = pendingStart + Double(i) * frameSeconds
            if let last = spans.last, abs(last.end - start) < 1e-6 {
                spans[spans.count - 1].end = start + frameSeconds
            } else {
                spans.append(TimeRange(start: start, end: start + frameSeconds))
            }
        }
        pending.removeFirst(frames * frameLength)
        pendingStart += Double(frames) * frameSeconds
        return spans
    }
}
