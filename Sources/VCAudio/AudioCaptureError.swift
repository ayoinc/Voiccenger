import CoreAudio
import Foundation

/// Failures raised by the capture sources, recorder and Core Audio helpers in this module.
public enum AudioCaptureError: Error, LocalizedError, Equatable, Sendable {
    /// The user (or an MDM profile) has denied microphone access to this app.
    case microphonePermissionDenied
    /// The system has no audio input device, or the selected device exposes no input channels.
    case noInputDevice
    /// No input device with the requested Core Audio UID is connected.
    case deviceNotFound(uid: String)
    /// A microphone-array channel map refers to channels the device does not have.
    case invalidChannelMap(channelMap: [Int], deviceChannelCount: Int)
    /// The stream format cannot be captured by this module.
    case unsupportedFormat(String)
    /// `start()` was called on a source that is already running.
    case alreadyRunning
    /// AVAudioEngine refused to start or reconfigure.
    case engineFailure(String)
    /// A Core Audio call failed. `status` is the raw OSStatus.
    case coreAudio(operation: String, status: OSStatus)
    /// An audio file could not be opened or decoded.
    case fileUnreadable(path: String, reason: String)
    /// An audio file could not be created or written.
    case fileUnwritable(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "Microphone access was denied. Allow it in System Settings › Privacy & Security › Microphone."
        case .noInputDevice:
            "No audio input device is available."
        case .deviceNotFound(let uid):
            "The audio input device “\(uid)” is not connected."
        case .invalidChannelMap(let map, let count):
            "The microphone array channel map \(map) does not fit a device with \(count) input channel\(count == 1 ? "" : "s")."
        case .unsupportedFormat(let detail):
            "Unsupported audio format: \(detail)."
        case .alreadyRunning:
            "The audio source is already running."
        case .engineFailure(let detail):
            "The audio engine failed: \(detail)."
        case .coreAudio(let operation, let status):
            "Core Audio failed to \(operation) (\(CoreAudioProperty.describe(status)))."
        case .fileUnreadable(let path, let reason):
            "Could not read audio file \(path): \(reason)."
        case .fileUnwritable(let path, let reason):
            "Could not write audio file \(path): \(reason)."
        }
    }
}
