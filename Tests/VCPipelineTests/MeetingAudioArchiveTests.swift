import Foundation
import Testing
import VCModels

@testable import VCPipeline

@Suite("Meeting audio archive")
struct MeetingAudioArchiveTests {
    /// Sample values that survive Int16 storage exactly, distinct per index.
    static func ramp(_ indices: Range<Int>) -> [Float] {
        indices.map { Float($0 % 30_000 + 1) / Float(Int16.max) }
    }

    static func chunk(_ indices: Range<Int>, channel: AudioChannel = .microphone) -> AudioChunk {
        AudioChunk(
            channel: channel, startTime: Double(indices.lowerBound) / 16_000, sampleRate: 16_000,
            samples: ramp(indices))
    }

    @Test("Slices are sample-exact across chunk and storage-block boundaries")
    func exactSlicing() async {
        // 1 600-sample chunks over 1 000-sample blocks: chunk and block edges never coincide.
        let archive = MeetingAudioArchive(blockSize: 1_000)
        for start in stride(from: 0, to: 16_000, by: 1_600) { await archive.append(Self.chunk(start..<(start + 1_600))) }

        #expect(await archive.duration(of: .microphone) == 1)
        #expect(await archive.samples(channel: .microphone, range: TimeRange(start: 0.05, end: 0.3)) == Self.ramp(800..<4_800))
        #expect(await archive.samples(channel: .microphone, range: TimeRange(start: 0.0625, end: 0.0625 + 1.0 / 16_000)) == Self.ramp(1_000..<1_001))
        // Ranges past the audio are clamped; other channels are separate.
        #expect(await archive.samples(channel: .microphone, range: TimeRange(start: 0.9, end: 3)) == Self.ramp(14_400..<16_000))
        #expect(await archive.samples(channel: .system, range: TimeRange(start: 0, end: 1)).isEmpty)
    }

    @Test("Late starts and capture gaps are silence, so sample time is session time")
    func gapsKeepTimeline() async {
        let archive = MeetingAudioArchive(blockSize: 1_000)
        await archive.append(Self.chunk(8_000..<9_600))  // first audio at 0.5 s
        await archive.append(Self.chunk(9_600..<11_200))
        await archive.append(Self.chunk(24_000..<25_600))  // resumes at 1.5 s after a 0.8 s gap

        #expect(await archive.duration(of: .microphone) == 1.6)
        let all = await archive.samples(channel: .microphone, range: TimeRange(start: 0, end: 1.6))
        #expect(all[0..<8_000].allSatisfy { $0 == 0 })
        #expect(Array(all[8_000..<11_200]) == Self.ramp(8_000..<11_200))
        #expect(all[11_200..<24_000].allSatisfy { $0 == 0 })
        #expect(Array(all[24_000..<25_600]) == Self.ramp(24_000..<25_600))
    }

    @Test("Waiting for a range returns once the audio arrives, or when the channel ends")
    func waiting() async {
        let archive = MeetingAudioArchive(blockSize: 1_000)
        let waiter = Task { await archive.waitForSamples(channel: .microphone, range: TimeRange(start: 0.1, end: 0.2)) }
        await archive.append(Self.chunk(0..<1_600))
        await archive.append(Self.chunk(1_600..<3_200))
        #expect(await waiter.value == Self.ramp(1_600..<3_200))

        let beyond = Task { await archive.waitForSamples(channel: .microphone, range: TimeRange(start: 0.15, end: 5)) }
        await archive.finish(.microphone)
        #expect(await beyond.value == Self.ramp(2_400..<3_200))
    }

    @Test("Device-rate audio is resampled to 16 kHz at its session time")
    func resampledPlacement() async {
        let archive = MeetingAudioArchive()
        let rate = 48_000.0
        // 2 s at 48 kHz in 0.1 s chunks, a 440 Hz tone between 1.0 and 1.5 s.
        for c in 0..<20 {
            let start = Double(c) / 10
            let samples = (0..<4_800).map { i -> Float in
                let t = start + Double(i) / rate
                return t >= 1.0 && t < 1.5 ? Float(0.5 * sin(2 * .pi * 440 * t)) : 0
            }
            await archive.append(AudioChunk(channel: .microphone, startTime: start, sampleRate: rate, samples: samples))
        }
        await archive.finish(.microphone)

        #expect(abs(await archive.duration(of: .microphone) - 2) < 0.01)
        func rms(_ from: Double, _ to: Double) async -> Float {
            let s = await archive.samples(channel: .microphone, range: TimeRange(start: from, end: to))
            return (s.reduce(0) { $0 + $1 * $1 } / Float(max(1, s.count))).squareRoot()
        }
        #expect(await rms(0.5, 0.99) < 0.01)
        #expect(await rms(1.01, 1.49) > 0.3)
        #expect(await rms(1.51, 1.95) < 0.01)
    }
}
