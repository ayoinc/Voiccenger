import Foundation
import os
import VCModels

/// Failures surfaced by the transcription module.
public enum TranscriptionError: Error, LocalizedError, Sendable, Equatable {
    /// SpeechTranscriber is not available on this device (unsupported hardware or OS configuration).
    case speechTranscriberUnavailable
    /// No SpeechTranscriber locale matches the identifier.
    case unsupportedLocale(String)
    /// The locale is supported but its recognition assets are not installed.
    case assetsNotInstalled(String)
    /// The analyzer reported no audio format compatible with the transcriber.
    case noCompatibleAudioFormat
    /// Converting audio into the analyzer format failed.
    case audioConversionFailed(String)
    /// `start()` has not been called, or `finish()` already ran.
    case notRunning
    /// None of the candidate locales could be evaluated (unsupported or not installed).
    case noUsableCandidates([String])
    /// The voice model's files are not on this Mac; download it first.
    case modelNotDownloaded(SpeechEngineKind)
    /// The voice model cannot transcribe this ISO 639-1 language.
    case unsupportedLanguage(String, SpeechEngineKind)
    /// Speech recognition permission was denied (System Settings › Privacy & Security › Speech Recognition).
    case speechRecognitionNotAuthorized

    public var errorDescription: String? {
        switch self {
        case .speechRecognitionNotAuthorized:
            "Speech recognition isn't allowed. Turn on Voiccenger in System Settings › Privacy & Security › Speech Recognition."
        case .speechTranscriberUnavailable:
            "Speech transcription is not available on this Mac."
        case .unsupportedLocale(let id):
            "Speech transcription does not support the locale “\(id)”."
        case .assetsNotInstalled(let id):
            "Speech recognition assets for “\(id)” are not installed."
        case .noCompatibleAudioFormat:
            "The speech analyzer did not report a compatible audio format."
        case .audioConversionFailed(let detail):
            "Audio conversion for speech recognition failed: \(detail)"
        case .notRunning:
            "The transcriber is not running."
        case .noUsableCandidates(let ids):
            "None of the candidate locales (\(ids.joined(separator: ", "))) are installed and supported."
        case .modelNotDownloaded(let kind):
            "\(SpeechModelLibrary.info(kind).displayName) is not downloaded."
        case .unsupportedLanguage(let code, let kind):
            "\(SpeechModelLibrary.info(kind).displayName) does not support the language “\(code)”."
        }
    }
}

let transcriptionLog = Logger(subsystem: "com.voiccenger.app", category: "transcription")
