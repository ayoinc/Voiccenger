import Foundation
import VCModels

/// Live transcription of one audio channel: audio in, volatile and final text out.
/// `RefiningTranscriber` (Apple preview refined on-device) and `DeepgramLiveTranscriber` (Deepgram streaming).
public protocol ChannelTranscriber: Actor {
    nonisolated var events: AsyncStream<TranscriptEvent> { get }
    func start() async throws
    /// Any sample rate, session-clock times. Dropped before `start()` and after `finish()`.
    func append(_ chunk: AudioChunk) async
    /// Names and terms to bias recognition toward.
    func setPrompt(_ prompt: [String]) async
    /// Delivers the remaining finals, then finishes `events`.
    func finish() async
}

extension RefiningTranscriber: ChannelTranscriber {}
