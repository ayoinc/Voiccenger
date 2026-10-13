import FluidAudio
import Foundation
import VCModels

/// Cohere Transcribe (Core ML, via FluidAudio). Text only — no word timings — and no prompt biasing.
/// Audio longer than the 35 s encoder window is transcribed by FluidAudio's overlapping-window merge.
final class CohereTranscriber: AccurateTranscriber {
    let kind = SpeechEngineKind.cohere
    private let pipeline: CoherePipeline
    private let models: CoherePipeline.LoadedModels
    private let lock = AsyncLock()

    /// Shorter input has no mel frames; it is returned as silence.
    static let minimumSamples = 1_600

    /// Files FluidAudio needs in the model directory.
    static let requiredFiles = [
        ModelNames.CohereTranscribe.encoderCompiledFile,
        ModelNames.CohereTranscribe.decoderCacheExternalV2CompiledFile,
        ModelNames.CohereTranscribe.vocab,
    ]

    static let languageCodes = CohereAsrConfig.Language.allCases.map(\.rawValue)

    private init(pipeline: CoherePipeline, models: CoherePipeline.LoadedModels) {
        self.pipeline = pipeline
        self.models = models
    }

    /// Loads encoder, decoder and vocabulary from `directory` (the `cohere-transcribe/q8` folder).
    ///
    /// CPU + Neural Engine, not `.all`: with the GPU allowed, Core ML builds GPU graphs on every launch
    /// (~60 s load+warm, ~12 GB footprint on an M-series Mac); on the Neural Engine the same models load and
    /// warm in ~11 s with ~0.3 GB footprint and identical output, decoding ~15 % slower.
    static func load(from directory: URL) async throws -> CohereTranscriber {
        let models = try await CoherePipeline.loadModels(
            encoderDir: directory, decoderDir: directory, vocabDir: directory, decoderVariant: .v2,
            computeUnits: .cpuAndNeuralEngine)
        return CohereTranscriber(pipeline: CoherePipeline(), models: models)
    }

    func transcribe(samples16k: [Float], languageCode: String, prompt: [String]) async throws -> EngineTranscript {
        let code = baseLanguageCode(languageCode)
        guard let language = CohereAsrConfig.Language(rawValue: code) else {
            throw TranscriptionError.unsupportedLanguage(languageCode, .cohere)
        }
        guard samples16k.count >= Self.minimumSamples else {
            return EngineTranscript(text: "", words: nil, engine: .cohere, languageCode: code)
        }
        let pipeline = pipeline
        let models = models
        let result = try await lock.withLock {
            try await pipeline.transcribeLong(audio: samples16k, models: models, language: language)
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return EngineTranscript(text: text, words: nil, engine: .cohere, languageCode: code)
    }
}
