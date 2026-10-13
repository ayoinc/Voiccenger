import Foundation

/// One step of a minimum-cost alignment between two sequences: a pair (`a` and `b` set), an insertion
/// (only `b`) or a deletion (only `a`).
struct AlignmentStep: Equatable {
    var a: Int?
    var b: Int?
    /// Cost of this step: the pair cost for pairs, 1 for gaps.
    var cost: Double
}

enum SequenceAlignment {
    /// Levenshtein-style alignment of `a` to `b`. Gaps cost 1; pairing costs `pairCost` (0 = identical,
    /// 1 = unrelated; values above 1 make a pairing never cheaper than two gaps). Ties prefer pairs,
    /// then deletions, so equal-length sequences line up position by position.
    static func align<A, B>(_ a: [A], _ b: [B], pairCost: (A, B) -> Double) -> [AlignmentStep] {
        let n = a.count
        let m = b.count
        if n == 0 { return (0..<m).map { AlignmentStep(a: nil, b: $0, cost: 1) } }
        if m == 0 { return (0..<n).map { AlignmentStep(a: $0, b: nil, cost: 1) } }
        // 0 = pair, 1 = deletion (a only), 2 = insertion (b only)
        var moves = [UInt8](repeating: 0, count: (n + 1) * (m + 1))
        var previous = (0...m).map(Double.init)
        var current = [Double](repeating: 0, count: m + 1)
        for j in 1...m { moves[j] = 2 }
        for i in 1...n {
            current[0] = Double(i)
            moves[i * (m + 1)] = 1
            for j in 1...m {
                let pair = previous[j - 1] + pairCost(a[i - 1], b[j - 1])
                let deletion = previous[j] + 1
                let insertion = current[j - 1] + 1
                if pair <= deletion && pair <= insertion {
                    current[j] = pair
                    moves[i * (m + 1) + j] = 0
                } else if deletion <= insertion {
                    current[j] = deletion
                    moves[i * (m + 1) + j] = 1
                } else {
                    current[j] = insertion
                    moves[i * (m + 1) + j] = 2
                }
            }
            swap(&previous, &current)
        }
        var steps: [AlignmentStep] = []
        steps.reserveCapacity(n + m)
        var i = n
        var j = m
        while i > 0 || j > 0 {
            switch moves[i * (m + 1) + j] {
            case 0:
                steps.append(AlignmentStep(a: i - 1, b: j - 1, cost: pairCost(a[i - 1], b[j - 1])))
                i -= 1
                j -= 1
            case 1:
                steps.append(AlignmentStep(a: i - 1, b: nil, cost: 1))
                i -= 1
            default:
                steps.append(AlignmentStep(a: nil, b: j - 1, cost: 1))
                j -= 1
            }
        }
        return steps.reversed()
    }

    /// Levenshtein distance between two sequences (two-row, O(min) memory).
    static func distance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1), previous[j] + 1, current[j - 1] + 1)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// 0 for identical strings, 1 for completely different ones (edit distance over the longer length).
    static func normalizedDistance(_ a: String, _ b: String) -> Double {
        let x = Array(a)
        let y = Array(b)
        let longest = max(x.count, y.count)
        guard longest > 0 else { return 0 }
        return Double(distance(x, y)) / Double(longest)
    }
}

/// Splitting display text into tokens that keep their punctuation, and the letters-only key used to compare them.
enum TextTokens {
    /// Whitespace-separated tokens of `text`, punctuation attached.
    static func split(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Lower-cased letters and digits only, diacritics folded: "Stella," → "stella", "Adé's" → "ades".
    static func key(_ token: String) -> String {
        let folded = token.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
    }
}
