import Foundation

/// An enrolled person. Embeddings are L2-normalized 256-d WeSpeaker vectors;
/// several per person (different sentences / sessions) make similar voices separable.
public struct SpeakerProfile: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var embeddings: [[Float]]
    /// Recognizer locale that best fits this person's accent, e.g. "en-IN". Set by accent detection.
    public var preferredLocaleID: String?
    public var colorIndex: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(), name: String, embeddings: [[Float]], preferredLocaleID: String? = nil,
        colorIndex: Int = 0, createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.embeddings = embeddings
        self.preferredLocaleID = preferredLocaleID
        self.colorIndex = colorIndex
        self.createdAt = createdAt
    }
}

/// "Who spoke when" for one channel.
public struct SpeakerTurn: Codable, Sendable, Hashable {
    public var channel: AudioChannel
    public var range: TimeRange
    /// Stable participant key. Enrolled: "profile:<UUID>". Unknown: "<channel.keyPrefix>:<cluster>", e.g. "mic:S2".
    public var speakerKey: String
    public var profileID: UUID?
    /// Cosine similarity to the matched profile, or the diarizer's quality score for unknown speakers. 0...1.
    public var confidence: Double
    /// True when the best enrolled match was too close to the runner-up to call (similar voices).
    public var isAmbiguous: Bool

    public init(
        channel: AudioChannel, range: TimeRange, speakerKey: String, profileID: UUID?, confidence: Double,
        isAmbiguous: Bool = false
    ) {
        self.channel = channel
        self.range = range
        self.speakerKey = speakerKey
        self.profileID = profileID
        self.confidence = confidence
        self.isAmbiguous = isAmbiguous
    }

    public static func profileKey(_ id: UUID) -> String { "profile:\(id.uuidString)" }
}

public struct Participant: Codable, Sendable, Identifiable, Hashable {
    /// Same as `SpeakerTurn.speakerKey`.
    public var id: String
    public var displayName: String
    public var profileID: UUID?
    public var channel: AudioChannel
    public var localeID: String?
    /// Estimated seat direction (degrees, 0 = array front, counter-clockwise) when an array is in use.
    public var seatAzimuthDegrees: Double?
    public var speakingTime: TimeInterval
    public var colorIndex: Int

    public init(
        id: String, displayName: String, profileID: UUID? = nil, channel: AudioChannel, localeID: String? = nil,
        seatAzimuthDegrees: Double? = nil, speakingTime: TimeInterval = 0, colorIndex: Int = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.profileID = profileID
        self.channel = channel
        self.localeID = localeID
        self.seatAzimuthDegrees = seatAzimuthDegrees
        self.speakingTime = speakingTime
        self.colorIndex = colorIndex
    }

    public var isEnrolled: Bool { profileID != nil }
}
