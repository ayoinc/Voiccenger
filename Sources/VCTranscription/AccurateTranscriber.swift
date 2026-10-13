import Foundation
import VCModels

/// Text from an accurate engine for one utterance. Word times are seconds relative to the start of the samples.
public struct EngineTranscript: Sendable, Hashable {
    public var text: String
    /// Per-word timing when the engine produces it (Whisper, Apple); nil otherwise (Cohere).
    public var words: [TimedWord]?
    public var engine: SpeechEngineKind
    /// ISO 639-1 language the text is in.
    public var languageCode: String

    public init(text: String, words: [TimedWord]?, engine: SpeechEngineKind, languageCode: String) {
        self.text = text
        self.words = words
        self.engine = engine
        self.languageCode = languageCode
    }
}

/// A loaded speech-to-text engine that transcribes complete utterances.
public protocol AccurateTranscriber: Sendable {
    var kind: SpeechEngineKind { get }
    /// samples: 16 kHz mono Float32, any length (long input chunked internally). prompt: names/terms to bias toward (Whisper uses it; Cohere ignores).
    func transcribe(samples16k: [Float], languageCode: String, prompt: [String]) async throws -> EngineTranscript
}

/// FIFO mutual exclusion across suspension points: engines run one inference at a time, in call order,
/// which bounds memory and keeps non-reentrant model state safe.
actor AsyncLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        do {
            let value = try await operation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// ISO 639-1 base of a language or locale identifier: "en-GB" → "en", "zh_Hans" → "zh", "EN" → "en".
func baseLanguageCode(_ code: String) -> String {
    let lower = code.lowercased()
    guard let separator = lower.firstIndex(where: { $0 == "-" || $0 == "_" }) else { return lower }
    return String(lower[..<separator])
}
