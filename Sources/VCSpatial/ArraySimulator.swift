import Foundation
import VCModels

/// Synthesises what a microphone array records from a far-field (plane-wave) source.
///
/// Every microphone receives the source with its exact fractional propagation delay, applied as a
/// linear phase shift in the frequency domain (no interpolation error below Nyquist). Optional
/// reverberation adds a handful of decaying early reflections, each arriving as its own plane wave
/// from a random direction. Independent white Gaussian noise is added per microphone. All
/// randomness derives from `seed`, so renders are bit-for-bit reproducible.
public struct ArraySimulator: Sendable {
    public let geometry: MicArrayGeometry
    public let sampleRate: Double
    public let speedOfSound: Double

    /// Number of early reflections rendered when `reverb > 0`.
    public static let reflectionCount = 6

    public init(geometry: MicArrayGeometry, sampleRate: Double = 16_000, speedOfSound: Double = 343) {
        self.geometry = geometry
        self.sampleRate = sampleRate
        self.speedOfSound = speedOfSound
    }

    /// Renders one signal per microphone, in `geometry.mics` order, each `source.count` samples long.
    ///
    /// - Parameters:
    ///   - azimuthDegrees: source direction, counter-clockwise from the array's +x axis.
    ///   - snrDB: ratio of the source power (as received on the direct path) to the noise power on
    ///     each microphone.
    ///   - reverb: gain of the first reflection (0 = anechoic); later reflections decay from it.
    ///     Reflections arrive 4–50 ms after the direct sound.
    ///   - seed: drives reflection directions/delays and the noise.
    public func render(source: [Float], azimuthDegrees: Double, snrDB: Double, reverb: Double = 0, seed: UInt64 = 1)
        -> [[Float]]
    {
        let micCount = geometry.mics.count
        guard !source.isEmpty, micCount > 0, sampleRate > 0, speedOfSound > 0 else {
            return [[Float]](repeating: [], count: micCount)
        }
        var reflectionRandom = SeededGenerator(seed: seed ^ 0x5EED_0F_AE7E_C705)
        var taps = [Tap(delay: 0, azimuthDegrees: azimuthDegrees, gain: 1)]
        if reverb > 0 {
            for k in 0..<ArraySimulator.reflectionCount {
                taps.append(
                    Tap(
                        delay: 0.004 + 0.007 * Double(k) + 0.004 * reflectionRandom.nextUnit(),
                        azimuthDegrees: 360 * reflectionRandom.nextUnit(),
                        gain: reverb * exp(-0.35 * Double(k))))
            }
        }

        // Shift everything by the array radius so the earliest arrival has a non-negative delay.
        let radius = geometry.mics.map { hypot($0.x, $0.y) }.max() ?? 0
        let alignment = radius / speedOfSound
        let latestArrival = (taps.map(\.delay).max() ?? 0) + 2 * alignment
        let fft = RealFFT(minimumSize: source.count + Int((latestArrival * sampleRate).rounded(.up)) + 32)
        let size = fft.size
        let half = size / 2
        let spectrum = fft.forward(source)
        let totalGain = Float(taps.reduce(0) { $0 + $1.gain })
        let radiansPerSampleDelay = 2 * Double.pi / Double(size)
        let roundTripScale = 1 / Float(2 * size)

        var noiseRandom = SeededGenerator(seed: seed)
        let sourcePower = source.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(source.count)
        let noiseSigma = (sourcePower / pow(10, snrDB / 10)).squareRoot()

        return geometry.mics.map { mic in
            // Per-tap delay at this mic, in samples.
            let tapDelays: [(samples: Double, gain: Double)] = taps.map { tap in
                let a = tap.azimuthDegrees * .pi / 180
                let lead = (mic.x * cos(a) + mic.y * sin(a)) / speedOfSound
                return ((tap.delay + alignment - lead) * sampleRate, tap.gain)
            }
            var shifted = PackedSpectrum(zerosForFFTSize: size)
            shifted.re[0] = spectrum.re[0] * totalGain
            shifted.im[0] = 0  // Nyquist: a fractional delay cannot be represented on a real bin.
            for k in 1..<half {
                var hRe = 0.0
                var hIm = 0.0
                for tap in tapDelays {
                    let phase = -radiansPerSampleDelay * Double(k) * tap.samples
                    hRe += tap.gain * cos(phase)
                    hIm += tap.gain * sin(phase)
                }
                let xRe = Double(spectrum.re[k])
                let xIm = Double(spectrum.im[k])
                shifted.re[k] = Float(xRe * hRe - xIm * hIm)
                shifted.im[k] = Float(xRe * hIm + xIm * hRe)
            }
            let delayed = fft.inverse(shifted)
            var output = [Float](repeating: 0, count: source.count)
            for n in 0..<source.count {
                output[n] = delayed[n] * roundTripScale
                if noiseSigma > 0 { output[n] += Float(noiseSigma * noiseRandom.nextGaussian()) }
            }
            return output
        }
    }

    /// Renders and packages the result as a capture chunk: `channelSamples` uses the device channel
    /// layout from `geometry.channelMap` (unmapped channels are silent) and `samples` is the mean of
    /// the microphone signals.
    public func renderChunk(
        source: [Float], azimuthDegrees: Double, snrDB: Double, reverb: Double = 0, seed: UInt64 = 1,
        startTime: TimeInterval = 0, channel: AudioChannel = .microphone
    ) -> AudioChunk {
        let micSignals = render(
            source: source, azimuthDegrees: azimuthDegrees, snrDB: snrDB, reverb: reverb, seed: seed)
        var mono = [Float](repeating: 0, count: source.count)
        if !micSignals.isEmpty {
            let scale = 1 / Float(micSignals.count)
            for signal in micSignals {
                for n in signal.indices { mono[n] += signal[n] * scale }
            }
        }
        return AudioChunk(
            channel: channel, startTime: startTime, sampleRate: sampleRate, samples: mono,
            channelSamples: deviceChannels(micSignals))
    }

    /// Places per-microphone signals (in `geometry.mics` order) at their device channel indices.
    public func deviceChannels(_ micSignals: [[Float]]) -> [[Float]] {
        let length = micSignals.map(\.count).max() ?? 0
        let channelCount = (geometry.channelMap.max() ?? -1) + 1
        var channels = [[Float]](repeating: [Float](repeating: 0, count: length), count: channelCount)
        for (mic, channel) in geometry.channelMap.enumerated() where mic < micSignals.count {
            channels[channel] = micSignals[mic]
        }
        return channels
    }

    /// Far-field time difference of arrival `t_j − t_i` in seconds (positive = mic `j` hears the
    /// source after mic `i`), the quantity `GCCPHAT.tdoa(mic_i, mic_j, …)` estimates.
    public func tdoa(from i: Int, to j: Int, azimuthDegrees: Double) -> Double {
        let a = azimuthDegrees * .pi / 180
        let pi = geometry.mics[i]
        let pj = geometry.mics[j]
        return ((pi.x - pj.x) * cos(a) + (pi.y - pj.y) * sin(a)) / speedOfSound
    }

    /// Frequency above which a pair spaced `micSpacing` metres apart aliases spatially: `c / (2d)`,
    /// i.e. where the spacing exceeds half a wavelength. Infinite for non-positive spacing.
    public static func spatialAliasingFrequency(micSpacing: Double, speedOfSound: Double = 343) -> Double {
        micSpacing > 0 ? speedOfSound / (2 * micSpacing) : .infinity
    }

    private struct Tap {
        /// Extra propagation delay relative to the direct sound, in seconds.
        let delay: Double
        let azimuthDegrees: Double
        let gain: Double
    }
}
