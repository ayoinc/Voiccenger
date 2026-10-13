import Foundation
import VCModels
import WhisperKit

/// OpenAI Whisper large-v3 turbo (Core ML, via WhisperKit) with word timestamps and prompt biasing.
///
/// `@unchecked Sendable`: the `WhisperKit` instance is not thread-safe; every use goes through `lock`,
/// one inference at a time.
final class WhisperTranscriber: AccurateTranscriber, @unchecked Sendable {
    let kind = SpeechEngineKind.whisper
    private let kit: WhisperKit
    private let lock = AsyncLock()

    /// Folder name of the model in `argmaxinc/whisperkit-coreml`.
    static let variant = "openai_whisper-large-v3-v20240930_turbo"
    /// Hugging Face repo holding the tokenizer WhisperKit loads for large-v3 models.
    static let tokenizerRepo = "openai/whisper-large-v3"
    /// Compiled models WhisperKit loads from the model folder.
    static let requiredModels = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
    /// Whisper's decoder context is 448 tokens; at most half may be prompt.
    static let maximumPromptTokens = 200
    /// Shorter input has nothing to transcribe.
    static let minimumSamples = 1_600

    static var languageCodes: [String] { Constants.languageCodes.sorted() }

    /// `<base>/models/argmaxinc/whisperkit-coreml/<variant>`, where WhisperKit's hub client puts the model.
    static func modelFolder(base: URL) -> URL {
        base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant)", isDirectory: true)
    }

    /// `<base>/models/openai/whisper-large-v3`, where the tokenizer is downloaded and looked up.
    static func tokenizerFolder(base: URL) -> URL {
        base.appendingPathComponent("models/\(tokenizerRepo)", isDirectory: true)
    }

    private init(kit: WhisperKit) {
        self.kit = kit
    }

    /// Loads the model and tokenizer from `base` without touching the network.
    static func load(base: URL) async throws -> WhisperTranscriber {
        let config = WhisperKitConfig(
            model: variant, downloadBase: base, modelFolder: modelFolder(base: base).path, tokenizerFolder: base,
            verbose: false, logLevel: .error, prewarm: false, load: true, download: false)
        return WhisperTranscriber(kit: try await WhisperKit(config))
    }

    /// Downloads model and tokenizer into `base`. `progress` receives 0...1.
    static func download(base: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await WhisperKit.download(variant: variant, downloadBase: base) { p in
            progress(min(p.fractionCompleted, 1) * 0.98)
        }
        // Fetches tokenizer.json into the hub layout under `base` (no-op when already present).
        _ = try await ModelUtilities.loadTokenizer(for: .largev3, tokenizerFolder: base)
        progress(1)
    }

    func transcribe(samples16k: [Float], languageCode: String, prompt: [String]) async throws -> EngineTranscript {
        let code = baseLanguageCode(languageCode)
        guard Constants.languageCodes.contains(code) else {
            throw TranscriptionError.unsupportedLanguage(languageCode, .whisper)
        }
        guard samples16k.count >= Self.minimumSamples else {
            return EngineTranscript(text: "", words: [], engine: .whisper, languageCode: code)
        }
        let promptTokens = try await lock.withLock { [self] in
            kit.tokenizer.flatMap { Self.promptTokens(prompt, tokenizer: $0) }
        }
        var results = try await decode(samples16k, language: code, promptTokens: promptTokens)
        // A prompt occasionally makes Whisper end the transcript at once (empty text for clear speech);
        // the unprompted decode of the same audio is then the better answer.
        if promptTokens != nil, Self.text(of: results).isEmpty {
            results = try await decode(samples16k, language: code, promptTokens: nil)
        }
        let segments = results.flatMap(\.segments)
        let text = Self.text(of: results)
        let words = segments.flatMap { $0.words ?? [] }.compactMap { timing -> TimedWord? in
            let word = timing.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { return nil }
            return TimedWord(
                text: word, range: TimeRange(start: Double(timing.start), end: Double(timing.end)),
                confidence: Double(timing.probability))
        }
        return EngineTranscript(text: text, words: words, engine: .whisper, languageCode: code)
    }

    private func decode(_ samples: [Float], language: String, promptTokens: [Int]?) async throws -> [TranscriptionResult] {
        try await lock.withLock { [self] in
            // No chunking strategy: input over 30 s is decoded window by window, each seeking to the last
            // timestamp. WhisperKit's VAD chunking cuts mid-phrase and cost ~10 WER points on accented clips.
            let options = DecodingOptions(
                verbose: false, task: .transcribe, language: language, temperature: 0, usePrefillPrompt: true,
                detectLanguage: false, skipSpecialTokens: true, withoutTimestamps: false, wordTimestamps: true,
                promptTokens: promptTokens)
            return try await kit.transcribe(audioArray: samples, decodeOptions: options)
        }
    }

    private static func text(of results: [TranscriptionResult]) -> String {
        results.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// " term, term, …" encoded without special tokens and capped at the prompt budget (whole terms only).
    static func promptTokens(_ prompt: [String], tokenizer: any WhisperTokenizer) -> [Int]? {
        var seen = Set<String>()
        var tokens: [Int] = []
        for term in prompt {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            let piece = tokenizer.encode(text: (tokens.isEmpty ? " " : ", ") + trimmed)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            guard tokens.count + piece.count <= maximumPromptTokens else { break }
            tokens += piece
        }
        return tokens.isEmpty ? nil : tokens
    }
}
