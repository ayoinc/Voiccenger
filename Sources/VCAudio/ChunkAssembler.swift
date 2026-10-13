import Accelerate
import Foundation
import VCModels

/// Re-blocks arbitrarily sized multichannel buffers into fixed-length `AudioChunk`s.
///
/// Timestamps are derived from the frame count, never from wall-clock arrival, so they cannot drift:
/// the first buffer anchors the timeline at `arrivalTime − bufferedDuration`, and every later chunk starts
/// exactly where the previous one ended.
struct ChunkAssembler: Sendable {
    let channel: AudioChannel
    let sampleRate: Double
    let chunkFrames: Int
    let channelCount: Int
    /// Channels averaged into the mono `samples`.
    let mixIndices: [Int]
    /// Whether chunks carry every channel in `channelSamples`.
    let keepChannels: Bool
    /// Session time of the first frame; set by the first append.
    private(set) var origin: TimeInterval?
    /// The anchored origin is never earlier than this (keeps the timeline monotonic across restarts).
    private let minimumOrigin: TimeInterval
    private(set) var framesEmitted = 0
    private var pending: [[Float]]

    init(
        channel: AudioChannel, sampleRate: Double, chunkDuration: TimeInterval, channelCount: Int,
        mixIndices: [Int]? = nil, keepChannels: Bool, minimumOrigin: TimeInterval = -.infinity
    ) {
        precondition(sampleRate > 0 && channelCount > 0)
        self.channel = channel
        self.sampleRate = sampleRate
        self.chunkFrames = max(1, Int((chunkDuration * sampleRate).rounded()))
        self.channelCount = channelCount
        let mix = (mixIndices ?? Array(0..<channelCount)).filter { (0..<channelCount).contains($0) }
        self.mixIndices = mix.isEmpty ? Array(0..<channelCount) : mix
        self.keepChannels = keepChannels
        self.minimumOrigin = minimumOrigin
        self.pending = Array(repeating: [], count: channelCount)
        for i in pending.indices { pending[i].reserveCapacity(chunkFrames * 2) }
    }

    /// Session time just past the last emitted frame.
    var emittedEnd: TimeInterval? {
        origin.map { $0 + Double(framesEmitted) / sampleRate }
    }

    /// Appends `frames` frames. `samples(c)` must return at least `frames` values for channel `c`.
    /// `arrivalTime` is the session time at which the last of these frames was captured.
    mutating func append(
        frames: Int, arrivalTime: TimeInterval, samples: (Int) -> UnsafeBufferPointer<Float>
    ) -> [AudioChunk] {
        guard frames > 0 else { return [] }
        if origin == nil {
            origin = max(minimumOrigin, arrivalTime - Double(frames) / sampleRate)
        }
        for c in 0..<channelCount {
            pending[c].append(contentsOf: UnsafeBufferPointer(rebasing: samples(c)[0..<frames]))
        }
        var chunks: [AudioChunk] = []
        while pending[0].count >= chunkFrames {
            chunks.append(emit(frames: chunkFrames))
        }
        return chunks
    }

    /// Appends `frames` of silence on every channel (used to keep the timeline when capture drops frames).
    mutating func appendSilence(frames: Int, arrivalTime: TimeInterval) -> [AudioChunk] {
        guard frames > 0 else { return [] }
        let zeros = [Float](repeating: 0, count: frames)
        return zeros.withUnsafeBufferPointer { zero in
            append(frames: frames, arrivalTime: arrivalTime) { _ in zero }
        }
    }

    /// Emits whatever is pending as a final, shorter chunk.
    mutating func flush() -> AudioChunk? {
        let remaining = pending[0].count
        guard remaining > 0, origin != nil else { return nil }
        return emit(frames: remaining)
    }

    private mutating func emit(frames: Int) -> AudioChunk {
        let start = origin! + Double(framesEmitted) / sampleRate
        let mono = Self.mixdown(pending, indices: mixIndices, frames: frames)
        let channels: [[Float]]? = keepChannels ? pending.map { Array($0[0..<frames]) } : nil
        for c in 0..<channelCount { pending[c].removeFirst(frames) }
        framesEmitted += frames
        return AudioChunk(
            channel: channel, startTime: start, sampleRate: sampleRate, samples: mono, channelSamples: channels)
    }

    /// Average of the selected channels over the first `frames` frames.
    static func mixdown(_ channels: [[Float]], indices: [Int], frames: Int) -> [Float] {
        guard let first = indices.first else { return [] }
        if indices.count == 1 { return Array(channels[first][0..<frames]) }
        var out = [Float](repeating: 0, count: frames)
        out.withUnsafeMutableBufferPointer { dst in
            for i in indices {
                channels[i].withUnsafeBufferPointer { src in
                    vDSP_vadd(src.baseAddress!, 1, dst.baseAddress!, 1, dst.baseAddress!, 1, vDSP_Length(frames))
                }
            }
            var scale = 1 / Float(indices.count)
            vDSP_vsmul(dst.baseAddress!, 1, &scale, dst.baseAddress!, 1, vDSP_Length(frames))
        }
        return out
    }
}
