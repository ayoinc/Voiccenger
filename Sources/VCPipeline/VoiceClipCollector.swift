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

    func collect(_ turns: [SpeakerTurn]) {
        for turn in turns {
            guard let h = history[turn.channel] else { continue }
            let from = Int(((turn.range.start - h.startTime) * h.sampleRate).rounded())
            let to = Int(((turn.range.end - h.startTime) * h.sampleRate).rounded())
            let lo = max(0, from), hi = min(h.samples.count, to)
            guard hi > lo else { continue }
            var clip = clips[turn.speakerKey] ?? Clip(sampleRate: h.sampleRate)
            guard clip.sampleRate == h.sampleRate else { continue }
            let room = Int(Self.clipSeconds * h.sampleRate) - clip.samples.count
            guard room > 0 else { continue }
            clip.samples.append(contentsOf: h.samples[lo..<min(hi, lo + room)])
            clips[turn.speakerKey] = clip
        }
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
