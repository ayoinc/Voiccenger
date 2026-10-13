@preconcurrency import AVFAudio
import Foundation

/// Streaming AVAudioConverter wrapper. Keeps converter state between calls so sample-rate
/// conversion of consecutive chunks is seamless (no clicks or dropped samples at chunk borders).
/// The default prime method is zero-latency: output frame `n` is time-aligned with input time `n / rate`.
final class PCMStreamConverter {
    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw TranscriptionError.audioConversionFailed("no converter from \(inputFormat) to \(outputFormat)")
        }
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        converter.primeMethod = .normal
        self.converter = converter
    }

    var ratio: Double { outputFormat.sampleRate / inputFormat.sampleRate }

    /// Converts one buffer. May return fewer frames than `frames × ratio` while the resampler holds
    /// back its filter tail; `flush()` releases it.
    func convert(_ buffer: AVAudioPCMBuffer) throws -> [AVAudioPCMBuffer] {
        var supplied = false
        return try drain(expectedFrames: Int(buffer.frameLength)) { status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
    }

    /// Emits the frames still held by the converter and resets it for a new, unrelated stream.
    func flush() throws -> [AVAudioPCMBuffer] {
        let out = try drain(expectedFrames: 0) { status in
            status.pointee = .endOfStream
            return nil
        }
        converter.reset()
        return out
    }

    private func drain(
        expectedFrames: Int,
        input: (UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer?
    ) throws -> [AVAudioPCMBuffer] {
        let capacity = AVAudioFrameCount((Double(expectedFrames) * ratio).rounded(.up)) + 1024
        var outputs: [AVAudioPCMBuffer] = []
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                throw TranscriptionError.audioConversionFailed("cannot allocate output buffer")
            }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, statusPointer in
                input(statusPointer)
            }
            if out.frameLength > 0 { outputs.append(out) }
            switch status {
            case .haveData:
                continue
            case .inputRanDry, .endOfStream:
                return outputs
            case .error:
                throw TranscriptionError.audioConversionFailed(error?.localizedDescription ?? "unknown error")
            @unknown default:
                throw TranscriptionError.audioConversionFailed("unexpected converter status \(status.rawValue)")
            }
        }
    }
}

enum PCM {
    static let recognitionRate: Double = 16_000

    static func monoFloatFormat(sampleRate: Double) throws -> AVAudioFormat {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        else { throw TranscriptionError.audioConversionFailed("invalid sample rate \(sampleRate)") }
        return format
    }

    static func monoFloatBuffer(_ samples: [Float], format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))),
            let channel = buffer.floatChannelData?[0]
        else { throw TranscriptionError.audioConversionFailed("cannot allocate input buffer") }
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { channel.update(from: base, count: src.count) }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    static func floatSamples(_ buffers: [AVAudioPCMBuffer]) -> [Float] {
        var samples: [Float] = []
        samples.reserveCapacity(buffers.reduce(0) { $0 + Int($1.frameLength) })
        for buffer in buffers {
            guard let channel = buffer.floatChannelData?[0] else { continue }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        return samples
    }

    static func sameFormat(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.commonFormat == b.commonFormat && a.sampleRate == b.sampleRate
            && a.channelCount == b.channelCount && a.isInterleaved == b.isInterleaved
    }
}

/// Converts mono chunks of any sample rate into a contiguous 16 kHz Float32 stream addressed by
/// absolute frame index on the session clock (frame `n` ⇔ `n / 16000` s). Restarts the timeline
/// when the source rate changes or chunks are not contiguous, never letting frames overlap.
final class RecognitionTimeline {
    /// Chunks whose start deviates from the expected continuation by more than this are a discontinuity.
    static let discontinuityTolerance: TimeInterval = 0.02

    private var resampler: PCMStreamConverter?
    private var inputRate: Double?
    private var expectedInputTime: TimeInterval?
    private var nextFrame: Int64 = 0
    private var lastEndFrame: Int64 = 0

    struct Span {
        let samples: [Float]
        let startFrame: Int64
    }

    func ingest(samples: [Float], sampleRate: Double, startTime: TimeInterval) throws -> [Span] {
        guard sampleRate > 0, !samples.isEmpty else { return [] }
        var spans: [Span] = []
        let contiguous: Bool =
            if let expected = expectedInputTime, inputRate == sampleRate {
                abs(startTime - expected) <= Self.discontinuityTolerance
            } else { false }
        if !contiguous {
            spans += try flush()
            inputRate = sampleRate
            resampler =
                sampleRate == PCM.recognitionRate
                ? nil
                : try PCMStreamConverter(
                    from: PCM.monoFloatFormat(sampleRate: sampleRate),
                    to: PCM.monoFloatFormat(sampleRate: PCM.recognitionRate))
            nextFrame = max(Int64((startTime * PCM.recognitionRate).rounded()), lastEndFrame)
        }
        expectedInputTime = startTime + Double(samples.count) / sampleRate
        let converted: [Float]
        if let resampler {
            converted = PCM.floatSamples(
                try resampler.convert(PCM.monoFloatBuffer(samples, format: resampler.inputFormat)))
        } else {
            converted = samples
        }
        if let span = emit(converted) { spans.append(span) }
        return spans
    }

    /// Releases samples still held by the resampler (end of input or before a discontinuity).
    func flush() throws -> [Span] {
        guard let resampler else { return [] }
        let tail = PCM.floatSamples(try resampler.flush())
        return emit(tail).map { [$0] } ?? []
    }

    private func emit(_ samples: [Float]) -> Span? {
        guard !samples.isEmpty else { return nil }
        let span = Span(samples: samples, startFrame: nextFrame)
        nextFrame += Int64(samples.count)
        lastEndFrame = nextFrame
        return span
    }
}
