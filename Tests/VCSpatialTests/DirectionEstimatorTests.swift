import Foundation
import Testing
import VCModels
@testable import VCSpatial

@Suite struct DirectionEstimatorTests {
    private struct Sweep {
        let errors: [Double]
        let confidences: [Double]
        var maxError: Double { errors.max() ?? .infinity }
        var meanError: Double { errors.reduce(0, +) / Double(errors.count) }
    }

    private func sweep(_ geometry: MicArrayGeometry, snrDB: Double, reverb: Double) throws -> Sweep {
        let simulator = ArraySimulator(geometry: geometry, sampleRate: SpatialFixtures.sampleRate)
        let estimator = DirectionEstimator(geometry: geometry)
        var errors: [Double] = []
        var confidences: [Double] = []
        for azimuth in stride(from: 0.0, through: 350, by: 10) {
            let chunk = simulator.renderChunk(
                source: SpatialFixtures.speech.samples, azimuthDegrees: azimuth, snrDB: snrDB, reverb: reverb,
                seed: 42)
            let estimate = try #require(estimator.estimate(chunk), "no estimate at \(azimuth)°")
            errors.append(SpatialFixtures.angularError(estimate.azimuthDegrees, azimuth))
            confidences.append(estimate.confidence)
        }
        let source = SpatialFixtures.speech.isRecorded ? "speech fixture" : "speech-like noise"
        print(
            String(
                format: "DOA %@ | SNR %4.0f dB reverb %.1f | %@ | max %.2f° mean %.2f° | confidence %.2f–%.2f",
                geometry.name, snrDB, reverb, source, errors.max()!, errors.reduce(0, +) / Double(errors.count),
                confidences.min()!, confidences.max()!))
        return Sweep(errors: errors, confidences: confidences)
    }

    @Test(arguments: ArrayPresets.all)
    func cleanRoomErrorWithinFiveDegrees(geometry: MicArrayGeometry) throws {
        let result = try sweep(geometry, snrDB: 20, reverb: 0)
        #expect(result.maxError <= 5)
        #expect(result.confidences.allSatisfy { $0 >= SeatTracker.minimumConfidence })
    }

    @Test(arguments: ArrayPresets.all)
    func noisyReverberantRoomErrorWithinTenDegrees(geometry: MicArrayGeometry) throws {
        let result = try sweep(geometry, snrDB: 5, reverb: 0.3)
        #expect(result.maxError <= 10)
        #expect(result.confidences.allSatisfy { $0 >= SeatTracker.minimumConfidence })
    }

    @Test(arguments: ArrayPresets.all)
    func competingEqualTalkersLowerConfidence(geometry: MicArrayGeometry) throws {
        let simulator = ArraySimulator(geometry: geometry)
        let a = SignalGenerator.speechLike(count: 16_000, sampleRate: 16_000, seed: 1)
        let b = SignalGenerator.speechLike(count: 16_000, sampleRate: 16_000, seed: 2)
        let estimator = DirectionEstimator(geometry: geometry)
        let alone = try #require(estimator.estimate(simulator.renderChunk(source: a, azimuthDegrees: 40, snrDB: 20)))
        let first = simulator.render(source: a, azimuthDegrees: 40, snrDB: 20, seed: 1)
        let second = simulator.render(source: b, azimuthDegrees: 220, snrDB: 200, seed: 2)
        let mixed = zip(first, second).map { zip($0, $1).map { $0 + $1 } }
        let chunk = AudioChunk(
            channel: .microphone, startTime: 0, sampleRate: 16_000, samples: mixed[0],
            channelSamples: simulator.deviceChannels(mixed))
        let both = try #require(estimator.estimate(chunk))
        print(String(format: "Overlap %@ | alone %.2f | two talkers %.2f", geometry.name, alone.confidence, both.confidence))
        // The talker that dominates more time–frequency bins wins; the other still caps dominance.
        #expect(min(SpatialFixtures.angularError(both.azimuthDegrees, 40), SpatialFixtures.angularError(both.azimuthDegrees, 220)) <= 5)
        #expect(both.confidence < alone.confidence * 0.75)
    }

    @Test func responsePeaksAtEstimateAndIsNormalised() throws {
        let geometry = ArrayPresets.respeaker6
        let chunk = ArraySimulator(geometry: geometry).renderChunk(
            source: SpatialFixtures.speech.samples, azimuthDegrees: 123, snrDB: 20, seed: 3)
        let estimator = DirectionEstimator(geometry: geometry)
        let response = estimator.response(chunk)
        #expect(response.count == 360)
        #expect(response.min() == 0 && response.max() == 1)
        let peakDegree = try #require(response.indices.max { response[$0] < response[$1] })
        let estimate = try #require(estimator.estimate(chunk))
        #expect(SpatialFixtures.angularError(Double(peakDegree), estimate.azimuthDegrees) <= 1)
    }

    @Test func diffuseNoiseHasLowConfidence() throws {
        // Independent noise on every channel: no coherent direction.
        let geometry = ArrayPresets.uma8
        let channels = (0..<8).map { SpatialFixtures.whiteNoise(count: 16_000, seed: UInt64(100 + $0)) }
        let chunk = AudioChunk(
            channel: .microphone, startTime: 0, sampleRate: 16_000, samples: channels[0], channelSamples: channels)
        let estimate = try #require(DirectionEstimator(geometry: geometry).estimate(chunk))
        #expect(estimate.confidence < SeatTracker.minimumConfidence)
    }

    @Test func usesChannelMapToFindRawMics() throws {
        // ReSpeaker v2.0 puts a processed mono signal on channel 0; it must not be used.
        let geometry = ArrayPresets.respeaker4
        let clean = ArraySimulator(geometry: geometry).renderChunk(
            source: SpatialFixtures.speech.samples, azimuthDegrees: 200, snrDB: 20, seed: 9)
        var channels = try #require(clean.channelSamples)
        #expect(channels.count == 5)
        channels[0] = SpatialFixtures.whiteNoise(count: channels[1].count, seed: 77)
        let chunk = AudioChunk(
            channel: .microphone, startTime: 2, sampleRate: clean.sampleRate, samples: clean.samples,
            channelSamples: channels)
        let estimate = try #require(DirectionEstimator(geometry: geometry).estimate(chunk))
        #expect(SpatialFixtures.angularError(estimate.azimuthDegrees, 200) <= 5)
        #expect(estimate.time > 2 && estimate.time < 2 + clean.duration)
    }

    @Test func returnsNilWithoutArrayChannelsOrWhenSilent() {
        let estimator = DirectionEstimator(geometry: ArrayPresets.respeaker4)
        let mono = AudioChunk(channel: .microphone, startTime: 0, sampleRate: 16_000, samples: SpatialFixtures.speech.samples)
        #expect(estimator.estimate(mono) == nil)
        #expect(estimator.response(mono) == [Double](repeating: 0, count: 360))

        let silence = [[Float]](repeating: [Float](repeating: 0, count: 1_600), count: 6)
        let quiet = AudioChunk(
            channel: .microphone, startTime: 0, sampleRate: 16_000, samples: silence[0], channelSamples: silence)
        #expect(estimator.estimate(quiet) == nil)

        let tooFewChannels = AudioChunk(
            channel: .microphone, startTime: 0, sampleRate: 16_000, samples: silence[0],
            channelSamples: Array(silence.prefix(3)))
        #expect(estimator.estimate(tooFewChannels) == nil)
    }

    @Test func singleShortChunkStillEstimates() throws {
        // Live capture delivers 100 ms chunks; one chunk must be enough for an estimate.
        let geometry = ArrayPresets.respeaker6
        let speech = SpatialFixtures.speech.samples
        let loudest = stride(from: 0, to: speech.count - 1_600, by: 160).max { a, b in
            speech[a..<a + 1_600].reduce(0) { $0 + $1 * $1 } < speech[b..<b + 1_600].reduce(0) { $0 + $1 * $1 }
        }!
        let chunk = ArraySimulator(geometry: geometry).renderChunk(
            source: Array(speech[loudest..<loudest + 1_600]), azimuthDegrees: 290, snrDB: 20, seed: 4)
        let estimate = try #require(DirectionEstimator(geometry: geometry).estimate(chunk))
        #expect(SpatialFixtures.angularError(estimate.azimuthDegrees, 290) <= 10)
    }
}
