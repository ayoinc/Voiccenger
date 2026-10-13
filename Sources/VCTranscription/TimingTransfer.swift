import Foundation
import VCModels

/// Gives word timings to text from an engine without (usable) timestamps, using another recognizer's
/// word timings for the same audio.
public enum TimingTransfer {
    /// Aligns `text` tokens to reference word timings (edit-distance alignment); unmatched tokens interpolated;
    /// no reference → proportional by length across `range`.
    ///
    /// Tokens paired with a reference word (identical or similar spelling, or a plain substitution) take its
    /// time range; runs of unpaired tokens share the time between their paired neighbours in proportion to
    /// their length. Output words keep the token text (with punctuation), are non-overlapping, ordered and
    /// inside `range`. Confidence is copied only from identical reference words.
    public static func align(text: String, reference: [TimedWord], range: TimeRange) -> [TimedWord] {
        let tokens = TextTokens.split(text)
        guard !tokens.isEmpty else { return [] }
        let references = reference.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.range.start < $1.range.start }
        guard !references.isEmpty else { return proportional(tokens, across: range) }

        // Reference words may hold several tokens' worth of text ("New York" as one run); compare by key.
        let tokenKeys = tokens.map(TextTokens.key)
        let referenceKeys = references.map { TextTokens.key($0.text) }
        let steps = SequenceAlignment.align(Array(tokenKeys.indices), Array(referenceKeys.indices)) { t, r in
            pairCost(tokenKeys[t], referenceKeys[r])
        }

        var anchors = [TimeRange?](repeating: nil, count: tokens.count)
        var confidences = [Double?](repeating: nil, count: tokens.count)
        for step in steps {
            guard let t = step.a, let r = step.b else { continue }
            anchors[t] = clamp(references[r].range, to: range)
            if tokenKeys[t] == referenceKeys[r] { confidences[t] = references[r].confidence }
        }

        // Fill unanchored runs between anchors, proportional to token length.
        var ranges = [TimeRange](repeating: TimeRange(start: range.start, end: range.start), count: tokens.count)
        var index = 0
        while index < tokens.count {
            if let anchor = anchors[index] {
                ranges[index] = anchor
                index += 1
                continue
            }
            var end = index
            while end < tokens.count, anchors[end] == nil { end += 1 }
            let lower = index > 0 ? ranges[index - 1].end : range.start
            let upper = end < tokens.count ? anchors[end]!.start : range.end
            let span = TimeRange(start: lower, end: max(lower, upper))
            let filled = proportional(Array(tokens[index..<end]), across: span)
            for (offset, word) in filled.enumerated() { ranges[index + offset] = word.range }
            index = end
        }

        // Monotonic, non-overlapping, inside the utterance.
        var words: [TimedWord] = []
        words.reserveCapacity(tokens.count)
        var cursor = range.start
        for (i, token) in tokens.enumerated() {
            let start = min(max(ranges[i].start, cursor), range.end)
            let end = min(max(ranges[i].end, start), range.end)
            words.append(TimedWord(text: token, range: TimeRange(start: start, end: end), confidence: confidences[i]))
            cursor = end
        }
        return words
    }

    /// Identical keys pair for free; similar spellings ("Stela"/"Stella") cost less than a gap so the
    /// alignment prefers them; unrelated words cost 1 (a substitution, still taking the reference time).
    static func pairCost(_ a: String, _ b: String) -> Double {
        if a == b { return 0 }
        if a.isEmpty || b.isEmpty { return 1 }
        return 0.2 + 0.8 * SequenceAlignment.normalizedDistance(a, b)
    }

    /// Splits `range` across tokens in proportion to their character count (+1 for the gap after each word).
    static func proportional(_ tokens: [String], across range: TimeRange) -> [TimedWord] {
        let weights = tokens.map { Double($0.count + 1) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return [] }
        var words: [TimedWord] = []
        var cursor = range.start
        for (index, token) in tokens.enumerated() {
            let isLast = index == tokens.count - 1
            let length = range.duration * weights[index] / total
            let end = isLast ? range.end : min(cursor + length, range.end)
            // Each word's share ends with a short gap (its "+1"), except the last, which ends with the range.
            let wordEnd = isLast ? range.end : cursor + length * Double(token.count) / weights[index]
            words.append(TimedWord(text: token, range: TimeRange(start: cursor, end: min(wordEnd, range.end))))
            cursor = end
        }
        return words
    }

    private static func clamp(_ word: TimeRange, to range: TimeRange) -> TimeRange {
        let start = min(max(word.start, range.start), range.end)
        return TimeRange(start: start, end: min(max(word.end, start), range.end))
    }
}
