@preconcurrency import AVFAudio
import Foundation
import Speech
import VCModels

/// Apple's classic recognizer (`SFSpeechRecognizer`, macOS 10.15+): the Apple Speech engine on Macs without
/// macOS 26's `SpeechTranscriber` — every Mac before macOS 26, and Intel Macs. It runs on this Mac when the
/// locale supports on-device recognition, otherwise on Apple's servers (`isOnDevice(localeID:)` says which).
/// A request handles about a minute of audio at most, so longer audio is recognized in pieces cut at pauses.
public enum ClassicSpeech {
    /// Longest audio sent in one request; the recognizer stops at about a minute.
    static let maximumRequestSeconds = 30.0

    /// A recognizer exists for this Mac's language (the user may still have to allow speech recognition).
    public static var isAvailable: Bool {
        SFSpeechRecognizer() != nil
    }

    /// Whether `localeID` is recognized on this Mac rather than on Apple's servers.
    public static func isOnDevice(localeID: String) -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: localeID))?.supportsOnDeviceRecognition ?? false
    }

    /// Asks for speech-recognition permission once; true when granted.
    public static func authorize() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        @unknown default: return false
        }
    }

    /// Recognizes 16 kHz mono audio; word times are seconds from the first sample.
    static func transcribe(samples16k: [Float], localeID: String, prompt: [String]) async throws -> EngineTranscript {
        let code = baseLanguageCode(localeID)
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)), recognizer.isAvailable else {
            throw TranscriptionError.unsupportedLocale(localeID)
        }
        guard await authorize() else { throw TranscriptionError.speechRecognitionNotAuthorized }
        var texts: [String] = []
        var words: [TimedWord] = []
        let pieces = samples16k.count > Int(maximumRequestSeconds * PCM.recognitionRate)
            ? SpeechChunker.split(samples16k, maximumSeconds: maximumRequestSeconds) : [0..<samples16k.count]
        for piece in pieces {
            try Task.checkCancellation()
            let offset = Double(piece.lowerBound) / PCM.recognitionRate
            guard let result = try await recognize(Array(samples16k[piece]), recognizer: recognizer, prompt: prompt)
            else { continue }
            texts.append(result.text)
            words += result.words.map { word in
                TimedWord(
                    text: word.text, range: TimeRange(start: offset + word.range.start, end: offset + word.range.end),
                    confidence: word.confidence)
            }
        }
        return EngineTranscript(text: texts.joined(separator: " "), words: words, engine: .apple, languageCode: code)
    }

    private struct Recognized: Sendable {
        let text: String
        let words: [TimedWord]
    }

    /// One request; nil when no speech was heard. Word times are seconds from the first of `samples`.
    private static func recognize(_ samples: [Float], recognizer: SFSpeechRecognizer, prompt: [String]) async throws
        -> Recognized?
    {
        guard !samples.isEmpty else { return nil }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        request.contextualStrings = prompt
        request.append(try PCM.monoFloatBuffer(samples, format: PCM.monoFloatFormat(sampleRate: PCM.recognitionRate)))
        request.endAudio()
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Recognized?, any Error>) in
                let once = ResumeOnce(continuation)
                box.task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        let transcription = result.bestTranscription
                        let words = transcription.segments.map { segment in
                            TimedWord(
                                text: segment.substring,
                                range: TimeRange(start: segment.timestamp, end: segment.timestamp + segment.duration),
                                confidence: segment.confidence > 0 ? Double(segment.confidence) : nil)
                        }
                        once.resume(.success(Recognized(text: transcription.formattedString, words: words)))
                    } else if let error {
                        // "No speech detected" (kAFAssistantErrorDomain 1110) is an empty result, not a failure.
                        let nsError = error as NSError
                        once.resume(nsError.code == 1110 || nsError.code == 1101 ? .success(nil) : .failure(error))
                    }
                }
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    private final class TaskBox: @unchecked Sendable {
        // @unchecked: set once before the handler can fire, read on cancellation.
        var task: SFSpeechRecognitionTask?
    }

    private final class ResumeOnce: Sendable {
        private let state: Mutex<CheckedContinuation<Recognized?, any Error>?>
        init(_ continuation: CheckedContinuation<Recognized?, any Error>) { state = Mutex(continuation) }
        func resume(_ result: Result<Recognized?, any Error>) {
            let continuation = state.withLock { value -> CheckedContinuation<Recognized?, any Error>? in
                defer { value = nil }
                return value
            }
            continuation?.resume(with: result)
        }
    }
}
