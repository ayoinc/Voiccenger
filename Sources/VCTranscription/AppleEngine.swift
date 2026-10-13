import Foundation
import Speech
import VCModels

/// Apple SpeechTranscriber run offline over a whole utterance (no volatile results), with word timings and
/// contextual-string biasing. Installs the language's recognition assets on first use.
struct AppleOfflineTranscriber: AccurateTranscriber {
    let kind = SpeechEngineKind.apple

    func transcribe(samples16k: [Float], languageCode: String, prompt: [String]) async throws -> EngineTranscript {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.speechTranscriberUnavailable }
        let localeID = Self.localeID(for: languageCode)
        try await SpeechAssets.ensureInstalled(localeIDs: [localeID])
        let locale = try await SpeechAssets.resolveInstalledLocale(localeID)
        let code = baseLanguageCode(languageCode)
        guard !samples16k.isEmpty else { return EngineTranscript(text: "", words: [], engine: .apple, languageCode: code) }
        let updates = try await OfflineRecognizer.transcribe(
            samples: samples16k, sampleRate: PCM.recognitionRate, locale: locale, channel: .microphone,
            contextualStrings: prompt)
        return EngineTranscript(
            text: updates.map(\.text).joined(separator: " "), words: updates.flatMap(\.words), engine: .apple,
            languageCode: code)
    }

    /// A full locale identifier is used as is; a bare language takes this Mac's region when the Mac's
    /// language matches ("en" on an en-GB Mac → "en-GB"), else the language alone (Speech picks its default).
    static func localeID(for languageCode: String, current: Locale = .current) -> String {
        guard !languageCode.contains("-"), !languageCode.contains("_") else { return languageCode }
        let code = languageCode.lowercased()
        if current.language.languageCode?.identifier == code, let region = current.region?.identifier {
            return "\(code)-\(region)"
        }
        return code
    }
}
