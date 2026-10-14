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
    /// When the line ends (session seconds), if known; reports use it for the end of an outline segment.
    public var end: TimeInterval?

    public init(segmentID: UUID, speaker: String, time: TimeInterval, text: String, end: TimeInterval? = nil) {
        self.segmentID = segmentID
        self.speaker = speaker
        self.time = time
        self.text = text
        self.end = end
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

/// One point of the conversation outline: what one speaker said, with the transcript lines it rests on.
public struct OutlinePoint: Codable, Sendable, Hashable {
    public var speaker: String
    public var text: String
    /// Start of the first cited line (session seconds).
    public var time: TimeInterval
    /// The transcript lines (segment IDs) the point cites, in transcript order.
    public var segmentIDs: [UUID]
    /// `text` is the speaker's own sentence, taken from the transcript, not a summary.
    public var isQuote: Bool

    public init(speaker: String, text: String, time: TimeInterval, segmentIDs: [UUID], isQuote: Bool = false) {
        self.speaker = speaker
        self.text = text
        self.time = time
        self.segmentIDs = segmentIDs
        self.isQuote = isQuote
    }
}

/// A stretch of the meeting in the conversation outline. Consecutive segments cover the whole meeting.
public struct OutlineSegment: Codable, Sendable, Hashable {
    public var heading: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var points: [OutlinePoint]
    /// Built from the transcript (quoted sentences) because the language model left this stretch out.
    public var isExtracted: Bool
    /// Built from the transcript because the language model's safety filter declined these lines (`isExtracted`
    /// is true as well).
    public var isDeclined: Bool

    public init(
        heading: String, start: TimeInterval, end: TimeInterval, points: [OutlinePoint], isExtracted: Bool = false,
        isDeclined: Bool = false
    ) {
        self.heading = heading
        self.start = start
        self.end = end
        self.points = points
        self.isExtracted = isExtracted || isDeclined
        self.isDeclined = isDeclined
    }

    private enum CodingKeys: String, CodingKey {
        case heading, start, end, points, isExtracted, isDeclined
    }

    /// Segments saved before `isDeclined` existed decode as not declined.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        heading = try c.decode(String.self, forKey: .heading)
        start = try c.decode(TimeInterval.self, forKey: .start)
        end = try c.decode(TimeInterval.self, forKey: .end)
        points = try c.decode([OutlinePoint].self, forKey: .points)
        isExtracted = try c.decode(Bool.self, forKey: .isExtracted)
        isDeclined = try c.decodeIfPresent(Bool.self, forKey: .isDeclined) ?? false
    }
}

/// Something the reader should know about how a report was written: parts handled without a language model,
/// or another engine standing in for the chosen one. Shown with the report, worded for the user.
public struct ReportNotice: Codable, Sendable, Hashable {
    public enum Reason: String, Codable, Sendable, Hashable {
        /// The language model's safety filter declined some requests; those parts come from the transcript.
        case safetyFilter
        /// The chosen engine could not write the report; another one did.
        case engineFallback
    }

    public var reason: Reason
    public var message: String
    /// Meeting time (seconds) handled without a language model; nil when none was.
    public var timeWithoutAI: TimeInterval?

    public init(reason: Reason, message: String, timeWithoutAI: TimeInterval? = nil) {
        self.reason = reason
        self.message = message
        self.timeWithoutAI = timeWithoutAI
    }
}

/// How a report was written.
public enum ReportKind: String, Codable, Sendable, Hashable {
    /// By a language model, checked against the transcript.
    case languageModel
    /// Extracted from the transcript without any language model: quoted sentences, question lines and possible
    /// action items found by word cues.
    case transcriptOutline
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
    /// What was discussed, in order: segments covering the whole meeting, each with attributed points.
    public var outline: [OutlineSegment]
    public var kind: ReportKind
    public var generatedBy: String
    public var generatedAt: Date
    /// How the report was written, when the reader should know: parts handled without AI, a stand-in engine.
    public var notices: [ReportNotice]

    public init(
        title: String, overview: String, topics: [TopicSummary], decisions: [String], actionItems: [ActionItem],
        notesToRemember: [String], missedOpportunities: [String], openQuestions: [String],
        corrections: [CorrectionNote], participantSummaries: [ParticipantSummary], outline: [OutlineSegment] = [],
        kind: ReportKind = .languageModel, generatedBy: String, generatedAt: Date = Date(), notices: [ReportNotice] = []
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
        self.outline = outline
        self.kind = kind
        self.generatedBy = generatedBy
        self.generatedAt = generatedAt
        self.notices = notices
    }

    private enum CodingKeys: String, CodingKey {
        case title, overview, topics, decisions, actionItems, notesToRemember, missedOpportunities, openQuestions
        case corrections, participantSummaries, outline, kind, generatedBy, generatedAt, notices
    }

    /// Reports saved before the outline existed decode with an empty outline, as language-model reports; before
    /// notices existed, without notices.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        overview = try c.decode(String.self, forKey: .overview)
        topics = try c.decode([TopicSummary].self, forKey: .topics)
        decisions = try c.decode([String].self, forKey: .decisions)
        actionItems = try c.decode([ActionItem].self, forKey: .actionItems)
        notesToRemember = try c.decode([String].self, forKey: .notesToRemember)
        missedOpportunities = try c.decode([String].self, forKey: .missedOpportunities)
        openQuestions = try c.decode([String].self, forKey: .openQuestions)
        corrections = try c.decode([CorrectionNote].self, forKey: .corrections)
        participantSummaries = try c.decode([ParticipantSummary].self, forKey: .participantSummaries)
        outline = try c.decodeIfPresent([OutlineSegment].self, forKey: .outline) ?? []
        kind = try c.decodeIfPresent(ReportKind.self, forKey: .kind) ?? .languageModel
        generatedBy = try c.decode(String.self, forKey: .generatedBy)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        notices = try c.decodeIfPresent([ReportNotice].self, forKey: .notices) ?? []
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
