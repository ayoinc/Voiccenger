import Foundation
import Testing
import VCModels
@testable import VCSpatial

@Suite struct SeatTrackerTests {
    @Test func circularMeanWrapsAroundZero() throws {
        var tracker = SeatTracker()
        tracker.add(DirectionEstimate(azimuthDegrees: 350, confidence: 0.8, time: 0), speakerKey: "mic-1")
        tracker.add(DirectionEstimate(azimuthDegrees: 10, confidence: 0.8, time: 1), speakerKey: "mic-1")
        let seat = try #require(tracker.seat(for: "mic-1"))
        #expect(SpatialFixtures.angularError(seat, 0) < 1e-6)
        #expect(seat >= 0 && seat < 360)
    }

    @Test func meanIsWeightedByConfidence() throws {
        var tracker = SeatTracker()
        tracker.add(DirectionEstimate(azimuthDegrees: 80, confidence: 0.9, time: 0), speakerKey: "a")
        tracker.add(DirectionEstimate(azimuthDegrees: 100, confidence: 0.3, time: 1), speakerKey: "a")
        let seat = try #require(tracker.seat(for: "a"))
        #expect(seat > 80 && seat < 90)
    }

    @Test func lowConfidenceEstimatesAreIgnored() throws {
        var tracker = SeatTracker()
        tracker.add(DirectionEstimate(azimuthDegrees: 270, confidence: 0.19, time: 0), speakerKey: "b")
        #expect(tracker.seat(for: "b") == nil)
        tracker.add(DirectionEstimate(azimuthDegrees: 45, confidence: 0.5, time: 1), speakerKey: "b")
        tracker.add(DirectionEstimate(azimuthDegrees: 225, confidence: 0.1, time: 2), speakerKey: "b")
        #expect(try abs(#require(tracker.seat(for: "b")) - 45) < 1e-9)
    }

    @Test func speakersAreTrackedIndependently() {
        var tracker = SeatTracker()
        tracker.add(DirectionEstimate(azimuthDegrees: 30, confidence: 0.7, time: 0), speakerKey: "a")
        tracker.add(DirectionEstimate(azimuthDegrees: 200, confidence: 0.7, time: 0), speakerKey: "b")
        tracker.add(DirectionEstimate(azimuthDegrees: 200, confidence: 0.1, time: 0), speakerKey: "c")
        #expect(Set(tracker.seats.keys) == ["a", "b"])
        #expect(abs((tracker.seats["b"] ?? 0) - 200) < 1e-9)
    }
}

@Suite struct ArraySimulatorTests {
    @Test func aliasingFrequencyIsHalfWavelengthBoundary() {
        // λ/2 at 8 kHz with c = 343 m/s is 21.4375 mm.
        let boundary = 343.0 / (2 * 8_000)
        #expect(abs(ArraySimulator.spatialAliasingFrequency(micSpacing: boundary) - 8_000) < 1e-9)
        #expect(ArraySimulator.spatialAliasingFrequency(micSpacing: boundary * 1.01) < 8_000)
        #expect(ArraySimulator.spatialAliasingFrequency(micSpacing: boundary * 0.99) > 8_000)
        #expect(ArraySimulator.spatialAliasingFrequency(micSpacing: 0.1, speedOfSound: 340) == 1_700)
        #expect(ArraySimulator.spatialAliasingFrequency(micSpacing: 0) == .infinity)
    }

    @Test func renderIsDeterministicPerSeed() {
        let simulator = ArraySimulator(geometry: ArrayPresets.respeaker4)
        let source = SignalGenerator.speechLike(count: 4_000, sampleRate: 16_000, seed: 2)
        let a = simulator.render(source: source, azimuthDegrees: 45, snrDB: 10, reverb: 0.4, seed: 9)
        let b = simulator.render(source: source, azimuthDegrees: 45, snrDB: 10, reverb: 0.4, seed: 9)
        let c = simulator.render(source: source, azimuthDegrees: 45, snrDB: 10, reverb: 0.4, seed: 10)
        #expect(a == b)
        #expect(a != c)
        #expect(a.count == 4 && a.allSatisfy { $0.count == source.count })
    }

    @Test func noiseLevelMatchesRequestedSNR() {
        let simulator = ArraySimulator(geometry: ArrayPresets.respeaker6)
        let source = SpatialFixtures.whiteNoise(count: 32_000, seed: 1)
        let clean = simulator.render(source: source, azimuthDegrees: 0, snrDB: 200, seed: 1)
        let noisy = simulator.render(source: source, azimuthDegrees: 0, snrDB: 6, seed: 1)
        for mic in clean.indices {
            let signalPower = clean[mic].reduce(0.0) { $0 + Double($1 * $1) }
            let noisePower = zip(noisy[mic], clean[mic]).reduce(0.0) { $0 + Double(($1.0 - $1.1) * ($1.0 - $1.1)) }
            #expect(abs(10 * log10(signalPower / noisePower) - 6) < 0.3)
        }
    }

    @Test func chunkUsesDeviceChannelLayout() throws {
        let geometry = ArrayPresets.respeaker4
        let simulator = ArraySimulator(geometry: geometry)
        let source = SpatialFixtures.whiteNoise(count: 1_000, seed: 5)
        let mics = simulator.render(source: source, azimuthDegrees: 90, snrDB: 30, seed: 3)
        let chunk = simulator.renderChunk(source: source, azimuthDegrees: 90, snrDB: 30, seed: 3, startTime: 4)
        let channels = try #require(chunk.channelSamples)
        #expect(channels.count == 5)
        #expect(channels[0].allSatisfy { $0 == 0 })
        #expect(Array(channels[1...4]) == mics)
        #expect(chunk.startTime == 4 && chunk.samples.count == source.count)
    }
}
