import Foundation
import VCModels

/// Attributes recognizer results to speakers by overlapping them with diarization turns.
public enum TranscriptAligner {
    /// A result (or word) that overlaps no turn goes to the nearest turn when the gap is at most this long.
    public static let nearestTurnTolerance: TimeInterval = 1.5

    /// Splits `update` into speaker-attributed pieces.
    ///
    /// With word timings, each word goes to the turn it overlaps most (zero-length words: the turn containing
    /// the word's midpoint), and consecutive words of one speaker form a piece. Without words, the whole
    /// update goes to the turn it overlaps most. Words/updates overlapping nothing fall back to the nearest
    /// turn within `nearestTurnTolerance`, else to `"<channel.keyPrefix>:unknown"`.
    /// Only turns on the update's channel are considered.
    public static func align(
        update: TranscriptUpdate, turns: [SpeakerTurn]
    ) -> [(speakerKey: String, text: String, range: TimeRange, confidence: Double?)] {
        let channelTurns = turns.filter { $0.channel == update.channel }
        let unknownKey = unknownSpeakerKey(for: update.channel)

        let words = update.words.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !words.isEmpty else {
            let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            let key = speakerKey(for: update.range, in: channelTurns) ?? unknownKey
            return [(key, text, update.range, update.confidence)]
        }

        var groups: [(key: String, words: [TimedWord])] = []
        for word in words {
            let key = speakerKey(for: word.range, in: channelTurns) ?? unknownKey
            if let last = groups.indices.last, groups[last].key == key {
                groups[last].words.append(word)
            } else {
                groups.append((key, [word]))
            }
        }

        // One speaker for everything: keep the recognizer's own formatting of the full text.
        if groups.count == 1 {
            let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return [(groups[0].key, text.isEmpty ? join(words) : text, update.range, update.confidence)]
        }

        return groups.map { group in
            let range = TimeRange(start: group.words.first!.range.start, end: group.words.last!.range.end)
            let confidences = group.words.compactMap(\.confidence)
            let confidence = confidences.isEmpty
                ? update.confidence : confidences.reduce(0, +) / Double(confidences.count)
            return (group.key, join(group.words), range, confidence)
        }
    }

    /// Key used when no turn can be attributed.
    public static func unknownSpeakerKey(for channel: AudioChannel) -> String { "\(channel.keyPrefix):unknown" }

    /// Turn with maximum overlap; zero-overlap ranges use midpoint containment, then the nearest turn.
    static func speakerKey(for range: TimeRange, in turns: [SpeakerTurn]) -> String? {
        var best: SpeakerTurn?
        var bestOverlap = 0.0
        for turn in turns {
            let overlap = turn.range.overlap(with: range)
            if overlap > bestOverlap {
                bestOverlap = overlap
                best = turn
            }
        }
        if let best { return best.speakerKey }

        let mid = (range.start + range.end) / 2
        if let containing = turns.first(where: { $0.range.contains(mid) }) { return containing.speakerKey }

        var nearest: SpeakerTurn?
        var nearestGap = Double.infinity
        for turn in turns {
            let gap = max(turn.range.start - range.end, range.start - turn.range.end, 0)
            if gap < nearestGap {
                nearestGap = gap
                nearest = turn
            }
        }
        guard let nearest, nearestGap <= nearestTurnTolerance else { return nil }
        return nearest.speakerKey
    }

    /// Joins recognizer words with single spaces, attaching punctuation to the preceding word.
    static func join(_ words: [TimedWord]) -> String {
        var out = ""
        for word in words {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if out.isEmpty || text.first.map(attachesLeft) == true {
                out += text
            } else {
                out += " " + text
            }
        }
        return out
    }

    private static func attachesLeft(_ c: Character) -> Bool { ",.;:!?)]}’”%".contains(c) }
}
