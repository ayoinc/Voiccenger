import Foundation
import VCModels

/// Recognises microphone lines that are the computer's audio heard again through the Mac's speakers.
///
/// Without headphones the microphone also hears the remote party, so their words arrive twice: once on the
/// system channel and, slightly later and noisier, on the microphone. A microphone line is bleed when system
/// lines cover more than `minimumOverlap` of its time and their words contain at least `minimumSimilarity` of
/// its normalised words in order (longest common subsequence ÷ the mic line's word count). Someone in the room
/// talking over the remote party says different words, so their line stays.
///
/// Thresholds come from the two recorded Teams meetings on the development Mac (334 mic lines): of the 144 mic
/// lines that system lines overlapped by more than half, the word share was ≥ 0.85 for 75 % and ≥ 0.6 for 118;
/// pairing every mic line with the system lines 2–5 minutes away instead (320 pairs of genuinely different
/// speech) gave a median of 0.13, and only 3 pairs reached 0.6 (two of them one-word lines).
public enum BleedSuppression {
    public static let minimumOverlap = 0.5
    public static let minimumSimilarity = 0.6

    /// Lower-cased words with punctuation removed ("Don't!" → "don't").
    public static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map(String.init)
    }

    /// Share of `mic`'s words found, in order, in `system` (0 when `mic` is empty).
    public static func similarity(mic: [String], system: [String]) -> Double {
        guard !mic.isEmpty, !system.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: system.count + 1)
        var current = previous
        for word in mic {
            for (j, other) in system.enumerated() {
                current[j + 1] = word == other ? previous[j] + 1 : max(previous[j + 1], current[j])
            }
            swap(&previous, &current)
        }
        return Double(previous[system.count]) / Double(mic.count)
    }

    /// Whether the microphone line `mic` repeats speech from `system` (lines from the system channel, any order).
    public static func isBleed(_ mic: TranscriptSegment, system: [TranscriptSegment]) -> Bool {
        guard mic.channel == .microphone, mic.range.duration > 0 else { return false }
        let overlapping = system
            .filter { $0.channel == .system && $0.range.overlap(with: mic.range) > 0 }
            .sorted { $0.range.start < $1.range.start }
        let covered = overlapping.reduce(0) { $0 + $1.range.overlap(with: mic.range) }
        guard covered / mic.range.duration > minimumOverlap else { return false }
        let systemWords = overlapping.flatMap { words($0.text) }
        return similarity(mic: words(mic.text), system: systemWords) >= minimumSimilarity
    }
}
