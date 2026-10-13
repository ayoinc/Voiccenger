import AVFAudio
import Accelerate
import Foundation

/// High-quality mono sample-rate conversion (AVAudioConverter, mastering algorithm, max quality).
public enum AudioResampler {
    /// Converts mono samples between rates. Output length is `round(count × to / from)` (±1 frame of
    /// converter latency trimmed or padded), so timelines stay aligned.
    public static func resample(_ samples: [Float], from: Double, to: Double) -> [Float] {
        guard !samples.isEmpty, from > 0, to > 0 else { return [] }
        guard from != to else { return samples }
        guard
            let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 1, interleaved: false),
            let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inFormat, to: outFormat),
            let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return [] }
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }

        let expected = Int((Double(samples.count) * to / from).rounded())
        let blockFrames = AVAudioFrameCount(max(4_096, min(expected + 1_024, 262_144)))
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: blockFrames) else { return [] }

        var result: [Float] = []
        result.reserveCapacity(expected + 64)
        // `nonisolated(unsafe)`: the input block runs synchronously inside `convert`, on this thread.
        nonisolated(unsafe) var supplied = false
        nonisolated(unsafe) let source = input
        while true {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return source
            }
            if output.frameLength > 0 {
                result.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            }
            if status == .endOfStream || status == .error || (status == .inputRanDry && output.frameLength == 0) { break }
        }
        if result.count > expected {
            result.removeLast(result.count - expected)
        } else if result.count < expected {
            result.append(contentsOf: repeatElement(0, count: expected - result.count))
        }
        return result
    }

    /// Decodes any audio file to 16 kHz mono Float32 (channels averaged).
    public static func load16kMono(url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioCaptureError.fileUnreadable(path: url.path, reason: error.localizedDescription)
        }
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0 else { return [] }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw AudioCaptureError.unsupportedFormat("\(format)")
        }
        do {
            try file.read(into: buffer)
        } catch {
            throw AudioCaptureError.fileUnreadable(path: url.path, reason: error.localizedDescription)
        }
        guard let data = buffer.floatChannelData else { throw AudioCaptureError.unsupportedFormat("\(format)") }
        let count = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: count)
        mono.withUnsafeMutableBufferPointer { dst in
            for c in 0..<channels {
                vDSP_vadd(data[c], 1, dst.baseAddress!, 1, dst.baseAddress!, 1, vDSP_Length(count))
            }
            if channels > 1 {
                var scale = 1 / Float(channels)
                vDSP_vsmul(dst.baseAddress!, 1, &scale, dst.baseAddress!, 1, vDSP_Length(count))
            }
        }
        return resample(mono, from: format.sampleRate, to: 16_000)
    }
}
