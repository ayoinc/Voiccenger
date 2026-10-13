import Foundation

/// Generalized cross-correlation with phase transform (GCC-PHAT).
///
/// **Sign convention:** a positive lag means `y` lags `x`, i.e. `y[n] ≈ x[n − lag]`
/// (the sound reached the `x` microphone first). Internally the cross-spectrum is `X·conj(Y)`,
/// whose inverse transform peaks at index `−lag`; lags are read back accordingly.
///
/// Correlation values are normalised so that two identical (or purely delayed) signals produce a
/// peak of ≈ 1; incoherent signals produce values near 0.
public enum GCCPHAT {
    /// GCC-PHAT correlation at integer lags `−maxLag … maxLag` (positive = `y` lags `x`).
    ///
    /// Both inputs are zero-padded to the next power of two ≥ `x.count + y.count`, so the result is
    /// a linear (not circular) correlation for every lag that fits within the signals.
    public static func correlate(_ x: [Float], _ y: [Float], maxLag: Int) -> (lags: [Int], values: [Float]) {
        let maxLag = max(0, maxLag)
        let lags = Array(-maxLag...maxLag)
        guard !x.isEmpty, !y.isEmpty else {
            return (lags, [Float](repeating: 0, count: lags.count))
        }
        let fft = RealFFT(minimumSize: max(x.count + y.count, 2 * maxLag + 2))
        let cross = phatCrossSpectrum(fft.forward(x), fft.forward(y), band: nil)
        let values = lagWindow(
            of: cross, weight: hermitianWeight(fftSize: fft.size, band: nil), maxLag: maxLag, upsample: 1)
        return (lags, values)
    }

    /// Time difference of arrival of `y` relative to `x` (positive = `y` lags `x`), restricted to
    /// `|τ| ≤ maxDelay` seconds, with sub-sample precision.
    ///
    /// The PHAT cross-spectrum is band-limited-interpolated (zero-padded inverse FFT, up to 8× finer
    /// lag grid) and the peak is then refined with a parabolic fit, which keeps the bias of plain
    /// three-point interpolation on the sinc-shaped PHAT peak well below 0.01 sample.
    public static func tdoa(_ x: [Float], _ y: [Float], sampleRate: Double, maxDelay: Double) -> (
        seconds: Double, peak: Float
    ) {
        guard !x.isEmpty, !y.isEmpty, sampleRate > 0, maxDelay.isFinite else { return (0, 0) }
        let limit = max(0, maxDelay) * sampleRate
        let maxLag = Int(limit.rounded(.up)) + 1
        let fft = RealFFT(minimumSize: max(x.count + y.count, 2 * maxLag + 2))
        let cross = phatCrossSpectrum(fft.forward(x), fft.forward(y), band: nil)
        let factor = max(1, min(8, (1 << 22) / fft.size))
        let fine = lagWindow(
            of: cross, weight: hermitianWeight(fftSize: fft.size, band: nil), maxLag: maxLag, upsample: factor)

        let centre = maxLag * factor
        let reach = Int((limit * Double(factor)).rounded(.down))
        var best = centre - reach
        for index in (centre - reach)...(centre + reach) where fine[index] > fine[best] {
            best = index
        }
        let vertex = parabolicVertex(fine[best - 1], fine[best], fine[best + 1])
        let lagSamples = min(limit, max(-limit, (Double(best - centre) + vertex.offset) / Double(factor)))
        return (lagSamples / sampleRate, vertex.value)
    }

    /// Sub-sample peak of an integer-lag correlation (e.g. the output of `correlate`) by parabolic
    /// interpolation around the largest value. Returns the lag in (fractional) samples.
    public static func interpolatedPeak(lags: [Int], values: [Float]) -> (lag: Double, value: Float)? {
        guard !values.isEmpty, lags.count == values.count else { return nil }
        let best = values.indices.max { values[$0] < values[$1] }!
        guard best > 0, best < values.count - 1 else { return (Double(lags[best]), values[best]) }
        let vertex = parabolicVertex(values[best - 1], values[best], values[best + 1])
        return (Double(lags[best]) + vertex.offset, vertex.value)
    }

    // MARK: - Building blocks shared with DirectionEstimator

    /// Vertex of the parabola through three equally spaced samples centred on `b`.
    /// Returns offset 0 when the samples are not concave (no interior maximum).
    static func parabolicVertex(_ a: Float, _ b: Float, _ c: Float) -> (offset: Double, value: Float) {
        let denominator = Double(a) - 2 * Double(b) + Double(c)
        guard denominator < 0 else { return (0, b) }
        let offset = min(0.5, max(-0.5, 0.5 * (Double(a) - Double(c)) / denominator))
        let value = Double(b) - 0.25 * (Double(a) - Double(c)) * offset
        return (offset, Float(value))
    }

    /// PHAT-weighted cross-spectrum `X·conj(Y) / (|X·conj(Y)| + ε)`.
    /// Bins outside `band` (inclusive bin indices, 0 = DC, n/2 = Nyquist) are zeroed.
    static func phatCrossSpectrum(_ x: PackedSpectrum, _ y: PackedSpectrum, band: ClosedRange<Int>?)
        -> PackedSpectrum
    {
        precondition(x.fftSize == y.fftSize)
        let half = x.re.count
        var out = PackedSpectrum(zerosForFFTSize: x.fftSize)
        var magnitudes = [Float](repeating: 0, count: half + 1)  // index half = Nyquist
        var largest: Float = 0
        for k in 1..<half {
            let re = x.re[k] * y.re[k] + x.im[k] * y.im[k]
            let im = x.im[k] * y.re[k] - x.re[k] * y.im[k]
            out.re[k] = re
            out.im[k] = im
            let magnitude = (re * re + im * im).squareRoot()
            magnitudes[k] = magnitude
            largest = max(largest, magnitude)
        }
        // Packed DC (re[0]) and Nyquist (im[0]) are real.
        out.re[0] = x.re[0] * y.re[0]
        out.im[0] = x.im[0] * y.im[0]
        magnitudes[0] = abs(out.re[0])
        magnitudes[half] = abs(out.im[0])
        largest = max(largest, magnitudes[0], magnitudes[half])

        // Relative epsilon: only guards division by (near) zero, never reweights real content.
        let epsilon = largest * 1e-7 + Float.leastNormalMagnitude
        let keep = band ?? 0...half
        for k in 1..<half {
            if keep.contains(k) {
                let scale = 1 / (magnitudes[k] + epsilon)
                out.re[k] *= scale
                out.im[k] *= scale
            } else {
                out.re[k] = 0
                out.im[k] = 0
            }
        }
        out.re[0] = keep.contains(0) ? out.re[0] / (magnitudes[0] + epsilon) : 0
        out.im[0] = keep.contains(half) ? out.im[0] / (magnitudes[half] + epsilon) : 0
        return out
    }

    /// Sum of PHAT weights over the full Hermitian spectrum: the zero-lag value of a perfectly
    /// coherent pair before normalisation.
    static func hermitianWeight(fftSize n: Int, band: ClosedRange<Int>?) -> Float {
        let half = n / 2
        let keep = band ?? 0...half
        var weight = 0
        for k in keep.clamped(to: 0...half) {
            weight += (k == 0 || k == half) ? 1 : 2
        }
        return Float(weight)
    }

    /// Inverse-transforms a (possibly accumulated) PHAT cross-spectrum and returns values on a lag
    /// grid of step `1/upsample` samples from `−maxLag` to `+maxLag` (positive = `y` lags `x`),
    /// divided by `weight`. `upsample > 1` interpolates by zero-padding the spectrum.
    static func lagWindow(of cross: PackedSpectrum, weight: Float, maxLag: Int, upsample: Int) -> [Float] {
        let n = cross.fftSize
        let factor = max(1, upsample)
        let spectrum: PackedSpectrum
        if factor == 1 {
            spectrum = cross
        } else {
            var padded = PackedSpectrum(zerosForFFTSize: n * factor)
            let half = n / 2
            padded.re[0] = cross.re[0]
            for k in 1..<half {
                padded.re[k] = cross.re[k]
                padded.im[k] = cross.im[k]
            }
            // The old Nyquist bin becomes an ordinary bin; its energy is split between ±n/2.
            padded.re[half] = cross.im[0] * 0.5
            spectrum = padded
        }
        let size = n * factor
        let correlation = RealFFT(log2n: RealFFT.log2Ceiling(size)).inverse(spectrum)
        let scale = weight > 0 ? 1 / weight : 0
        let centre = maxLag * factor
        return (0...(2 * centre)).map { k in
            let index = ((centre - k) % size + size) % size
            return correlation[index] * scale
        }
    }
}
