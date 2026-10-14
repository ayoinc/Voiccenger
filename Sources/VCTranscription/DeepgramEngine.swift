import Foundation
import VCModels

/// Deepgram Nova-3 pre-recorded transcription: each call uploads the samples as a 16 kHz WAV to
/// `POST /v1/listen` and returns Deepgram's punctuated words with their times. Prompt terms become keyterms.
struct DeepgramTranscriber: AccurateTranscriber {
    let kind = SpeechEngineKind.deepgram
    let client: DeepgramClient

    func transcribe(samples16k: [Float], languageCode: String, prompt: [String]) async throws -> EngineTranscript {
        guard let language = Deepgram.requestLanguage(languageCode) else {
            throw TranscriptionError.unsupportedLanguage(languageCode, .deepgram)
        }
        guard !samples16k.isEmpty else {
            return EngineTranscript(text: "", words: [], engine: .deepgram, languageCode: language)
        }
        let response = try await client.listen(
            wav: Deepgram.wav(samples16k: samples16k), language: language, keyterms: Deepgram.keyterms(prompt))
        return Self.transcript(response, requestedLanguage: language)
    }

    /// Text and word times of the first alternative of the first channel. In `multi` mode the language is the
    /// first one Deepgram detected (English when it reports none).
    static func transcript(_ response: Deepgram.ListenResponse, requestedLanguage: String) -> EngineTranscript {
        let alternative = response.alternative
        let words = (alternative?.words ?? []).map {
            TimedWord(text: $0.displayText, range: TimeRange(start: $0.start, end: $0.end), confidence: $0.confidence)
        }
        let language =
            requestedLanguage == "multi"
            ? (alternative?.languages?.first).map(baseLanguageCode) ?? "en" : requestedLanguage
        return EngineTranscript(
            text: alternative?.transcript.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", words: words,
            engine: .deepgram, languageCode: language)
    }
}
