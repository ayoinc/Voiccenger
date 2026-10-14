import AVFAudio
import Foundation
import VCModels

/// Writes chunks of one channel to a 16-bit CAF/WAV file. Thread-safe.
///
/// The container follows the URL's extension (`.caf`, `.wav`, `.aiff`). Chunks at another sample rate are
/// resampled to the recorder's rate; only the mono `samples` are written.
public final class AudioRecorder: Sendable {
    public let url: URL
    public let sampleRate: Double
    private let file: Mutex<AVAudioFile?>
    private let format: AVAudioFormat

    public init(url: URL, sampleRate: Double) throws {
        guard sampleRate > 0,
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        else { throw AudioCaptureError.unsupportedFormat("recording at \(sampleRate) Hz") }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            self.file = Mutex(file)
        } catch {
            throw AudioCaptureError.fileUnwritable(path: url.path, reason: error.localizedDescription)
        }
        self.url = url
        self.sampleRate = sampleRate
        self.format = format
    }

    /// Appends the chunk's mono samples. Ignored after `close()`; write errors close the file.
    public func append(_ chunk: AudioChunk) {
        let samples = chunk.sampleRate == sampleRate
            ? chunk.samples : AudioResampler.resample(chunk.samples, from: chunk.sampleRate, to: sampleRate)
        guard !samples.isEmpty,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        file.withLock { file in
            guard let current = file else { return }
            do {
                try current.write(from: buffer)
            } catch {
                Self.close(current)
                file = nil
            }
        }
    }

    /// Finalizes the file header. Further appends are ignored.
    public func close() {
        file.withLock { file in
            if let current = file { Self.close(current) }
            file = nil
        }
    }

    /// `AVAudioFile.close()` is macOS 15+; before it, releasing the last reference (`file = nil`) finalizes the file.
    private static func close(_ file: AVAudioFile) {
        if #available(macOS 15.0, *) { file.close() }
    }
}
