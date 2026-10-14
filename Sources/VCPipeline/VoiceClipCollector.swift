import Foundation
import VCAudio
import VCModels

/// Keeps a short rolling buffer of each channel's audio and copies out the samples of every speaker turn,
/// so a voice heard during the meeting can be enrolled without re-reading the recording.
/// Fed in lock-step with the speaker identifier, so the buffer always still holds the audio of the turns
/// the identifier just returned.
actor VoiceClipCollector {
    /// Seconds of audio kept per speaker (more adds little to an enrollment).
    static let clipSeconds: Double = 40
    /// Rolling history per channel; must exceed the diarization window plus its latency.
    static let historySeconds: Double = 45

    private struct History {
        var sampleRate: Double
        var startTime: TimeInterval
        var samples: [Float] = []
    }

    private struct Clip {
        var sampleRate: Double
        var samples: [Float] = []
    }

    private var history: [AudioChannel: History] = [:]
    private var clips: [String: Clip] = [:]
    /// When the computer's audio carried speech (sorted, merged): the microphone may hear it through the
    /// speakers, so those stretches never go into a microphone speaker's clip.
    private var systemSpeech: [TimeRange] = []

    func append(_ chunk: AudioChunk) {
        guard chunk.sampleRate > 0, !chunk.samples.isEmpty else { return }
        // Take the value out of the dictionary so appending doesn't trigger a copy-on-write of the buffer.
        var h = history.removeValue(forKey: chunk.channel)
            ?? History(sampleRate: chunk.sampleRate, startTime: chunk.startTime)
        let expectedStart = h.startTime + Double(h.samples.count) / h.sampleRate
        if h.sampleRate != chunk.sampleRate || h.samples.isEmpty || abs(chunk.startTime - expectedStart) > 0.25 {
            h = History(sampleRate: chunk.sampleRate, startTime: chunk.startTime)
        }
        h.samples.append(contentsOf: chunk.samples)
        let maxCount = Int(Self.historySeconds * h.sampleRate)
        // Trim in batches so the buffer isn't shifted on every chunk.
        if h.samples.count > maxCount + maxCount / 2 {
            let drop = h.samples.count - maxCount
            h.samples.removeFirst(drop)
            h.startTime += Double(drop) / h.sampleRate
        }
        history[chunk.channel] = h
    }

    /// Computer audio carried speech during `ranges`.
    func excludeSystemSpeech(_ ranges: [TimeRange]) {
        var merged: [TimeRange] = []
        for range in (systemSpeech + ranges).sorted(by: { $0.start < $1.start }) where range.duration > 0 {
            if let last = merged.last, range.start <= last.end {
                merged[merged.count - 1].end = max(last.end, range.end)
            } else {
                merged.append(range)
            }
        }
        let horizon = (merged.last?.end ?? 0) - Self.historySeconds * 2
        systemSpeech = merged.filter { $0.end >= horizon }
    }

    func collect(_ turns: [SpeakerTurn]) {
        for turn in turns {
            guard let h = history[turn.channel] else { continue }
            var clip = clips[turn.speakerKey] ?? Clip(sampleRate: h.sampleRate)
            guard clip.sampleRate == h.sampleRate else { continue }
            let pieces = turn.channel == .microphone ? Self.subtract(systemSpeech, from: turn.range) : [turn.range]
            for piece in pieces {
                let from = Int(((piece.start - h.startTime) * h.sampleRate).rounded())
                let to = Int(((piece.end - h.startTime) * h.sampleRate).rounded())
                let lo = max(0, from), hi = min(h.samples.count, to)
                let room = Int(Self.clipSeconds * h.sampleRate) - clip.samples.count
                guard hi > lo, room > 0 else { continue }
                clip.samples.append(contentsOf: h.samples[lo..<min(hi, lo + room)])
            }
            if !clip.samples.isEmpty { clips[turn.speakerKey] = clip }
        }
    }

    /// The parts of `range` outside `excluded` (sorted, non-overlapping).
    static func subtract(_ excluded: [TimeRange], from range: TimeRange) -> [TimeRange] {
        var pieces: [TimeRange] = []
        var start = range.start
        for e in excluded where e.end > start && e.start < range.end {
            if e.start > start { pieces.append(TimeRange(start: start, end: e.start)) }
            start = max(start, e.end)
        }
        if range.end > start { pieces.append(TimeRange(start: start, end: range.end)) }
        return pieces
    }

    /// The speaker's collected audio resampled to 16 kHz.
    func clip16k(for key: String) -> [Float] {
        guard let clip = clips[key] else { return [] }
        return clip.sampleRate == 16_000
            ? clip.samples : AudioResampler.resample(clip.samples, from: clip.sampleRate, to: 16_000)
    }

    func seconds(for key: String) -> Double {
        guard let clip = clips[key], clip.sampleRate > 0 else { return 0 }
        return Double(clip.samples.count) / clip.sampleRate
    }

    func rekey(_ oldKey: String, to newKey: String) {
        guard let clip = clips.removeValue(forKey: oldKey) else { return }
        if clips[newKey] == nil { clips[newKey] = clip }
    }
}
