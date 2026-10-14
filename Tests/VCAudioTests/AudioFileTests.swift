import AVFAudio
import Foundation
import Testing
import VCModels

@testable import VCAudio

enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: ".fixtures", directoryHint: .isDirectory)
    static let meeting = directory.appending(path: "meeting.wav")
    static var hasMeeting: Bool { FileManager.default.fileExists(atPath: meeting.path) }
}

func temporaryURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appending(path: "vcaudio-\(UUID().uuidString)-\(name)")
}

func sine(frequency: Double, seconds: Double, sampleRate: Double, amplitude: Float = 0.5) -> [Float] {
    (0..<Int(seconds * sampleRate)).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
}

/// Writes a Float32 file with one array per channel.
func writeFile(_ channels: [[Float]], sampleRate: Double, to url: URL) throws {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels.count),
        interleaved: false)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[0].count))!
    buffer.frameLength = AVAudioFrameCount(channels[0].count)
    for (c, samples) in channels.enumerated() {
        samples.withUnsafeBufferPointer { buffer.floatChannelData![c].update(from: $0.baseAddress!, count: samples.count) }
    }
    try file.write(from: buffer)
    // Before macOS 15 the file is finalized when `file` is released on return.
    if #available(macOS 15.0, *) { file.close() }
}

/// Frequency (Hz) of the strongest zero-crossing rate estimate — enough to tell a 1 kHz tone from aliasing.
func zeroCrossingFrequency(_ samples: [Float], sampleRate: Double) -> Double {
    var crossings = 0
    for i in 1..<samples.count where (samples[i - 1] < 0) != (samples[i] < 0) { crossings += 1 }
    return Double(crossings) / 2 / (Double(samples.count) / sampleRate)
}

func rms(_ samples: some Collection<Float>) -> Float {
    (samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count))).squareRoot()
}

@Suite("AudioFileSource")
struct AudioFileSourceTests {
    @Test("Chunks are contiguous from 0 and cover the whole file", .enabled(if: Fixtures.hasMeeting))
    func fixtureTimeline() async throws {
        let file = try AVAudioFile(forReading: Fixtures.meeting)
        let expectedDuration = Double(file.length) / file.processingFormat.sampleRate
        let source = AudioFileSource(url: Fixtures.meeting, channel: .microphone, clock: SessionClock(), realtime: false)
        var chunks: [AudioChunk] = []
        for await chunk in try await source.start() { chunks.append(chunk) }

        #expect(chunks.first?.startTime == 0)
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            #expect(abs(b.startTime - a.range.end) < 1e-9, "gap between \(a.range) and \(b.range)")
        }
        let total = chunks.reduce(0) { $0 + $1.duration }
        #expect(abs(total - expectedDuration) < 1e-6)
        #expect(chunks.dropLast().allSatisfy { abs($0.duration - 0.1) < 1e-9 })
        #expect(chunks.allSatisfy { $0.channelSamples == nil && $0.channel == .microphone }, "mono file has no channel samples")
    }

    @Test("Multichannel files carry every channel and a mono mixdown")
    func multichannel() async throws {
        let url = temporaryURL("stereo.caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let left = [Float](repeating: 0.5, count: 4_800)
        let right = [Float](repeating: -0.1, count: 4_800)
        try writeFile([left, right], sampleRate: 48_000, to: url)

        let source = AudioFileSource(url: url, channel: .system, clock: SessionClock(), realtime: false, chunkDuration: 0.02)
        var chunks: [AudioChunk] = []
        for await chunk in try await source.start() { chunks.append(chunk) }
        #expect(chunks.count == 5)
        let first = try #require(chunks.first)
        #expect(first.channelSamples?.count == 2)
        #expect(first.channelSamples?[0].first == 0.5)
        #expect(abs((first.samples.first ?? 0) - 0.2) < 1e-6)
        #expect(first.channel == .system)
    }

    @Test("Realtime playback paces chunks against the session clock")
    func realtimePacing() async throws {
        let url = temporaryURL("tone.caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeFile([sine(frequency: 440, seconds: 0.5, sampleRate: 16_000)], sampleRate: 16_000, to: url)
        let clock = SessionClock()
        let source = AudioFileSource(url: url, channel: .microphone, clock: clock, realtime: true)
        var first: AudioChunk?
        var count = 0
        for await chunk in try await source.start() {
            #expect(clock.now() >= chunk.startTime - 0.01, "delivered before its time")
            if first == nil { first = chunk }
            count += 1
        }
        let start = try #require(first?.startTime)
        #expect(count == 5)
        // Five 0.1 s chunks: the last is due 0.4 s after the first.
        #expect(clock.now() - start >= 0.39)
    }

    @Test("A missing file fails with a descriptive error")
    func missingFile() async {
        let source = AudioFileSource(url: URL(fileURLWithPath: "/nonexistent.wav"), channel: .microphone, clock: SessionClock(), realtime: false)
        await #expect(throws: AudioCaptureError.self) { _ = try await source.start() }
    }
}

@Suite("AudioResampler")
struct AudioResamplerTests {
    @Test("Length follows the rate ratio and a tone keeps its pitch and level", arguments: [
        (48_000.0, 16_000.0), (44_100.0, 16_000.0), (16_000.0, 48_000.0), (24_000.0, 16_000.0),
    ])
    func ratio(from: Double, to: Double) {
        let input = sine(frequency: 1_000, seconds: 1, sampleRate: from)
        let output = AudioResampler.resample(input, from: from, to: to)
        #expect(output.count == Int((Double(input.count) * to / from).rounded()))
        let steady = output[output.count / 10..<output.count * 9 / 10]
        #expect(abs(zeroCrossingFrequency(Array(steady), sampleRate: to) - 1_000) < 5)
        #expect(abs(rms(steady) - rms(input)) < 0.01)
    }

    @Test("Content above the new Nyquist is filtered out rather than aliased")
    func antiAliasing() {
        let input = sine(frequency: 12_000, seconds: 1, sampleRate: 48_000)
        let output = AudioResampler.resample(input, from: 48_000, to: 16_000)
        #expect(rms(output[1_000..<15_000]) < 0.01)
    }

    @Test("Same-rate and empty inputs pass through")
    func identity() {
        #expect(AudioResampler.resample([1, 2, 3], from: 16_000, to: 16_000) == [1, 2, 3])
        #expect(AudioResampler.resample([], from: 48_000, to: 16_000).isEmpty)
    }

    @Test("load16kMono decodes, mixes down and resamples")
    func load() throws {
        let url = temporaryURL("tone.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let tone = sine(frequency: 500, seconds: 2, sampleRate: 44_100)
        try writeFile([tone, [Float](repeating: 0, count: tone.count)], sampleRate: 44_100, to: url)
        let mono = try AudioResampler.load16kMono(url: url)
        #expect(mono.count == 32_000)
        #expect(abs(rms(mono[3_000..<29_000]) - rms(tone) / 2) < 0.01)
    }
}

@Suite("AudioRecorder")
struct AudioRecorderTests {
    @Test("Recorded chunks read back as the same audio (16-bit precision)")
    func roundTrip() throws {
        let url = temporaryURL("rec.caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let tone = sine(frequency: 300, seconds: 1, sampleRate: 16_000, amplitude: 0.4)
        let recorder = try AudioRecorder(url: url, sampleRate: 16_000)
        for start in stride(from: 0, to: tone.count, by: 1_600) {
            let piece = Array(tone[start..<min(tone.count, start + 1_600)])
            recorder.append(AudioChunk(channel: .microphone, startTime: Double(start) / 16_000, sampleRate: 16_000, samples: piece))
        }
        recorder.close()
        recorder.append(AudioChunk(channel: .microphone, startTime: 1, sampleRate: 16_000, samples: tone))  // ignored after close

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 16)
        let back = try AudioResampler.load16kMono(url: url)
        #expect(back.count == tone.count)
        let maxError = zip(back, tone).map { abs($0 - $1) }.max() ?? 1
        #expect(maxError < 1.0 / 16_000)
    }

    @Test("Chunks at another rate are resampled to the recorder's rate")
    func resamplesInput() throws {
        let url = temporaryURL("rec48.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try AudioRecorder(url: url, sampleRate: 16_000)
        recorder.append(AudioChunk(channel: .system, startTime: 0, sampleRate: 48_000, samples: sine(frequency: 400, seconds: 0.5, sampleRate: 48_000)))
        recorder.close()
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.length == 8_000)
    }

    @Test("An unwritable location fails at creation")
    func unwritable() {
        #expect(throws: AudioCaptureError.self) {
            _ = try AudioRecorder(url: URL(fileURLWithPath: "/System/forbidden/x.caf"), sampleRate: 16_000)
        }
    }
}
