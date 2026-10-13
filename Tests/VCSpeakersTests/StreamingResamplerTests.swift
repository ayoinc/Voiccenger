import Foundation
import Testing
@testable import VCSpeakers

@Suite("StreamingResampler")
struct StreamingResamplerTests {
    static func sine(frequency: Double, sampleRate: Double, seconds: Double) -> [Float] {
        (0..<Int(sampleRate * seconds)).map { Float(0.5 * sin(2 * .pi * frequency * Double($0) / sampleRate)) }
    }

    static func zeroCrossings(_ x: ArraySlice<Float>) -> Int {
        zip(x, x.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
    }

    @Test(arguments: [48_000.0, 44_100.0, 24_000.0])
    func chunkedConversionPreservesDurationAndPitch(inputRate: Double) throws {
        let input = Self.sine(frequency: 440, sampleRate: inputRate, seconds: 2)
        let resampler = try #require(StreamingResampler(from: inputRate, to: 16_000))
        let chunk = Int(inputRate / 10)  // 100 ms, like live capture
        var output: [Float] = []
        var start = 0
        while start < input.count {
            output += try resampler.process(Array(input[start..<min(input.count, start + chunk)]))
            start += chunk
        }
        output += try resampler.finish()

        // Duration: 2 s at 16 kHz, within a few samples of filter edge effects.
        #expect(abs(output.count - 32_000) <= 16)
        // Pitch: 440 Hz ⇒ 880 zero crossings per second; check the steady middle second.
        let crossings = Self.zeroCrossings(output[8_000..<24_000])
        #expect(abs(crossings - 880) <= 2)
        // Amplitude survives (no gain error, no dropped chunks in the middle).
        let peak = output[8_000..<24_000].map(abs).max() ?? 0
        #expect(abs(peak - 0.5) < 0.02)
    }

    @Test func chunkingDoesNotChangeTheSignal() throws {
        let input = Self.sine(frequency: 1_000, sampleRate: 48_000, seconds: 1)
        let whole = try #require(StreamingResampler(from: 48_000, to: 16_000))
        let reference = try whole.process(input) + whole.finish()

        let pieces = try #require(StreamingResampler(from: 48_000, to: 16_000))
        var chunked: [Float] = []
        for s in stride(from: 0, to: input.count, by: 480) {
            chunked += try pieces.process(Array(input[s..<min(input.count, s + 480)]))
        }
        chunked += try pieces.finish()

        #expect(abs(chunked.count - reference.count) <= 2)
        let n = min(chunked.count, reference.count)
        let maxDiff = (0..<n).map { abs(chunked[$0] - reference[$0]) }.max() ?? 0
        #expect(maxDiff < 1e-3)
    }

    @Test func rejectsInvalidRates() {
        #expect(StreamingResampler(from: 0, to: 16_000) == nil)
        #expect(StreamingResampler(from: 48_000, to: -1) == nil)
    }
}
