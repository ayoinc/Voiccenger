import Foundation
import VCModels

/// Text a person reads aloud so Voiccenger can measure which engine understands them best.
public enum CalibrationPassages {
    /// The elicitation paragraph of the Speech Accent Archive (Weinberger, S. H., George Mason University,
    /// https://accent.gmu.edu), read by thousands of speakers worldwide. It covers most English consonant and
    /// vowel contrasts, and it is the passage behind the engine benchmark that chose Voiccenger's defaults.
    public static let standard = """
        Please call Stella. Ask her to bring these things with her from the store: Six spoons of fresh snow peas, \
        five thick slabs of blue cheese, and maybe a snack for her brother Bob. We also need a small plastic snake \
        and a big toy frog for the kids. She can scoop these things into three red bags, and we will go meet her \
        Wednesday at the train station.
        """

    /// One sentence with the person's name and places from their region, so calibration also measures how
    /// well each engine handles the names they actually say.
    public static func personal(name: String, region: AccentRegion?) -> String {
        let trimmed = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let introduction = trimmed.isEmpty ? "I am reading this" : "My name is \(trimmed), and I am reading this"
        let places = region?.places.prefix(2).map { $0 } ?? []
        switch places.count {
        case 2:
            return "\(introduction) so Voiccenger learns my voice; I know \(places[0]) and \(places[1]) well."
        case 1:
            return "\(introduction) so Voiccenger learns my voice; I know \(places[0]) well."
        default:
            return "\(introduction) so Voiccenger learns my voice."
        }
    }
}

/// Picks the engine that transcribes a person best, from one recording of known text.
public enum VoiceCalibrator {
    /// Transcribes the same recording with every given engine (must be ready/downloaded), scores against `expected`; best first.
    /// Engines that are not downloaded or fail are left out.
    public static func calibrate(
        samples16k: [Float], expected: String, engines: [SpeechEngineKind], languageCode: String,
        library: SpeechModelLibrary = .shared
    ) async -> VoiceCalibration {
        var transcribers: [any AccurateTranscriber] = []
        for engine in unique(engines) {
            do {
                transcribers.append(try await library.transcriber(engine))
            } catch {
                transcriptionLog.info("Calibration skips \(engine.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return await calibrate(
            samples16k: samples16k, expected: expected, transcribers: transcribers, languageCode: languageCode)
    }

    /// Same scoring with explicit transcribers, run one after another. Transcribers that throw are left out.
    /// Ties keep the given order.
    public static func calibrate(
        samples16k: [Float], expected: String, transcribers: [any AccurateTranscriber], languageCode: String
    ) async -> VoiceCalibration {
        var scores: [EngineScore] = []
        for transcriber in transcribers where !scores.contains(where: { $0.engine == transcriber.kind }) {
            do {
                let result = try await transcriber.transcribe(samples16k: samples16k, languageCode: languageCode, prompt: [])
                scores.append(
                    EngineScore(
                        engine: transcriber.kind,
                        wordErrorRate: WordErrorRate.compute(reference: expected, hypothesis: result.text),
                        transcript: result.text))
            } catch {
                transcriptionLog.error("Calibration with \(transcriber.kind.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let ranked = scores.enumerated().sorted { lhs, rhs in
            lhs.element.wordErrorRate != rhs.element.wordErrorRate
                ? lhs.element.wordErrorRate < rhs.element.wordErrorRate : lhs.offset < rhs.offset
        }.map(\.element)
        return VoiceCalibration(scores: ranked)
    }

    /// Proposed corrections from substitutions in the best transcript vs expected (multi-word spans, proper nouns/vocabulary only; no common words).
    ///
    /// Each differing stretch of the alignment where the expected side is a name or vocabulary term
    /// becomes "heard → meant", e.g. expected "Ngozi", heard "and gozi" → `and gozi → Ngozi`. Stretches
    /// where the expected words are ordinary words ("slabs" heard as "slaps") are ignored, as are pure
    /// insertions and deletions.
    public static func suggestedReplacements(expected: String, heard: String, vocabulary: [String]) -> [TextReplacement] {
        let expectedTokens = TextTokens.split(expected).map(SuggestionToken.init).filter { !$0.key.isEmpty }
        let heardTokens = TextTokens.split(heard).map(SuggestionToken.init).filter { !$0.key.isEmpty }
        guard !expectedTokens.isEmpty, !heardTokens.isEmpty else { return [] }
        let vocabularyKeys = Set(vocabulary.flatMap { TextTokens.split($0).map(TextTokens.key) }.filter { !$0.isEmpty })
        let properNouns = properNounIndices(expectedTokens, vocabularyKeys: vocabularyKeys)

        let steps = SequenceAlignment.align(expectedTokens, heardTokens) { a, b in
            a.key == b.key ? 0 : 1
        }
        var suggestions: [TextReplacement] = []
        var seen = Set<String>()
        var blockExpected: [Int] = []
        var blockHeard: [Int] = []

        func flush() {
            defer {
                blockExpected.removeAll()
                blockHeard.removeAll()
            }
            guard !blockExpected.isEmpty, !blockHeard.isEmpty, blockExpected.count <= 3, blockHeard.count <= 4 else { return }
            guard blockExpected.allSatisfy(properNouns.contains) else { return }
            let meant = blockExpected.map { expectedTokens[$0].core }.joined(separator: " ")
            let heardText = blockHeard.map { heardTokens[$0].core }.joined(separator: " ")
            let heardKey = blockHeard.map { heardTokens[$0].key }.joined(separator: " ")
            guard heardKey != blockExpected.map({ expectedTokens[$0].key }).joined(separator: " "),
                seen.insert(heardKey).inserted
            else { return }
            suggestions.append(TextReplacement(heard: heardText, meant: meant))
        }

        for step in steps {
            if step.a != nil, step.b != nil, step.cost == 0 {
                flush()
                continue
            }
            if let a = step.a { blockExpected.append(a) }
            if let b = step.b { blockHeard.append(b) }
        }
        flush()
        return suggestions
    }

    /// Expected tokens that are names or terms: in `vocabularyKeys`, or capitalised and not a common word
    /// (a capitalised common word counts only mid-sentence, e.g. "Bob" in "her brother Bob").
    private static func properNounIndices(_ tokens: [SuggestionToken], vocabularyKeys: Set<String>) -> Set<Int> {
        var indices = Set<Int>()
        var sentenceStart = true
        for (index, token) in tokens.enumerated() {
            let capitalized = token.core.first?.isUppercase == true
            if vocabularyKeys.contains(token.key)
                || (capitalized && (!CommonWords.contains(token.key) || !sentenceStart) && token.core != "I")
            {
                indices.insert(index)
            }
            sentenceStart = token.endsSentence
        }
        return indices
    }

    private struct SuggestionToken {
        let core: String
        let key: String
        let endsSentence: Bool

        init(_ raw: String) {
            core = raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            key = TextTokens.key(raw)
            endsSentence = raw.last.map { ".!?:".contains($0) } ?? false
        }
    }

    private static func unique(_ engines: [SpeechEngineKind]) -> [SpeechEngineKind] {
        var seen = Set<SpeechEngineKind>()
        return engines.filter { seen.insert($0).inserted }
    }
}
