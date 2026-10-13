import CoreMedia
import Foundation
import Speech
import VCModels

/// Converts SpeechTranscriber results into model types.
enum ResultMapper {
    /// Word timing and confidence come from the `audioTimeRange` / `transcriptionConfidence` attributes
    /// on the result's AttributedString runs. A run without a time range (e.g. detached punctuation)
    /// is attached to the preceding word. Returns nil for results with no text.
    static func update(
        from result: SpeechTranscriber.Result, channel: AudioChannel, localeID: String
    ) -> TranscriptUpdate? {
        let attributed = result.text
        let text = String(attributed.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var words: [TimedWord] = []
        for run in attributed.runs {
            let piece = String(attributed[run.range].characters)
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let cmRange = run.audioTimeRange, let range = timeRange(cmRange) {
                words.append(TimedWord(text: trimmed, range: range, confidence: run.transcriptionConfidence))
            } else if !words.isEmpty {
                let separator = piece.first?.isWhitespace == true ? " " : ""
                words[words.count - 1].text += separator + trimmed
            } else {
                // Leading untimed text: keep it as a word spanning the result's start.
                let start = seconds(result.range.start) ?? 0
                words.append(
                    TimedWord(
                        text: trimmed, range: TimeRange(start: start, end: start),
                        confidence: run.transcriptionConfidence))
            }
        }

        let confidences = words.compactMap(\.confidence)
        let confidence = confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
        let range =
            timeRange(result.range)
            ?? TimeRange(start: words.first?.range.start ?? 0, end: words.last?.range.end ?? 0)
        return TranscriptUpdate(
            channel: channel, text: text, range: range, confidence: confidence, localeID: localeID,
            words: words)
    }

    static func seconds(_ time: CMTime) -> TimeInterval? {
        guard time.isValid, time.isNumeric else { return nil }
        let s = time.seconds
        return s.isFinite ? s : nil
    }

    static func timeRange(_ range: CMTimeRange) -> TimeRange? {
        guard range.isValid, let start = seconds(range.start), let end = seconds(range.end) else { return nil }
        return TimeRange(start: start, end: end)
    }
}
