import Testing
import VCModels
@testable import VCSpatial

@Suite struct GCCPHATTests {
    private let fs = SpatialFixtures.sampleRate

    /// `y[n] = x[n − delay]` plus a little independent noise.
    private func delayed(_ x: [Float], by delay: Int, noiseSeed: UInt64) -> [Float] {
        let noise = SpatialFixtures.whiteNoise(count: x.count, seed: noiseSeed)
        return x.indices.map { n in
            let source = n - delay
            return (source >= 0 && source < x.count ? x[source] : 0) + 0.05 * noise[n]
        }
    }

    @Test(arguments: [-9, -1, 0, 4, 13])
    func recoversIntegerDelaysOnNoise(delay: Int) throws {
        let x = SpatialFixtures.whiteNoise(count: 4096, seed: 11)
        let y = delayed(x, by: delay, noiseSeed: 12)
        let (lags, values) = GCCPHAT.correlate(x, y, maxLag: 20)
        #expect(lags.first == -20 && lags.last == 20 && values.count == 41)
        let best = try #require(values.indices.max { values[$0] < values[$1] })
        #expect(lags[best] == delay)

        let estimate = GCCPHAT.tdoa(x, y, sampleRate: fs, maxDelay: 20 / fs)
        #expect(abs(estimate.seconds * fs - Double(delay)) < 0.1)
    }

    @Test func positiveLagMeansYLagsX() {
        let x = SpatialFixtures.whiteNoise(count: 2048, seed: 3)
        let yLate = delayed(x, by: 3, noiseSeed: 4)
        let late = GCCPHAT.tdoa(x, yLate, sampleRate: fs, maxDelay: 0.002)
        let early = GCCPHAT.tdoa(yLate, x, sampleRate: fs, maxDelay: 0.002)
        #expect(late.seconds > 0)
        #expect(abs(late.seconds + early.seconds) < 0.1 / fs)
    }

    /// Fractional delays produced by an exact frequency-domain phase shift (two mics on the x axis,
    /// source on +x so mic 1 hears it first and `t1 − t0 = −spacing / c`).
    @Test(arguments: [0.25, 0.5, 1.37, 2.81, 3.5])
    func recoversFractionalDelaysWithinATenthOfASample(delaySamples: Double) {
        let spacing = delaySamples * 343 / fs
        let pair = MicArrayGeometry(name: "pair", mics: [.init(x: 0, y: 0), .init(x: spacing, y: 0)], channelMap: [0, 1])
        let simulator = ArraySimulator(geometry: pair, sampleRate: fs)
        let source = SpatialFixtures.whiteNoise(count: 8192, seed: 21)
        let mics = simulator.render(source: source, azimuthDegrees: 0, snrDB: 30, seed: 5)

        let estimate = GCCPHAT.tdoa(mics[0], mics[1], sampleRate: fs, maxDelay: 8 / fs)
        #expect(abs(estimate.seconds * fs - (-delaySamples)) < 0.1)
        #expect(abs(estimate.seconds - simulator.tdoa(from: 0, to: 1, azimuthDegrees: 0)) < 0.1 / fs)

        let integerPeak = GCCPHAT.correlate(mics[0], mics[1], maxLag: 8)
        let refined = GCCPHAT.interpolatedPeak(lags: integerPeak.lags, values: integerPeak.values)
        #expect(refined.map { abs($0.lag + delaySamples) < 0.25 } == true)
    }

    @Test func coherentPeakIsNearOneAndIncoherentNearZero() {
        let x = SpatialFixtures.whiteNoise(count: 4096, seed: 31)
        let same = GCCPHAT.tdoa(x, x, sampleRate: fs, maxDelay: 0.001)
        #expect(abs(same.seconds) < 1e-9)
        #expect(abs(same.peak - 1) < 0.01)

        let other = SpatialFixtures.whiteNoise(count: 4096, seed: 32)
        #expect(GCCPHAT.tdoa(x, other, sampleRate: fs, maxDelay: 0.001).peak < 0.1)
    }

    @Test func peakSearchRespectsMaxDelay() {
        let x = SpatialFixtures.whiteNoise(count: 4096, seed: 41)
        let y = delayed(x, by: 12, noiseSeed: 42)
        let estimate = GCCPHAT.tdoa(x, y, sampleRate: fs, maxDelay: 4 / fs)
        #expect(abs(estimate.seconds) <= 4 / fs + 1e-12)
        #expect(estimate.peak < 0.5)
    }

    @Test func emptyInputYieldsZeroCorrelation() {
        let (lags, values) = GCCPHAT.correlate([], [1, 2, 3], maxLag: 2)
        #expect(lags == [-2, -1, 0, 1, 2])
        #expect(values.allSatisfy { $0 == 0 })
        #expect(GCCPHAT.tdoa([], [], sampleRate: fs, maxDelay: 0.001).peak == 0)
    }
}
