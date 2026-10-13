import Foundation
import VCModels

/// Applies a person's preferences to recognized text.
public enum TranscriptCustomizer {
    /// Applies, in order: replacements (case-insensitive, word boundaries, longest first), vocabulary correction (conservative fuzzy match of 1–3 token spans to vocabulary terms; never changes common dictionary words), spelling variant.
    ///
    /// Vocabulary is `settings.vocabulary` + `extraVocabulary` + (when `settings.useRegionalVocabulary`) the
    /// vocabulary of the accent and residence regions.
    public static func apply(_ text: String, settings: VoiceSettings, extraVocabulary: [String] = []) -> String {
        var result = applyReplacements(text, settings.replacements)
        let vocabulary = settings.vocabulary + extraVocabulary + AccentRegions.vocabulary(for: settings)
        result = correctVocabulary(result, vocabulary: vocabulary)
        return applySpelling(result, settings.spelling)
    }

    /// Converts British ↔ American spellings of common words, keeping case ("Colour" → "Color").
    /// Capitalised words other than the first word of a sentence are proper nouns and stay as they are
    /// ("Labour Party", "Pearl Harbor").
    public static func applySpelling(_ text: String, _ variant: SpellingVariant) -> String {
        let table: [String: String]
        switch variant {
        case .unchanged: return text
        case .british: table = SpellingTable.toBritish
        case .american: table = SpellingTable.toAmerican
        }
        var output = ""
        output.reserveCapacity(text.count)
        var sentenceStart = true
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character.isLetter else {
                output.append(character)
                if ".!?\n".contains(character) { sentenceStart = true }
                index = text.index(after: index)
                continue
            }
            var end = index
            while end < text.endIndex, text[end].isLetter { end = text.index(after: end) }
            let word = String(text[index..<end])
            output += convert(word, table: table, atSentenceStart: sentenceStart)
            sentenceStart = false
            index = end
        }
        return output
    }

    // MARK: - Replacements

    static func applyReplacements(_ text: String, _ replacements: [TextReplacement]) -> String {
        let usable = replacements
            .map { (heard: $0.heard.trimmingCharacters(in: .whitespacesAndNewlines), meant: $0.meant) }
            .filter { !$0.heard.isEmpty }
            .sorted { $0.heard.count > $1.heard.count }
        guard !usable.isEmpty else { return text }
        var meant: [String: String] = [:]
        var alternatives: [String] = []
        for replacement in usable {
            let key = phraseKey(replacement.heard)
            guard meant[key] == nil else { continue }
            meant[key] = replacement.meant
            let words = replacement.heard.split(whereSeparator: \.isWhitespace).map {
                NSRegularExpression.escapedPattern(for: String($0))
            }
            alternatives.append(words.joined(separator: "\\s+"))
        }
        // Longest first inside one alternation, so a longer phrase wins over its prefix and replaced text is never re-matched.
        let pattern = "(?<![\\p{L}\\p{N}])(?:" + alternatives.joined(separator: "|") + ")(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        var output = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let found = ns.substring(with: match.range)
            output += meant[phraseKey(found)] ?? found
            cursor = match.range.location + match.range.length
        }
        output += ns.substring(from: cursor)
        return output
    }

    private static func phraseKey(_ phrase: String) -> String {
        phrase.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Vocabulary

    /// Rewrites spans of 1–3 tokens that are a near-miss of a vocabulary term ("Chima manda" → "Chimamanda",
    /// "Ngozy" → "Ngozi") or differ only in case. Spans containing a common dictionary word are never touched.
    static func correctVocabulary(_ text: String, vocabulary: [String]) -> String {
        let terms = VocabularyTerm.make(vocabulary)
        guard !terms.isEmpty else { return text }
        let tokens = TextTokens.split(text).map(Token.init)
        guard !tokens.isEmpty else { return text }
        var changed = false
        var output: [String] = []
        var index = 0
        while index < tokens.count {
            var replaced = false
            for length in stride(from: min(3, tokens.count - index), through: 1, by: -1) {
                let span = Array(tokens[index..<(index + length)])
                guard let term = bestTerm(for: span, terms: terms) else { continue }
                output.append(span[0].leading + term.text + span[length - 1].trailing)
                index += length
                replaced = true
                changed = true
                break
            }
            if !replaced {
                output.append(tokens[index].original)
                index += 1
            }
        }
        return changed ? output.joined(separator: " ") : text
    }

    private static func bestTerm(for span: [Token], terms: [VocabularyTerm]) -> VocabularyTerm? {
        // Interior punctuation means the span crosses a phrase boundary.
        for (i, token) in span.enumerated() {
            if token.core.isEmpty { return nil }
            if i < span.count - 1, !token.trailing.isEmpty { return nil }
            if i > 0, !token.leading.isEmpty { return nil }
        }
        let spanText = span.map(\.core).joined(separator: " ")
        let key = span.map(\.key).joined()
        guard key.count >= 2 else { return nil }
        if span.contains(where: { CommonWords.contains($0.key) }) {
            return nil
        }
        var best: (term: VocabularyTerm, distance: Int)?
        for term in terms where abs(term.key.count - key.count) <= 3 && term.wordCount <= span.count + 1 {
            if term.key == key {
                // Already right apart from case or spacing.
                if term.text == spanText { return nil }
                return term
            }
            guard term.key.count >= 4, key.count >= 4, sameFirstSound(term.key, key) else { continue }
            let distance = SequenceAlignment.distance(Array(term.key), Array(key))
            guard distance <= allowedEdits(term.key.count) else { continue }
            if best == nil || distance < best!.distance { best = (term, distance) }
        }
        return best?.term
    }

    /// 4–5 letters: 1 edit; 6–9: 2; longer: 3.
    static func allowedEdits(_ length: Int) -> Int {
        switch length {
        case ..<4: 0
        case 4...5: 1
        case 6...9: 2
        default: 3
        }
    }

    /// First letters equal, or interchangeable in spelling of the same sound (c/k/q, g/j, i/y, s/z).
    private static func sameFirstSound(_ a: String, _ b: String) -> Bool {
        guard let x = a.first, let y = b.first else { return false }
        if x == y { return true }
        let groups: [Set<Character>] = [["c", "k", "q"], ["g", "j"], ["i", "y"], ["s", "z"]]
        return groups.contains { $0.contains(x) && $0.contains(y) }
    }

    private struct Token {
        let original: String
        let leading: String
        let core: String
        let trailing: String
        let key: String

        init(_ original: String) {
            self.original = original
            var start = original.startIndex
            var end = original.endIndex
            while start < end, !original[start].isLetter, !original[start].isNumber { start = original.index(after: start) }
            while end > start {
                let before = original.index(before: end)
                if original[before].isLetter || original[before].isNumber { break }
                end = before
            }
            var core = String(original[start..<end])
            var trailing = String(original[end...])
            // Possessive stays outside the match: "Ngozy's" → "Ngozi's".
            for suffix in ["'s", "’s"] where core.lowercased().hasSuffix(suffix) && core.count > suffix.count {
                core = String(core.dropLast(suffix.count))
                trailing = String(original[original.index(start, offsetBy: core.count)...])
            }
            self.leading = String(original[..<start])
            self.core = core
            self.trailing = trailing
            self.key = TextTokens.key(core)
        }
    }

    private struct VocabularyTerm {
        let text: String
        let key: String
        let wordCount: Int

        static func make(_ vocabulary: [String]) -> [VocabularyTerm] {
            var seen = Set<String>()
            var terms: [VocabularyTerm] = []
            for raw in vocabulary {
                let text = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                let key = TextTokens.key(text)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                terms.append(VocabularyTerm(text: text, key: key, wordCount: text.split(separator: " ").count))
            }
            return terms
        }
    }

    // MARK: - Spelling

    private static func convert(_ word: String, table: [String: String], atSentenceStart: Bool) -> String {
        let lower = word.lowercased()
        guard let target = table[lower] else { return word }
        if word == lower { return target }
        let isCapitalized = word.first?.isUppercase == true && word.dropFirst() == lower.dropFirst()
        if isCapitalized {
            // A capitalised word mid-sentence is a name.
            guard atSentenceStart else { return word }
            return target.prefix(1).uppercased() + target.dropFirst()
        }
        return word
    }
}
