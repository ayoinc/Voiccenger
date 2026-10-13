import Foundation

public enum UtteranceIntent: String, Codable, Sendable, CaseIterable, Hashable {
    case statement
    case question
    case proposal
    case decision
    /// Speaker commits to doing something ("I'll send the deck").
    case commitment
    /// Speaker asks someone else to do something.
    case request
    case objection
    /// Speaker corrects themselves or someone else.
    case correction
    case smallTalk
}

public struct ActionItem: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var task: String
    public var owner: String?
    /// Free text as spoken ("by Friday"); not parsed into a date.
    public var due: String?
    public var sourceSegmentID: UUID?

    public init(id: UUID = UUID(), task: String, owner: String? = nil, due: String? = nil, sourceSegmentID: UUID? = nil) {
        self.id = id
        self.task = task
        self.owner = owner
        self.due = due
        self.sourceSegmentID = sourceSegmentID
    }
}

/// Live per-utterance analysis.
public struct UtteranceInsight: Codable, Sendable, Hashable {
    public var intent: UtteranceIntent
    /// What the speaker most likely meant, when the utterance contains a slip, misstatement,
    /// self-contradiction or likely recognition error. Nil when the text is fine.
    public var correctedText: String?
    public var correctionReason: String?
    /// A proactive prompt for the meeting ("Propose: confirm the Friday deadline with Sam").
    public var suggestion: String?
    public var actionItem: ActionItem?

    public init(
        intent: UtteranceIntent, correctedText: String? = nil, correctionReason: String? = nil,
        suggestion: String? = nil, actionItem: ActionItem? = nil
    ) {
        self.intent = intent
        self.correctedText = correctedText
        self.correctionReason = correctionReason
        self.suggestion = suggestion
        self.actionItem = actionItem
    }

    /// Worth surfacing to the user while the meeting is running.
    public var needsAttention: Bool { correctedText != nil || suggestion != nil || actionItem != nil }
}

/// One line of transcript as given to the language model.
public struct ContextLine: Codable, Sendable, Hashable {
    public var segmentID: UUID
    public var speaker: String
    public var time: TimeInterval
    public var text: String

    public init(segmentID: UUID, speaker: String, time: TimeInterval, text: String) {
        self.segmentID = segmentID
        self.speaker = speaker
        self.time = time
        self.text = text
    }
}

public struct TopicSummary: Codable, Sendable, Hashable {
    public var title: String
    public var summary: String
    public var speakers: [String]
    public init(title: String, summary: String, speakers: [String]) {
        self.title = title
        self.summary = summary
        self.speakers = speakers
    }
}

public struct CorrectionNote: Codable, Sendable, Hashable {
    public var speaker: String
    public var original: String
    public var corrected: String
    public var reason: String
    public init(speaker: String, original: String, corrected: String, reason: String) {
        self.speaker = speaker
        self.original = original
        self.corrected = corrected
        self.reason = reason
    }
}

public struct ParticipantSummary: Codable, Sendable, Hashable {
    public var name: String
    public var keyPoints: [String]
    public init(name: String, keyPoints: [String]) {
        self.name = name
        self.keyPoints = keyPoints
    }
}

/// Post-meeting report.
public struct MeetingReport: Codable, Sendable, Hashable {
    public var title: String
    public var overview: String
    public var topics: [TopicSummary]
    public var decisions: [String]
    public var actionItems: [ActionItem]
    /// Facts, numbers, dates and caveats worth remembering.
    public var notesToRemember: [String]
    /// "Things that could have been said": unaddressed risks, missing follow-ups, unasked questions.
    public var missedOpportunities: [String]
    public var openQuestions: [String]
    public var corrections: [CorrectionNote]
    public var participantSummaries: [ParticipantSummary]
    public var generatedBy: String
    public var generatedAt: Date

    public init(
        title: String, overview: String, topics: [TopicSummary], decisions: [String], actionItems: [ActionItem],
        notesToRemember: [String], missedOpportunities: [String], openQuestions: [String],
        corrections: [CorrectionNote], participantSummaries: [ParticipantSummary], generatedBy: String,
        generatedAt: Date = Date()
    ) {
        self.title = title
        self.overview = overview
        self.topics = topics
        self.decisions = decisions
        self.actionItems = actionItems
        self.notesToRemember = notesToRemember
        self.missedOpportunities = missedOpportunities
        self.openQuestions = openQuestions
        self.corrections = corrections
        self.participantSummaries = participantSummaries
        self.generatedBy = generatedBy
        self.generatedAt = generatedAt
    }
}

public protocol MeetingIntelligence: Sendable {
    /// Human-readable engine name shown in reports ("Apple Intelligence (on-device)", "Claude …").
    var engineName: String { get }
    /// Classify intent, detect slips/misstatements and propose corrections or prompts for one utterance.
    func analyze(utterance: ContextLine, recentContext: [ContextLine]) async throws -> UtteranceInsight
    /// Build the post-meeting report from the whole transcript.
    func report(transcript: [ContextLine], participants: [String], meetingTitle: String?) async throws
        -> MeetingReport
}
