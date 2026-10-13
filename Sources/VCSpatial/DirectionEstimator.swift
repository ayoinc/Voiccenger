import Accelerate
import Foundation
import VCModels

/// Far-field direction of arrival by steered-response power over GCC-PHAT (SRP-PHAT).
///
/// The chunk's raw array channels (`chunk.channelSamples`, picked via `geometry.channelMap`) are cut
/// into Hann-windowed frames of `frameSeconds` with 50 % overlap. Frames below the energy gate are
/// skipped. For every microphone pair the PHAT cross-spectra of the kept frames are accumulated
/// (SRP is linear in the GCC, so this equals summing per-frame correlations), transformed once to an
/// 8× interpolated lag grid, and sampled at each azimuth's expected lag
/// `τ_ij(θ) = ((p_j − p_i)·u(θ)) / c` (positive = mic `i` hears the source after mic `j`).
/// Azimuths follow `DirectionEstimate`: degrees counter-clockwise from the array's +x axis.
public struct DirectionEstimator: Sendable {
    public let geometry: MicArrayGeometry
    public let speedOfSound: Double
    public let frameSeconds: Double

    /// Frames whose RMS (averaged over the array) is below this are never analysed (≈ −60 dBFS).
    public static let absoluteGateRMS: Double = 0.001
    /// Frames more than this many dB below the loudest frame of the chunk are skipped, so pauses
    /// and noise-only frames do not dilute the steered response.
    public static let relativeGateDB: Double = 12

    /// Interpolation factor of the lag grid the steered response is sampled from.
    static let lagUpsample = 8
    /// Extra integer lags computed beyond the largest pair delay to measure the incoherent floor.
    static let noiseLags = 24
    /// Lags this far past a pair's maximum physical delay are still treated as main lobe.
    static let noiseGuardLags = 2.0
    /// Peak-to-floor ratio (in noise standard deviations) that diffuse noise alone reaches.
    static let detectionFloor = 2.0
    /// Excess ratio above `detectionFloor` at which detection confidence is 0.5.
    static let detectionScale = 6.0
    /// Minimum angular distance (degrees) of a competing local maximum.
    static let secondaryPeakSeparation = 25

    private struct MicPair: Sendable {
        let i: Int
        let j: Int
        /// `p_j − p_i` in metres.
        let dx: Double
        let dy: Double
    }

    private struct Analysis {
        /// Mean (over pairs and frames) PHAT coherence steered to each whole degree; ≈1 for a
        /// perfectly coherent single source at that azimuth, ≈0 for diffuse noise.
        let steered: [Double]
        /// Standard deviation `steered` would have from incoherent sound alone, measured on the
        /// physically impossible lags (beyond the pair's aperture), where no plane wave can peak.
        let noiseFloor: Double
        let time: TimeInterval
    }

    private let pairs: [MicPair]

    public init(geometry: MicArrayGeometry, speedOfSound: Double = 343, frameSeconds: Double = 0.064) {
        self.geometry = geometry
        self.speedOfSound = speedOfSound
        self.frameSeconds = frameSeconds
        var pairs: [MicPair] = []
        for i in geometry.mics.indices {
            for j in geometry.mics.indices where j > i {
                pairs.append(
                    MicPair(
                        i: i, j: j,
                        dx: geometry.mics[j].x - geometry.mics[i].x,
                        dy: geometry.mics[j].y - geometry.mics[i].y))
            }
        }
        self.pairs = pairs
    }

    /// Strongest direction in the chunk, or nil when the chunk has no usable array channels or every
    /// frame is gated as silence.
    ///
    /// Confidence combines how far the peak stands above the incoherent floor with how dominant it
    /// is over any other direction:
    /// - `z = (r_peak − r_mean) / σ`, where `σ` is the response's noise standard deviation measured
    ///   on physically impossible lags. Diffuse noise reaches `z ≈ 2`; clear speech exceeds 30.
    ///   Detection is `(z − z₀) / (z − z₀ + k)` with `z₀ = detectionFloor`, `k = detectionScale`.
    /// - `ρ = (r_second − r_mean) / (r_peak − r_mean)` for the highest other local maximum at least
    ///   `secondaryPeakSeparation` away; dominance is `1 − ρ` (equally strong peaks ⇒ 0).
    ///
    /// Measured on the speech fixture: ≈0.8–0.9 at 20 dB SNR, 0.45–0.75 at 5 dB with reverb,
    /// < 0.05 for diffuse noise; overlapping talkers drop it by 30–65 %.
    public func estimate(_ chunk: AudioChunk) -> DirectionEstimate? {
        guard let analysis = analyse(chunk) else { return nil }
        let r = analysis.steered
        var best = 0
        for degree in 1..<360 where r[degree] > r[best] { best = degree }
        let vertex = GCCPHAT.parabolicVertex(
            Float(r[(best + 359) % 360]), Float(r[best]), Float(r[(best + 1) % 360]))
        let azimuth = DirectionEstimator.normalizedDegrees(Double(best) + vertex.offset)

        let mean = r.reduce(0, +) / Double(r.count)
        let contrast = r[best] - mean
        guard contrast > 0, analysis.noiseFloor > 0 else {
            return DirectionEstimate(azimuthDegrees: azimuth, confidence: contrast > 0 ? 1 : 0, time: analysis.time)
        }
        let excess = max(0, contrast / analysis.noiseFloor - DirectionEstimator.detectionFloor)
        let detection = excess / (excess + DirectionEstimator.detectionScale)

        var secondary = mean
        for degree in 0..<360 where r[degree] >= r[(degree + 359) % 360] && r[degree] >= r[(degree + 1) % 360] {
            let separation = abs(degree - best)
            if min(separation, 360 - separation) >= DirectionEstimator.secondaryPeakSeparation {
                secondary = max(secondary, r[degree])
            }
        }
        let dominance = 1 - min(1, (secondary - mean) / contrast)
        return DirectionEstimate(azimuthDegrees: azimuth, confidence: detection * dominance, time: analysis.time)
    }

    /// Steered response for azimuths 0…359° (index = degree), min–max normalised to 0…1 for
    /// plotting. All zeros when `estimate` would return nil.
    public func response(_ chunk: AudioChunk) -> [Double] {
        guard let analysis = analyse(chunk) else { return [Double](repeating: 0, count: 360) }
        let r = analysis.steered
        let low = r.min()!
        let span = r.max()! - low
        guard span > 0 else { return [Double](repeating: 0, count: 360) }
        return r.map { ($0 - low) / span }
    }

    static func normalizedDegrees(_ degrees: Double) -> Double {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        let positive = wrapped < 0 ? wrapped + 360 : wrapped
        return positive >= 360 ? 0 : positive
    }

    // MARK: - Analysis

    private func analyse(_ chunk: AudioChunk) -> Analysis? {
        guard let channels = chunk.channelSamples, chunk.sampleRate > 0, speedOfSound > 0,
            !pairs.isEmpty, geometry.channelMap.count == geometry.mics.count
        else { return nil }
        var signals: [[Float]] = []
        signals.reserveCapacity(geometry.channelMap.count)
        for channel in geometry.channelMap {
            guard channels.indices.contains(channel) else { return nil }
            signals.append(channels[channel])
        }

        let sampleRate = chunk.sampleRate
        let available = signals.map(\.count).min() ?? 0
        let frameLength = min(max(64, Int((frameSeconds * sampleRate).rounded())), available)
        guard frameLength >= 64 else { return nil }
        let hop = max(1, frameLength / 2)
        let starts = Array(stride(from: 0, through: available - frameLength, by: hop))

        // Energy gate: mean power over the array per frame.
        let energies: [Double] = starts.map { start in
            var total = 0.0
            for signal in signals {
                signal.withUnsafeBufferPointer { buffer in
                    total += Double(vDSP.meanSquare(UnsafeBufferPointer(rebasing: buffer[start..<start + frameLength])))
                }
            }
            return total / Double(signals.count)
        }
        let loudest = energies.max() ?? 0
        let gate = max(
            DirectionEstimator.absoluteGateRMS * DirectionEstimator.absoluteGateRMS,
            loudest * pow(10, -DirectionEstimator.relativeGateDB / 10))
        let kept = starts.indices.filter { energies[$0] >= gate }.map { starts[$0] }
        guard !kept.isEmpty else { return nil }

        let fft = RealFFT(minimumSize: 2 * frameLength)
        let window = vDSP.window(
            ofType: Float.self, usingSequence: .hanningDenormalized, count: frameLength, isHalfWindow: false)
        var accumulated = [PackedSpectrum](repeating: PackedSpectrum(zerosForFFTSize: fft.size), count: pairs.count)
        var frame = [Float](repeating: 0, count: frameLength)
        for start in kept {
            let spectra: [PackedSpectrum] = signals.map { signal in
                signal.withUnsafeBufferPointer { buffer in
                    vDSP.multiply(UnsafeBufferPointer(rebasing: buffer[start..<start + frameLength]), window, result: &frame)
                }
                return fft.forward(frame)
            }
            for (index, pair) in pairs.enumerated() {
                // x = mic j, y = mic i ⇒ positive lag means mic i lags mic j, matching τ_ij(θ).
                let cross = GCCPHAT.phatCrossSpectrum(spectra[pair.j], spectra[pair.i], band: nil)
                vDSP.add(accumulated[index].re, cross.re, result: &accumulated[index].re)
                vDSP.add(accumulated[index].im, cross.im, result: &accumulated[index].im)
            }
        }

        let samplesPerMetre = sampleRate / speedOfSound
        let pairDelays = pairs.map { hypot($0.dx, $0.dy) * samplesPerMetre }
        let maxLag = Int((pairDelays.max() ?? 0).rounded(.up)) + DirectionEstimator.noiseLags
        let upsample = DirectionEstimator.lagUpsample
        let weight = GCCPHAT.hermitianWeight(fftSize: fft.size, band: nil) * Float(kept.count)
        let centre = Double(maxLag * upsample)
        var steered = [Double](repeating: 0, count: 360)
        var noiseEnergy = 0.0
        var noiseCount = 0
        for (index, pair) in pairs.enumerated() {
            let lagValues = GCCPHAT.lagWindow(
                of: accumulated[index], weight: weight, maxLag: maxLag, upsample: upsample)
            let lastIndex = lagValues.count - 1
            for degree in 0..<360 {
                let tau = (pair.dx * DirectionEstimator.cosTable[degree] + pair.dy * DirectionEstimator.sinTable[degree])
                    * samplesPerMetre
                let position = min(Double(lastIndex), max(0, centre + tau * Double(upsample)))
                let lower = min(lastIndex - 1, Int(position))
                let fraction = position - Double(lower)
                steered[degree] += Double(lagValues[lower]) * (1 - fraction) + Double(lagValues[lower + 1]) * fraction
            }
            // Lags beyond the pair's aperture (plus a guard for the main lobe) carry no direct path.
            let guardLags = pairDelays[index] + DirectionEstimator.noiseGuardLags
            for (offset, value) in lagValues.enumerated()
            where abs(Double(offset) - centre) > guardLags * Double(upsample) {
                noiseEnergy += Double(value) * Double(value)
                noiseCount += 1
            }
        }
        let pairCount = Double(pairs.count)
        for degree in 0..<360 { steered[degree] /= pairCount }
        // Pairs share microphones, so their noise is not independent; dividing by √P is the
        // independent-pair approximation (slightly optimistic for large arrays).
        let pairNoise = noiseCount > 0 ? (noiseEnergy / Double(noiseCount)).squareRoot() : 0
        let noiseFloor = pairNoise / pairCount.squareRoot()

        let meanCentre = kept.reduce(0.0) { $0 + Double($1) + Double(frameLength) / 2 } / Double(kept.count)
        return Analysis(steered: steered, noiseFloor: noiseFloor, time: chunk.startTime + meanCentre / sampleRate)
    }

    private static let cosTable: [Double] = (0..<360).map { cos(Double($0) * .pi / 180) }
    private static let sinTable: [Double] = (0..<360).map { sin(Double($0) * .pi / 180) }
}
