import Foundation
import VCModels
import VCSpeakers

/// The whole meeting's audio per channel at 16 kHz mono Int16 (≈115 MB per channel-hour), so any segment
/// can be re-transcribed by another engine after it was attributed to a speaker.
///
/// Sample `i` of a channel is session time `i / 16 000`: leading silence and capture gaps are zero-filled.
/// Storage is a list of fixed-size blocks, so growth never copies earlier audio.
public actor MeetingAudioArchive {
    public static let sampleRate: Double = 16_000

    /// Input continuing within this many seconds of the previous chunk's end is treated as contiguous.
    static let continuityTolerance: TimeInterval = 0.05

    private struct Track {
        var blocks: [[Int16]] = []
        /// Samples written; the index of the next sample.
        var count = 0
        var inputRate: Double = 0
        var resampler: StreamingResampler?
        /// Session time where the next contiguous input chunk starts.
        var expectedStart: TimeInterval?
        var finished = false
    }

    private struct Waiter {
        let channel: AudioChannel
        let endIndex: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let blockSize: Int
    private var tracks: [AudioChannel: Track] = [:]
    private var waiters: [Waiter] = []

    /// - Parameter blockSize: samples per storage block (default 60 s).
    public init(blockSize: Int = 960_000) {
        self.blockSize = max(1, blockSize)
    }

    /// Adds a chunk at any sample rate. Chunks must arrive in time order per channel; a chunk that starts
    /// after a gap is placed at its session time with silence in between.
    public func append(_ chunk: AudioChunk) {
        guard chunk.sampleRate > 0, !chunk.samples.isEmpty else { return }
        var track = tracks.removeValue(forKey: chunk.channel) ?? Track()
        guard !track.finished else {
            tracks[chunk.channel] = track
            return
        }
        let contiguous = track.inputRate == chunk.sampleRate
            && track.expectedStart.map { abs(chunk.startTime - $0) <= Self.continuityTolerance } == true
        if !contiguous {
            flushResampler(&track)
            track.inputRate = chunk.sampleRate
            track.resampler =
                chunk.sampleRate == Self.sampleRate ? nil : StreamingResampler(from: chunk.sampleRate, to: Self.sampleRate)
            let target = Int((chunk.startTime * Self.sampleRate).rounded())
            if target > track.count { write(zerosCount: target - track.count, to: &track) }
        }
        if chunk.sampleRate == Self.sampleRate {
            write(chunk.samples, to: &track)
        } else if let resampler = track.resampler, let converted = try? resampler.process(chunk.samples) {
            write(converted, to: &track)
        } else {
            // No converter for this rate: keep the timeline with silence rather than shifting later audio.
            write(zerosCount: Int((chunk.duration * Self.sampleRate).rounded()), to: &track)
        }
        track.expectedStart = chunk.range.end
        tracks[chunk.channel] = track
        resumeWaiters()
    }

    /// Marks a channel's input complete: flushes resampling and releases anyone waiting for more audio.
    public func finish(_ channel: AudioChannel) {
        var track = tracks.removeValue(forKey: channel) ?? Track()
        flushResampler(&track)
        track.finished = true
        tracks[channel] = track
        resumeWaiters()
    }

    /// Seconds of audio held for `channel` (from session time 0).
    public func duration(of channel: AudioChannel) -> TimeInterval {
        Double(tracks[channel]?.count ?? 0) / Self.sampleRate
    }

    /// 16 kHz Float32 samples covering `range` (clamped to the audio held so far).
    public func samples(channel: AudioChannel, range: TimeRange) -> [Float] {
        guard let track = tracks[channel] else { return [] }
        let lo = max(0, Int((range.start * Self.sampleRate).rounded()))
        let hi = min(track.count, Int((range.end * Self.sampleRate).rounded()))
        guard hi > lo else { return [] }
        var out: [Float] = []
        out.reserveCapacity(hi - lo)
        var i = lo
        while i < hi {
            let block = track.blocks[i / blockSize]
            let offset = i % blockSize
            let n = min(hi - i, blockSize - offset)
            for v in block[offset..<(offset + n)] { out.append(Float(v) / Float(Int16.max)) }
            i += n
        }
        return out
    }

    /// Like `samples(channel:range:)`, first waiting until the channel's audio reaches `range.end` or the
    /// channel is finished.
    public func waitForSamples(channel: AudioChannel, range: TimeRange) async -> [Float] {
        let end = Int((range.end * Self.sampleRate).rounded())
        if !isAvailable(channel: channel, through: end) {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(channel: channel, endIndex: end, continuation: continuation))
            }
        }
        return samples(channel: channel, range: range)
    }

    // MARK: - Storage

    private func isAvailable(channel: AudioChannel, through end: Int) -> Bool {
        guard let track = tracks[channel] else { return false }
        return track.finished || track.count >= end
    }

    private func resumeWaiters() {
        var waiting: [Waiter] = []
        for waiter in waiters {
            if isAvailable(channel: waiter.channel, through: waiter.endIndex) {
                waiter.continuation.resume()
            } else {
                waiting.append(waiter)
            }
        }
        waiters = waiting
    }

    private func flushResampler(_ track: inout Track) {
        guard let resampler = track.resampler else { return }
        track.resampler = nil
        if let tail = try? resampler.finish(), !tail.isEmpty { write(tail, to: &track) }
    }

    private func write(_ samples: [Float], to track: inout Track) {
        var i = 0
        while i < samples.count {
            openBlock(&track)
            let n = min(samples.count - i, blockSize - track.count % blockSize)
            let last = track.blocks.count - 1
            for s in samples[i..<(i + n)] {
                track.blocks[last].append(Int16((max(-1, min(1, s)) * Float(Int16.max)).rounded()))
            }
            track.count += n
            i += n
        }
    }

    private func write(zerosCount count: Int, to track: inout Track) {
        var remaining = count
        while remaining > 0 {
            openBlock(&track)
            let n = min(remaining, blockSize - track.count % blockSize)
            let last = track.blocks.count - 1
            track.blocks[last].append(contentsOf: repeatElement(0, count: n))
            track.count += n
            remaining -= n
        }
    }

    /// Starts a new block when every block is full.
    private func openBlock(_ track: inout Track) {
        guard track.blocks.count * blockSize == track.count else { return }
        var block: [Int16] = []
        block.reserveCapacity(blockSize)
        track.blocks.append(block)
    }
}
