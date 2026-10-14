import AVFAudio
import Foundation
import VCModels

/// Plays a file into the pipeline. realtime=false emits as fast as consumed (tests/CLI). Multichannel files populate channelSamples.
///
/// The stream is pull-based: a chunk is decoded only when the consumer asks for the next one, so long
/// files never sit in memory. With `realtime` the first chunk starts at the session clock's current time
/// and each chunk is delivered no earlier than its start; without it the timeline is the file position
/// (the first chunk starts at 0), which is what offline processing aligns against.
public final class AudioFileSource: AudioSource {
    public let channel: AudioChannel
    public let url: URL
    private let clock: SessionClock
    private let realtime: Bool
    private let chunkDuration: TimeInterval
    private let state = Mutex(State())

    private struct State {
        var file: AVAudioFile?
        var buffer: AVAudioPCMBuffer?
        var assembler: ChunkAssembler?
        var ready: [AudioChunk] = []
        var finished = false
        var running = false
        /// Session time at which the file's first frame plays (realtime pacing).
        var origin: TimeInterval = 0
    }

    public init(url: URL, channel: AudioChannel, clock: SessionClock, realtime: Bool, chunkDuration: TimeInterval = 0.1) {
        self.url = url
        self.channel = channel
        self.clock = clock
        self.realtime = realtime
        self.chunkDuration = max(0.01, chunkDuration)
    }

    public func start() async throws -> AsyncStream<AudioChunk> {
        let url = self.url, channel = self.channel, chunkDuration = self.chunkDuration
        let origin = realtime ? clock.now() : 0
        // The (non-Sendable) file and buffer are created inside the lock so they never leave its region.
        try state.withLock { s in
            guard !s.running else { throw AudioCaptureError.alreadyRunning }
            let file: AVAudioFile
            do {
                file = try AVAudioFile(forReading: url)
            } catch {
                throw AudioCaptureError.fileUnreadable(path: url.path, reason: error.localizedDescription)
            }
            let format = file.processingFormat
            let channels = Int(format.channelCount)
            guard channels > 0, format.sampleRate > 0 else {
                throw AudioCaptureError.unsupportedFormat("\(url.lastPathComponent) has no audio channels")
            }
            let assembler = ChunkAssembler(
                channel: channel, sampleRate: format.sampleRate, chunkDuration: chunkDuration, channelCount: channels,
                keepChannels: channels > 1)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(assembler.chunkFrames))
            else { throw AudioCaptureError.unsupportedFormat("\(format)") }
            s = State(file: file, buffer: buffer, assembler: assembler, running: true, origin: origin)
        }

        let clock = self.clock
        let realtime = self.realtime
        return AsyncStream(unfolding: { [weak self] in
            guard let self, let chunk = self.next() else { return nil }
            if realtime {
                let wait = chunk.startTime - clock.now()
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            }
            return chunk
        }, onCancel: { [weak self] in
            self?.finish()
        })
    }

    public func stop() async {
        finish()
    }

    private func finish() {
        state.withLock { s in
            s.finished = true
            s.running = false
            s.ready.removeAll()
            s.file = nil
        }
    }

    /// Decodes until a chunk is ready; nil at end of file or after `stop()`.
    private func next() -> AudioChunk? {
        state.withLock { s -> AudioChunk? in
            while s.ready.isEmpty && !s.finished {
                guard let file = s.file, let buffer = s.buffer else {
                    s.finished = true
                    break
                }
                do {
                    try file.read(into: buffer, frameCount: buffer.frameCapacity)
                } catch {
                    // A decode error mid-file ends the stream like EOF; what was read is delivered.
                    buffer.frameLength = 0
                }
                let frames = Int(buffer.frameLength)
                if frames == 0 {
                    if let tail = s.assembler?.flush() { s.ready.append(tail) }
                    s.finished = true
                    s.running = false
                    s.file = nil
                    break
                }
                guard let data = buffer.floatChannelData else {
                    s.finished = true
                    break
                }
                // File time, shifted to the realtime origin when pacing.
                let arrival = s.origin + Double(file.framePosition) / file.processingFormat.sampleRate
                let chunks = s.assembler?.append(frames: frames, arrivalTime: arrival) { c in
                    UnsafeBufferPointer(start: data[c], count: frames)
                } ?? []
                s.ready.append(contentsOf: chunks)
            }
            return s.ready.isEmpty ? nil : s.ready.removeFirst()
        }
    }
}
