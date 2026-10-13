import Foundation

/// Word error rate: (substitutions + deletions + insertions) / reference words, over normalized words.
public enum WordErrorRate {
    /// 0 for a perfect transcript; can exceed 1 when the hypothesis adds many words.
    /// An empty reference scores 0 against an empty hypothesis and 1 otherwise.
    public static func compute(reference: String, hypothesis: String) -> Double {
        let ref = normalize(reference)
        let hyp = normalize(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
        return Double(SequenceAlignment.distance(ref, hyp)) / Double(ref.count)
    }

    /// Words for scoring: lower-cased, diacritics folded, apostrophes dropped ("we'll" → "well"),
    /// other punctuation and hyphens split words, "&" read as "and", and whole numbers spelled out
    /// ("6" → "six", "21" → "twenty one") so engines that write digits aren't penalised.
    public static func normalize(_ s: String) -> [String] {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
        let scalars = Array(folded.unicodeScalars)
        var cleaned = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            if apostrophes.contains(scalar) { continue }
            if CharacterSet.alphanumerics.contains(scalar) {
                cleaned.append(scalar)
            } else if scalar == ",", index > 0, index + 1 < scalars.count,
                CharacterSet.decimalDigits.contains(scalars[index - 1]),
                CharacterSet.decimalDigits.contains(scalars[index + 1])
            {
                // Thousands separator: "1,000" → "1000".
                continue
            } else {
                cleaned.append(" ")
            }
        }
        var words: [String] = []
        for raw in String(cleaned).split(separator: " ") {
            let word = String(raw)
            if word.count <= 9, word.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(word) {
                words += spellOut(value)
            } else {
                words.append(word)
            }
        }
        return words
    }

    private static let apostrophes: Set<Unicode.Scalar> = ["'", "\u{2019}", "\u{2018}", "\u{02BC}", "`"]

    private static let ones = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
    ]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    /// English words for 0...999_999_999 ("105" → one hundred five).
    static func spellOut(_ value: Int) -> [String] {
        guard value > 0 else { return ["zero"] }
        var words: [String] = []
        var rest = value
        for (scale, name) in [(1_000_000, "million"), (1_000, "thousand")] where rest >= scale {
            words += belowThousand(rest / scale) + [name]
            rest %= scale
        }
        if rest > 0 { words += belowThousand(rest) }
        return words
    }

    private static func belowThousand(_ value: Int) -> [String] {
        var words: [String] = []
        var rest = value
        if rest >= 100 {
            words += [ones[rest / 100], "hundred"]
            rest %= 100
        }
        if rest >= 20 {
            words.append(tens[rest / 10])
            rest %= 10
            if rest > 0 { words.append(ones[rest]) }
        } else if rest > 0 {
            words.append(ones[rest])
        }
        return words
    }
}
