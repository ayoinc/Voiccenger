import Foundation
import Speech
import VCModels

/// Ranks locales by mean transcription confidence on the same audio (accent within a language, or language).
///
/// Every candidate transcribes the identical samples with an on-device SpeechTranscriber; the locale whose
/// acoustic + language model fits the speech best reports the highest per-word confidence. Language
/// mismatches separate clearly (≈0.4 vs ≈0.98 on the French fixture); regional accents of one language
/// differ by only ~0.01, so callers should demand a margin before acting on an accent ranking.
public struct AccentDetector: Sendable {
    public init() {}

    /// - Returns: one score per usable candidate, best first (ties: more words first, then identifier).
    ///   Candidates that are unsupported or not installed are skipped.
    /// - Throws: `TranscriptionError.noUsableCandidates` when no candidate can be evaluated.
    public func rank(samples: [Float], sampleRate: Double, candidateLocaleIDs: [String]) async throws
        -> [LocaleScore]
    {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.speechTranscriberUnavailable }
        var scores: [LocaleScore] = []
        var evaluated = Set<String>()
        for id in candidateLocaleIDs {
            try Task.checkCancellation()
            let locale: Locale
            do {
                locale = try await SpeechAssets.resolveInstalledLocale(id)
            } catch {
                transcriptionLog.info("Accent ranking skips \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            let localeID = locale.identifier(.bcp47)
            guard evaluated.insert(localeID).inserted else { continue }
            let updates = try await OfflineRecognizer.transcribe(
                samples: samples, sampleRate: sampleRate, locale: locale, channel: .microphone)
            scores.append(Self.score(localeID: localeID, updates: updates))
        }
        guard !evaluated.isEmpty else { throw TranscriptionError.noUsableCandidates(candidateLocaleIDs) }
        return Self.sorted(scores)
    }

    /// Word-weighted mean confidence over all final results; a locale that recognised nothing scores 0.
    static func score(localeID: String, updates: [TranscriptUpdate]) -> LocaleScore {
        let confidences = updates.flatMap { $0.words.compactMap(\.confidence) }
        let mean = confidences.isEmpty ? 0 : confidences.reduce(0, +) / Double(confidences.count)
        let transcript = updates.map(\.text).joined(separator: " ")
        let wordCount = updates.reduce(0) { $0 + $1.words.count }
        return LocaleScore(localeID: localeID, meanConfidence: mean, wordCount: wordCount, transcript: transcript)
    }

    static func sorted(_ scores: [LocaleScore]) -> [LocaleScore] {
        scores.sorted {
            if $0.meanConfidence != $1.meanConfidence { return $0.meanConfidence > $1.meanConfidence }
            if $0.wordCount != $1.wordCount { return $0.wordCount > $1.wordCount }
            return $0.localeID < $1.localeID
        }
    }
}
