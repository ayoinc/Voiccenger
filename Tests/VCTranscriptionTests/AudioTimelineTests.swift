import Foundation
import Testing
@testable import VCTranscription

@Suite struct AudioTimelineTests {
    private func sine(frequency: Double, sampleRate: Double, seconds: Double, amplitude: Float = 0.5) -> [Float] {
        (0..<Int(sampleRate * seconds)).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
    }

    private func chunks(_ samples: [Float], size: Int) -> [[Float]] {
        stride(from: 0, to: samples.count, by: size).map { Array(samples[$0..<min($0 + size, samples.count)]) }
    }

    /// Rising zero crossings per second ≈ frequency.
    private func estimatedFrequency(_ samples: [Float], sampleRate: Double) -> Double {
        var crossings = 0
        for i in 1..<samples.count where samples[i - 1] < 0 && samples[i] >= 0 { crossings += 1 }
        return Double(crossings) * sampleRate / Double(samples.count)
    }

    @Test func contiguous48kChunksBecomeOneGaplessSixteenKilohertzStream() throws {
        let timeline = RecognitionTimeline()
        let input = sine(frequency: 440, sampleRate: 48_000, seconds: 2)
        var spans: [RecognitionTimeline.Span] = []
        var time = 5.0
        for chunk in chunks(input, size: 4_800) {
            spans += try timeline.ingest(samples: chunk, sampleRate: 48_000, startTime: time)
            time += Double(chunk.count) / 48_000
        }
        spans += try timeline.flush()

        #expect(spans.first?.startFrame == 80_000)  // 5 s on the session clock
        for (a, b) in zip(spans, spans.dropFirst()) {
            #expect(b.startFrame == a.startFrame + Int64(a.samples.count))
        }
        let output = spans.flatMap(\.samples)
        #expect(abs(output.count - 32_000) <= 16)
        // Skip the converter's settling at both ends, then the tone must survive resampling.
        let body = Array(output[1_000..<(output.count - 1_000)])
        #expect(abs(estimatedFrequency(body, sampleRate: 16_000) - 440) < 2)
        #expect(body.map(abs).max()! > 0.45)
    }

    @Test func gapRestartsTimelineAtTheChunkSessionTime() throws {
        let timeline = RecognitionTimeline()
        let second = [Float](repeating: 0.1, count: 16_000)
        let first = try timeline.ingest(samples: second, sampleRate: 16_000, startTime: 0)
        let afterGap = try timeline.ingest(samples: second, sampleRate: 16_000, startTime: 3)
        #expect(first.map(\.startFrame) == [0])
        #expect(afterGap.map(\.startFrame) == [48_000])
    }

    @Test func smallJitterIsTreatedAsContiguous() throws {
        let timeline = RecognitionTimeline()
        let block = [Float](repeating: 0.1, count: 1_600)
        _ = try timeline.ingest(samples: block, sampleRate: 16_000, startTime: 1)
        let next = try timeline.ingest(samples: block, sampleRate: 16_000, startTime: 1.105)
        #expect(next.map(\.startFrame) == [16_000 + 1_600])
    }

    @Test func overlappingChunkNeverMovesTimelineBackwards() throws {
        let timeline = RecognitionTimeline()
        let block = [Float](repeating: 0.1, count: 16_000)
        _ = try timeline.ingest(samples: block, sampleRate: 16_000, startTime: 10)
        let overlapping = try timeline.ingest(samples: block, sampleRate: 16_000, startTime: 10.5)
        #expect(overlapping.first?.startFrame == 176_000)
    }

    @Test func sampleRateChangeRestartsResamplingWithoutLosingAudio() throws {
        let timeline = RecognitionTimeline()
        var total = 0
        var spans = try timeline.ingest(
            samples: sine(frequency: 300, sampleRate: 44_100, seconds: 1), sampleRate: 44_100, startTime: 0)
        spans += try timeline.ingest(
            samples: sine(frequency: 300, sampleRate: 16_000, seconds: 1), sampleRate: 16_000, startTime: 1)
        spans += try timeline.flush()
        total = spans.reduce(0) { $0 + $1.samples.count }
        #expect(abs(total - 32_000) <= 16)
        let starts = spans.map(\.startFrame)
        #expect(starts == starts.sorted())
        #expect(spans.last.map { $0.startFrame + Int64($0.samples.count) }.map { abs($0 - 32_000) <= 16 } == true)
    }

    @Test func emptyAndInvalidChunksAreIgnored() throws {
        let timeline = RecognitionTimeline()
        #expect(try timeline.ingest(samples: [], sampleRate: 16_000, startTime: 0).isEmpty)
        #expect(try timeline.ingest(samples: [0.1, 0.2], sampleRate: 0, startTime: 0).isEmpty)
    }

    @Test func rollingBufferKeepsOnlyTheNewestSamplesInOrder() {
        var buffer = RollingAudioBuffer(capacity: 5)
        buffer.append([1, 2, 3])
        #expect(buffer.snapshot() == [1, 2, 3])
        buffer.append([4, 5, 6, 7])
        #expect(buffer.snapshot() == [3, 4, 5, 6, 7])
        buffer.append([8])
        #expect(buffer.snapshot() == [4, 5, 6, 7, 8])
        buffer.append(Array(10...20).map(Float.init))
        #expect(buffer.snapshot() == [16, 17, 18, 19, 20])
        buffer.removeAll()
        #expect(buffer.snapshot().isEmpty)
    }
}
