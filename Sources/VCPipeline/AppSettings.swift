import Foundation
import Observation
import VCIntelligence
import VCModels
import VCSpatial
import VCTranscription

/// User preferences, persisted in `UserDefaults`.
@MainActor @Observable
public final class AppSettings {
    private enum Key {
        static let autoDetectMeetings = "autoDetectMeetings"
        static let autoRecordOnline = "autoRecordOnlineMeetings"
        static let inPersonDetection = "inPersonDetection"
        static let localeID = "transcriptionLocaleID"
        static let autoLanguage = "autoLanguage"
        static let customVocabulary = "customVocabulary"
        static let engine = "intelligenceEngine"
        static let inputDeviceUID = "inputDeviceUID"
        static let arrayPresetName = "micArrayPreset"
        static let recordAudio = "recordAudio"
        static let speechEngine = "speechEngine"
        static let spelling = "spelling"
        static let downloadModelsAutomatically = "downloadModelsAutomatically"
        static let recordingConsentAcknowledged = "recordingConsentAcknowledged"
        static let capabilitiesReviewed = "capabilitiesReviewed"
        static let deepgramModel = "deepgramModel"
        static let deepgramCalibrationModels = "deepgramCalibrationModels"
        static let deepgramModelCatalog = "deepgramModelCatalog"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Watch for conferencing apps using the microphone.
    public var autoDetectMeetings: Bool { didSet { defaults.set(autoDetectMeetings, forKey: Key.autoDetectMeetings) } }
    /// Start recording detected online meetings automatically instead of asking with a notification.
    public var autoRecordOnline: Bool { didSet { defaults.set(autoRecordOnline, forKey: Key.autoRecordOnline) } }
    /// Listen on the microphone for sustained conversation when no meeting app is active.
    public var inPersonDetection: Bool { didSet { defaults.set(inPersonDetection, forKey: Key.inPersonDetection) } }
    public var localeID: String { didSet { defaults.set(localeID, forKey: Key.localeID) } }
    public var autoLanguage: Bool { didSet { defaults.set(autoLanguage, forKey: Key.autoLanguage) } }
    /// Names and jargon passed to the recognizer, one per entry.
    public var customVocabulary: [String] { didSet { defaults.set(customVocabulary, forKey: Key.customVocabulary) } }
    public var engine: IntelligenceEngineKind { didSet { defaults.set(engine.rawValue, forKey: Key.engine) } }
    /// Core Audio UID of the input device; nil follows the system default.
    public var inputDeviceUID: String? { didSet { defaults.set(inputDeviceUID, forKey: Key.inputDeviceUID) } }
    /// Name of an `ArrayPresets` geometry when the input is a microphone array.
    public var arrayPresetName: String? { didSet { defaults.set(arrayPresetName, forKey: Key.arrayPresetName) } }
    /// Keep audio recordings next to each meeting's transcript.
    public var recordAudio: Bool { didSet { defaults.set(recordAudio, forKey: Key.recordAudio) } }
    /// Voice model that transcribes meetings (Apple only previews live text until it's ready).
    public var speechEngine: SpeechEngineKind { didSet { defaults.set(speechEngine.rawValue, forKey: Key.speechEngine) } }
    /// Spelling for speakers without their own preference.
    public var spelling: SpellingVariant { didSet { defaults.set(spelling.rawValue, forKey: Key.spelling) } }
    /// Deepgram model for meetings and files (`Deepgram.defaultModel` = Nova-3); people can have their own.
    public var deepgramModel: String { didSet { defaults.set(deepgramModel, forKey: Key.deepgramModel) } }
    /// Up to `maximumExtraCalibrationModels` more Deepgram models compared when someone calibrates.
    public var deepgramCalibrationModels: [String] {
        didSet { defaults.set(deepgramCalibrationModels, forKey: Key.deepgramCalibrationModels) }
    }
    /// The Deepgram models the key could use when last fetched; nil before the first fetch or after the key changed.
    public var deepgramModelCatalog: DeepgramModelCatalog? {
        didSet {
            defaults.set(deepgramModelCatalog.flatMap { try? JSONEncoder().encode($0) }, forKey: Key.deepgramModelCatalog)
        }
    }
    /// Download the selected voice model when it's missing.
    public var downloadModelsAutomatically: Bool {
        didSet { defaults.set(downloadModelsAutomatically, forKey: Key.downloadModelsAutomatically) }
    }
    /// The user confirmed they tell participants when they record (and asked not to be reminded). Until then
    /// every recording asks first and detected meetings are never recorded automatically.
    public var recordingConsentAcknowledged: Bool {
        didSet { defaults.set(recordingConsentAcknowledged, forKey: Key.recordingConsentAcknowledged) }
    }
    /// The user has seen "What this Mac can do" (shown once at first launch).
    public var capabilitiesReviewed: Bool { didSet { defaults.set(capabilitiesReviewed, forKey: Key.capabilitiesReviewed) } }

    /// What this Mac supported when the settings loaded; defaults for new installs follow it.
    @ObservationIgnored public let capabilities: PlatformCapabilities

    public init(defaults: UserDefaults = .standard, capabilities: PlatformCapabilities = .current()) {
        self.defaults = defaults
        self.capabilities = capabilities
        defaults.register(defaults: [
            Key.autoDetectMeetings: true,
            Key.autoRecordOnline: false,
            Key.inPersonDetection: false,
            Key.autoLanguage: true,
            Key.recordAudio: true,
            Key.downloadModelsAutomatically: true,
        ])
        autoDetectMeetings = defaults.bool(forKey: Key.autoDetectMeetings)
        autoRecordOnline = defaults.bool(forKey: Key.autoRecordOnline)
        inPersonDetection = defaults.bool(forKey: Key.inPersonDetection)
        localeID = defaults.string(forKey: Key.localeID) ?? Self.systemLocaleID
        autoLanguage = defaults.bool(forKey: Key.autoLanguage)
        customVocabulary = defaults.stringArray(forKey: Key.customVocabulary) ?? []
        // Engines this Mac can never run (Apple Intelligence before macOS 26 or on Intel, Apple Speech before
        // macOS 26) give way to the platform default; one that's merely switched off stays selected.
        let storedEngine = defaults.string(forKey: Key.engine).flatMap(IntelligenceEngineKind.init(rawValue:))
        engine =
            if let storedEngine, !(storedEngine == .apple && capabilities.appleIntelligence.isPermanentlyUnavailable) {
                storedEngine
            } else { capabilities.defaultIntelligence }
        inputDeviceUID = defaults.string(forKey: Key.inputDeviceUID)
        arrayPresetName = defaults.string(forKey: Key.arrayPresetName)
        recordAudio = defaults.bool(forKey: Key.recordAudio)
        speechEngine = capabilities.usableSpeechEngine(
            defaults.string(forKey: Key.speechEngine).flatMap(SpeechEngineKind.init(rawValue:)) ?? capabilities.defaultSpeechEngine)
        spelling = defaults.string(forKey: Key.spelling).flatMap(SpellingVariant.init(rawValue:)) ?? .unchanged
        downloadModelsAutomatically = defaults.bool(forKey: Key.downloadModelsAutomatically)
        recordingConsentAcknowledged = defaults.bool(forKey: Key.recordingConsentAcknowledged)
        deepgramModel = defaults.string(forKey: Key.deepgramModel) ?? Deepgram.defaultModel
        deepgramCalibrationModels = defaults.stringArray(forKey: Key.deepgramCalibrationModels) ?? []
        deepgramModelCatalog = defaults.data(forKey: Key.deepgramModelCatalog)
            .flatMap { try? JSONDecoder().decode(DeepgramModelCatalog.self, from: $0) }
        capabilitiesReviewed = defaults.bool(forKey: Key.capabilitiesReviewed)
    }

    public var arrayGeometry: MicArrayGeometry? {
        guard let name = arrayPresetName else { return nil }
        return ArrayPresets.all.first { $0.name == name }
    }

    /// The user's locale as a BCP-47 identifier ("en-GB").
    public nonisolated static var systemLocaleID: String {
        let l = Locale.current
        if let language = l.language.languageCode?.identifier, let region = l.region?.identifier {
            return "\(language)-\(region)"
        }
        return l.identifier(.bcp47)
    }

    /// Extra Deepgram models a calibration may compare besides `deepgramModel`.
    public static let maximumExtraCalibrationModels = 2

    /// The Deepgram models a calibration compares: the chosen one, then up to two ticked extras.
    public var calibrationDeepgramModels: [String] {
        var models = [deepgramModel]
        for model in deepgramCalibrationModels where !models.contains(where: { Deepgram.sameModel($0, model) }) {
            guard models.count <= Self.maximumExtraCalibrationModels else { break }
            models.append(model)
        }
        return models
    }

    /// Session configuration for a meeting started now with these preferences.
    public func sessionConfig(
        kind: MeetingKind, detected: DetectedMeeting?, meetingsDirectory: URL
    ) -> MeetingSession.Config {
        MeetingSession.Config(
            kind: kind, detectedMeeting: detected, microphoneDeviceUID: inputDeviceUID, arrayGeometry: arrayGeometry,
            localeID: localeID, autoLanguage: autoLanguage, engineKind: engine, speechEngine: speechEngine,
            deepgramModel: deepgramModel,
            spelling: spelling, contextualStrings: customVocabulary, recordAudio: recordAudio,
            meetingsDirectory: meetingsDirectory)
    }
}
