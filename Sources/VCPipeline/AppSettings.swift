import Foundation
import Observation
import VCIntelligence
import VCModels
import VCSpatial

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
    /// Download the selected voice model when it's missing.
    public var downloadModelsAutomatically: Bool {
        didSet { defaults.set(downloadModelsAutomatically, forKey: Key.downloadModelsAutomatically) }
    }
    /// The user confirmed they tell participants when they record (and asked not to be reminded). Until then
    /// every recording asks first and detected meetings are never recorded automatically.
    public var recordingConsentAcknowledged: Bool {
        didSet { defaults.set(recordingConsentAcknowledged, forKey: Key.recordingConsentAcknowledged) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        engine = defaults.string(forKey: Key.engine).flatMap(IntelligenceEngineKind.init(rawValue:)) ?? .apple
        inputDeviceUID = defaults.string(forKey: Key.inputDeviceUID)
        arrayPresetName = defaults.string(forKey: Key.arrayPresetName)
        recordAudio = defaults.bool(forKey: Key.recordAudio)
        speechEngine = defaults.string(forKey: Key.speechEngine).flatMap(SpeechEngineKind.init(rawValue:)) ?? .cohere
        spelling = defaults.string(forKey: Key.spelling).flatMap(SpellingVariant.init(rawValue:)) ?? .unchanged
        downloadModelsAutomatically = defaults.bool(forKey: Key.downloadModelsAutomatically)
        recordingConsentAcknowledged = defaults.bool(forKey: Key.recordingConsentAcknowledged)
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

    /// Session configuration for a meeting started now with these preferences.
    public func sessionConfig(
        kind: MeetingKind, detected: DetectedMeeting?, meetingsDirectory: URL
    ) -> MeetingSession.Config {
        MeetingSession.Config(
            kind: kind, detectedMeeting: detected, microphoneDeviceUID: inputDeviceUID, arrayGeometry: arrayGeometry,
            localeID: localeID, autoLanguage: autoLanguage, engineKind: engine, speechEngine: speechEngine,
            spelling: spelling, contextualStrings: customVocabulary, recordAudio: recordAudio,
            meetingsDirectory: meetingsDirectory)
    }
}
