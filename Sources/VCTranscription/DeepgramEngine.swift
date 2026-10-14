import Foundation
import VCModels

/// Deepgram pre-recorded transcription: each call uploads the samples as a 16 kHz WAV to `POST /v1/listen`
/// and returns Deepgram's punctuated words with their times. Prompt terms become keyterms.
///
/// `model` is the requested model; each call checks it against the key's models for the language and uses
/// Nova-3 instead when it can't transcribe it (or Deepgram refuses it), saying why in the transcript.
struct DeepgramTranscriber: AccurateTranscriber {
    let kind = SpeechEngineKind.deepgram
    let client: DeepgramClient
    let model: String?
    let library: SpeechModelLibrary

    func transcribe(samples16k: [Float], languageCode: String, prompt: [String]) async throws -> EngineTranscript {
        var choice = await library.deepgramModelChoice(model, languageCode: languageCode, live: false)
        guard let language = choice.language else {
            throw TranscriptionError.unsupportedLanguage(languageCode, .deepgram)
        }
        if let reason = choice.fallbackReason {
            transcriptionLog.info("Deepgram: \(reason, privacy: .public)")
        }
        guard !samples16k.isEmpty else {
            return EngineTranscript(
                text: "", words: [], engine: .deepgram, languageCode: language, model: choice.model,
                modelFallbackReason: choice.fallbackReason)
        }
        let wav = Deepgram.wav(samples16k: samples16k)
        let keyterms = Deepgram.keyterms(prompt)
        let response: Deepgram.ListenResponse
        var requested = language
        do {
            response = try await client.listen(wav: wav, model: choice.model, language: language, keyterms: keyterms)
        } catch DeepgramError.requestFailed(let status, let message)
            where (400..<500).contains(status) && !choice.usesDefaultModel
        {
            // Deepgram refused this model for the request (retired, not on the plan, language mismatch).
            guard let fallbackLanguage = Deepgram.requestLanguage(languageCode) else {
                throw DeepgramError.requestFailed(status, message)
            }
            let refused = Deepgram.modelDisplayName(choice.model)
            choice = Deepgram.ModelChoice(
                model: Deepgram.defaultModel, language: fallbackLanguage,
                fallbackReason: "Deepgram refused \(refused) (\(message)), so Nova-3 is used instead")
            requested = fallbackLanguage
            response = try await client.listen(
                wav: wav, model: Deepgram.defaultModel, language: fallbackLanguage, keyterms: keyterms)
        }
        var transcript = Self.transcript(response, requestedLanguage: requested)
        transcript.model = choice.model
        transcript.modelFallbackReason = choice.fallbackReason
        return transcript
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
            ? (alternative?.languages?.first).map(baseLanguageCode) ?? "en" : baseLanguageCode(requestedLanguage)
        return EngineTranscript(
            text: alternative?.transcript.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", words: words,
            engine: .deepgram, languageCode: language)
    }
}
