import Foundation

/// Speech-to-text engine ("voice model"), as in Superwhisper's model picker.
public enum SpeechEngineKind: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    /// Apple SpeechTranscriber: instant streaming, one acoustic model per language (the locale only changes
    /// formatting), weakest on accented speech.
    case apple
    /// Cohere Transcribe (FluidAudio Core ML on the Neural Engine): most accurate on accented English; 14 languages; ~11 s warm-up per launch.
    case cohere
    /// OpenAI Whisper large-v3 turbo (WhisperKit): close second on accents; 99 languages incl. Swahili, Yoruba, Hausa, Amharic.
    case whisper
    /// Deepgram in the cloud (Nova-3 unless the user picks another model their key can use): streams live text
    /// over a WebSocket and transcribes files over HTTPS with word timings and keyterm hints. Audio leaves this
    /// Mac; needs the user's own Deepgram API key.
    case deepgram

    public var id: String { rawValue }
}

/// Output spelling for English transcripts.
public enum SpellingVariant: String, Codable, Sendable, CaseIterable, Hashable {
    /// Keep the engine's spelling.
    case unchanged
    case british
    case american
}

/// "When you hear X, write Y". Matched case-insensitively on word boundaries.
public struct TextReplacement: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var heard: String
    public var meant: String

    public init(id: UUID = UUID(), heard: String, meant: String) {
        self.id = id
        self.heard = heard
        self.meant = meant
    }
}

/// Word error rate of one engine on a calibration recording.
public struct EngineScore: Codable, Sendable, Hashable {
    public var engine: SpeechEngineKind
    /// 0...1 (can exceed 1 for very bad output). Lower is better.
    public var wordErrorRate: Double
    public var transcript: String
    /// The engine's model when it offers several (the Deepgram model, e.g. "nova-3"); nil otherwise and in
    /// calibrations saved before models could be compared.
    public var model: String?

    public init(engine: SpeechEngineKind, wordErrorRate: Double, transcript: String, model: String? = nil) {
        self.engine = engine
        self.wordErrorRate = wordErrorRate
        self.transcript = transcript
        self.model = model
    }
}

/// Result of reading the calibration passage(s).
public struct VoiceCalibration: Codable, Sendable, Hashable {
    public var date: Date
    /// Best first.
    public var scores: [EngineScore]

    public init(date: Date = Date(), scores: [EngineScore]) {
        self.date = date
        self.scores = scores
    }

    public var best: EngineScore? { scores.first }

    /// The Deepgram model that scored best when two or more Deepgram models were compared; nil otherwise (one
    /// Deepgram score says nothing about which model suits the person).
    public var bestDeepgramModel: String? {
        let deepgram = scores.filter { $0.engine == .deepgram && $0.model != nil }
        return deepgram.count > 1 ? deepgram.first?.model : nil
    }
}

/// How one person speaks, and how Voiccenger should transcribe them.
public struct VoiceSettings: Codable, Sendable, Hashable {
    /// `AccentRegion.id` the person's English (or other language) comes from, e.g. "ng" (Nigeria).
    public var accentRegionID: String?
    /// `AccentRegion.id` where they live now, e.g. "gb". Shapes default spelling and vocabulary.
    public var residenceRegionID: String?
    /// ISO 639-1 language they speak in meetings ("en", "yo", "sw"…).
    public var languageCode: String
    public var spelling: SpellingVariant
    /// Engine used for this person's speech; nil = the session default.
    public var preferredEngine: SpeechEngineKind?
    /// Deepgram model for this person's lines when Deepgram transcribes them (e.g. "nova-2-meeting"); nil = the
    /// app-wide Deepgram model. Calibration stores its best Deepgram model here unless the user chose another.
    public var deepgramModel: String?
    /// Names, places and terms this person says (boost/correct toward these spellings).
    public var vocabulary: [String]
    public var replacements: [TextReplacement]
    /// Seed the vocabulary with common names and places for `accentRegionID` and `residenceRegionID`.
    public var useRegionalVocabulary: Bool
    public var calibration: VoiceCalibration?

    public init(
        accentRegionID: String? = nil, residenceRegionID: String? = nil, languageCode: String = "en",
        spelling: SpellingVariant = .unchanged, preferredEngine: SpeechEngineKind? = nil, deepgramModel: String? = nil,
        vocabulary: [String] = [], replacements: [TextReplacement] = [], useRegionalVocabulary: Bool = true,
        calibration: VoiceCalibration? = nil
    ) {
        self.accentRegionID = accentRegionID
        self.residenceRegionID = residenceRegionID
        self.languageCode = languageCode
        self.spelling = spelling
        self.preferredEngine = preferredEngine
        self.deepgramModel = deepgramModel
        self.vocabulary = vocabulary
        self.replacements = replacements
        self.useRegionalVocabulary = useRegionalVocabulary
        self.calibration = calibration
    }

    public static let `default` = VoiceSettings()

    /// The Deepgram model for this person's lines: their own, else their calibration's best; nil = app-wide.
    public var effectiveDeepgramModel: String? { deepgramModel ?? calibration?.bestDeepgramModel }
}
