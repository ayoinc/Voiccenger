@preconcurrency import AVFAudio
import Foundation

/// Mono Float32 sample-rate converter that keeps filter state across chunks, so a stream cut
/// into 100 ms pieces converts exactly like one long buffer. Not thread-safe: owned by one actor.
final class StreamingResampler {
    let inputRate: Double
    let outputRate: Double
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init?(from inputRate: Double, to outputRate: Double) {
        guard inputRate > 0, outputRate > 0,
            let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false),
            let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { return nil }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        self.inputRate = inputRate
        self.outputRate = outputRate
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
    }

    /// Converts the next piece of the stream. Output may lag input by the filter delay.
    func process(_ samples: [Float]) throws -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return []
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            input.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        return try drain(input: input)
    }

    /// Flushes the converter's remaining samples and resets it for reuse.
    func finish() throws -> [Float] {
        let tail = try drain(input: nil)
        converter.reset()
        return tail
    }

    private func drain(input: AVAudioPCMBuffer?) throws -> [Float] {
        let inputFrames = Double(input?.frameLength ?? 0)
        let capacity = AVAudioFrameCount((inputFrames * outputRate / inputRate).rounded(.up)) + 1024
        var output: [Float] = []
        var supplied = false
        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return output }
            var conversionError: NSError?
            let status = converter.convert(to: buffer, error: &conversionError) { _, inputStatus in
                if let input, !supplied {
                    supplied = true
                    inputStatus.pointee = .haveData
                    return input
                }
                inputStatus.pointee = input == nil ? .endOfStream : .noDataNow
                return nil
            }
            if let conversionError { throw conversionError }
            if buffer.frameLength > 0, let data = buffer.floatChannelData?[0] {
                output.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
            }
            switch status {
            case .haveData where buffer.frameLength == buffer.frameCapacity:
                continue
            case .error:
                throw NSError(domain: "VCSpeakers.StreamingResampler", code: -1)
            default:
                return output
            }
        }
    }
}
