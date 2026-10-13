import Foundation

public struct TimedWord: Codable, Sendable, Hashable {
    public var text: String
    public var range: TimeRange
    public var confidence: Double?

    public init(text: String, range: TimeRange, confidence: Double? = nil) {
        self.text = text
        self.range = range
        self.confidence = confidence
    }
}

/// One recognizer result (volatile or final) for a channel.
public struct TranscriptUpdate: Sendable, Hashable {
    public var channel: AudioChannel
    public var text: String
    /// Session-clock time range of the audio this text covers.
    public var range: TimeRange
    /// Mean recognizer confidence in 0...1 when available.
    public var confidence: Double?
    /// BCP-47 identifier of the locale that produced the text, e.g. "en-GB".
    public var localeID: String
    /// Word-level timing when available; lets the aligner split a result across speaker turns.
    public var words: [TimedWord]

    public init(
        channel: AudioChannel, text: String, range: TimeRange, confidence: Double?, localeID: String,
        words: [TimedWord] = []
    ) {
        self.channel = channel
        self.text = text
        self.range = range
        self.confidence = confidence
        self.localeID = localeID
        self.words = words
    }
}

public enum TranscriptEvent: Sendable, Hashable {
    /// Provisional text that may still change. Replaces the previous volatile text for the channel.
    case volatile(TranscriptUpdate)
    /// Committed text. Clears the volatile text it covers.
    case final(TranscriptUpdate)
    /// The transcriber switched recognition locale (language or accent) for a channel.
    case localeChanged(channel: AudioChannel, from: String, to: String, reason: String)
}

/// Recognition quality of one locale over the same audio; used for accent / language detection.
public struct LocaleScore: Codable, Sendable, Hashable {
    public var localeID: String
    public var meanConfidence: Double
    public var wordCount: Int
    public var transcript: String

    public init(localeID: String, meanConfidence: Double, wordCount: Int, transcript: String) {
        self.localeID = localeID
        self.meanConfidence = meanConfidence
        self.wordCount = wordCount
        self.transcript = transcript
    }
}

/// A finalized, speaker-attributed piece of the meeting transcript.
public struct TranscriptSegment: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var channel: AudioChannel
    /// Key of the `Participant` who spoke.
    public var speakerKey: String
    public var range: TimeRange
    public var text: String
    public var confidence: Double?
    public var localeID: String
    /// Direction of arrival when a microphone array is in use.
    public var direction: DirectionEstimate?
    /// Filled asynchronously by the intelligence engine.
    public var insight: UtteranceInsight?

    public init(
        id: UUID = UUID(), channel: AudioChannel, speakerKey: String, range: TimeRange, text: String,
        confidence: Double?, localeID: String, direction: DirectionEstimate? = nil,
        insight: UtteranceInsight? = nil
    ) {
        self.id = id
        self.channel = channel
        self.speakerKey = speakerKey
        self.range = range
        self.text = text
        self.confidence = confidence
        self.localeID = localeID
        self.direction = direction
        self.insight = insight
    }
}
