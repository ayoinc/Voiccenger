import Foundation

/// Deterministic SplitMix64 generator: identical sequences for identical seeds on every platform.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) * 0x1p-53
    }

    /// Standard normal sample (Box–Muller).
    public mutating func nextGaussian() -> Double {
        let u1 = max(nextUnit(), .leastNonzeroMagnitude)
        let u2 = nextUnit()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// Reproducible excitation signals for array simulation and demos.
public enum SignalGenerator {
    /// Pink (1/f) noise via Paul Kellet's refined filter, scaled to `rms`.
    public static func pinkNoise(count: Int, seed: UInt64 = 1, rms: Float = 0.1) -> [Float] {
        guard count > 0 else { return [] }
        var random = SeededGenerator(seed: seed)
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0
        var output = [Float](repeating: 0, count: count)
        for n in 0..<count {
            let white = random.nextGaussian()
            b0 = 0.99886 * b0 + white * 0.0555179
            b1 = 0.99332 * b1 + white * 0.0750759
            b2 = 0.96900 * b2 + white * 0.1538520
            b3 = 0.86650 * b3 + white * 0.3104856
            b4 = 0.55000 * b4 + white * 0.5329522
            b5 = -0.7616 * b5 - white * 0.0168980
            output[n] = Float(b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362)
            b6 = white * 0.115926
        }
        return scaled(output, toRMS: rms)
    }

    /// Pink noise shaped into syllable-like bursts (120–300 ms raised-cosine envelopes separated by
    /// 30–150 ms gaps, with an occasional longer pause), approximating the on/off structure and
    /// spectral tilt of running speech. Scaled to `rms`.
    public static func speechLike(count: Int, sampleRate: Double, seed: UInt64 = 1, rms: Float = 0.1) -> [Float] {
        guard count > 0, sampleRate > 0 else { return [] }
        let noise = pinkNoise(count: count, seed: seed, rms: 1)
        var random = SeededGenerator(seed: seed &+ 0x5BEEC4)
        var envelope = [Float](repeating: 0, count: count)
        var position = Int(0.02 * sampleRate)
        while position < count {
            let syllable = Int((0.12 + 0.18 * random.nextUnit()) * sampleRate)
            let level = Float(0.4 + 0.6 * random.nextUnit())
            for n in 0..<syllable where position + n < count {
                let phase = Double(n) / Double(max(1, syllable - 1))
                envelope[position + n] = level * Float(0.5 - 0.5 * cos(2 * .pi * phase))
            }
            let longPause = random.nextUnit() < 0.15
            let gap = longPause ? 0.25 + 0.2 * random.nextUnit() : 0.03 + 0.12 * random.nextUnit()
            position += syllable + Int(gap * sampleRate)
        }
        return scaled(zip(noise, envelope).map { $0 * $1 }, toRMS: rms)
    }

    /// Pure sine tone.
    public static func tone(frequency: Double, count: Int, sampleRate: Double, amplitude: Float = 0.1) -> [Float] {
        guard count > 0, sampleRate > 0 else { return [] }
        let step = 2 * Double.pi * frequency / sampleRate
        return (0..<count).map { amplitude * Float(sin(step * Double($0))) }
    }

    private static func scaled(_ signal: [Float], toRMS rms: Float) -> [Float] {
        let power = signal.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, signal.count))
        guard power > 0 else { return signal }
        let gain = rms / Float(power.squareRoot())
        return signal.map { $0 * gain }
    }
}
