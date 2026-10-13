import Accelerate
import Synchronization

/// Half-spectrum of a real signal in vDSP's packed layout.
///
/// `re[0]` holds the DC bin and `im[0]` the Nyquist bin (both purely real); `re[k]`/`im[k]` for
/// `1 ..< count/2` hold bin `k`. The negative-frequency half is implied by Hermitian symmetry.
struct PackedSpectrum: Sendable {
    var re: [Float]
    var im: [Float]

    init(re: [Float], im: [Float]) {
        self.re = re
        self.im = im
    }

    init(zerosForFFTSize n: Int) {
        re = [Float](repeating: 0, count: n / 2)
        im = [Float](repeating: 0, count: n / 2)
    }

    /// Number of real samples this spectrum represents.
    var fftSize: Int { re.count * 2 }
}

/// Owner of an immutable vDSP FFT setup.
private final class FFTSetupHandle: Sendable {
    // vDSP setups are read-only after creation and documented as safe to share across threads.
    nonisolated(unsafe) let setup: FFTSetup

    init(log2n: Int) {
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP_create_fftsetup failed for log2n=\(log2n) (out of memory)")
        }
        self.setup = setup
    }
}

/// Process-wide cache of FFT setups keyed by log2 size; setups live for the process lifetime.
private let fftSetupCache = Mutex<[Int: FFTSetupHandle]>([:])

/// Power-of-two real FFT built on `vDSP_fft_zrip`.
///
/// Scaling follows vDSP: `forward` returns 2× the mathematical DFT, `inverse` returns
/// `Σ_k Z[k]·e^{+i2πkn/N}` over the full Hermitian spectrum (no 1/N), so a forward/inverse
/// round trip multiplies by `2N`.
struct RealFFT: Sendable {
    let log2n: Int
    private let handle: FFTSetupHandle

    var size: Int { 1 << log2n }

    /// FFT of the smallest power-of-two size ≥ `minimumSize` (at least 2).
    init(minimumSize: Int) {
        self.init(log2n: RealFFT.log2Ceiling(max(2, minimumSize)))
    }

    init(log2n: Int) {
        precondition(log2n >= 1 && log2n <= 30, "unsupported FFT size 2^\(log2n)")
        self.log2n = log2n
        handle = fftSetupCache.withLock { cache in
            if let existing = cache[log2n] { return existing }
            let created = FFTSetupHandle(log2n: log2n)
            cache[log2n] = created
            return created
        }
    }

    static func log2Ceiling(_ value: Int) -> Int {
        var log2n = 0
        while (1 << log2n) < value { log2n += 1 }
        return log2n
    }

    /// Forward transform of `input`, zero-padded (or truncated) to `size`.
    func forward(_ input: UnsafeBufferPointer<Float>) -> PackedSpectrum {
        let n = size
        let half = n / 2
        var padded = [Float](repeating: 0, count: n)
        let copied = min(input.count, n)
        if copied > 0, let base = input.baseAddress {
            padded.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: base, count: copied)
            }
        }
        var spectrum = PackedSpectrum(zerosForFFTSize: n)
        spectrum.re.withUnsafeMutableBufferPointer { rp in
            spectrum.im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                padded.withUnsafeBytes { raw in
                    vDSP_ctoz(
                        raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(handle.setup, &split, 1, vDSP_Length(log2n), FFTDirection(kFFTDirection_Forward))
            }
        }
        return spectrum
    }

    func forward(_ input: [Float]) -> PackedSpectrum {
        input.withUnsafeBufferPointer { forward($0) }
    }

    /// Inverse transform. `spectrum.fftSize` must equal `size`.
    func inverse(_ spectrum: PackedSpectrum) -> [Float] {
        let n = size
        precondition(spectrum.fftSize == n, "spectrum size \(spectrum.fftSize) ≠ FFT size \(n)")
        var re = spectrum.re
        var im = spectrum.im
        var output = [Float](repeating: 0, count: n)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(handle.setup, &split, 1, vDSP_Length(log2n), FFTDirection(kFFTDirection_Inverse))
                output.withUnsafeMutableBytes { raw in
                    vDSP_ztoc(&split, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(n / 2))
                }
            }
        }
        return output
    }
}
