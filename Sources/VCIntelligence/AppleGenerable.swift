import Foundation
import FoundationModels
import VCModels

// Guided-generation output types for the on-device model.
//
// These conform to `Generable` by hand, spelling out exactly what `@Generable`/`@Guide` expand to:
// the FoundationModels macro plugin ships with Xcode only, and this package builds with the Command
// Line Tools. Property order is generation order, so each type lists what the model should decide first.

@available(macOS 26.0, *)
private func malformed(_ type: String, _ content: GeneratedContent) -> IntelligenceError {
    .malformedResponse("unexpected \(type) content: \(content.jsonString.prefix(200))")
}

@available(macOS 26.0, *)
extension GeneratedContent {
    /// Optional string property; missing, null and blank values all read as nil.
    fileprivate func text(_ key: String) -> String? {
        guard let value = try? value(String?.self, forProperty: key) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Array property where a missing or unreadable array reads as empty.
    fileprivate func list<Element: ConvertibleFromGeneratedContent>(_ key: String, of _: Element.Type = Element.self) -> [Element] {
        (try? value([Element].self, forProperty: key)) ?? []
    }
}

@available(macOS 26.0, *)
enum GenIntent: String, CaseIterable, Generable {
    case statement
    case question
    case proposal
    case decision
    case commitment
    case request
    case objection
    case correction
    case smallTalk

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, description: "Intent of the new utterance.", anyOf: allCases.map(\.rawValue))
    }

    init(_ content: GeneratedContent) throws {
        guard let value = Self(rawValue: try content.value(String.self)) else { throw malformed("intent", content) }
        self = value
    }

    var generatedContent: GeneratedContent { GeneratedContent(rawValue) }
}

@available(macOS 26.0, *)
struct GenActionItem: Generable, Equatable {
    var task: String
    var owner: String?
    var due: String?

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, description: "A concrete task.", properties: [
            .init(name: "task", description: "Short imperative task.", type: String.self),
            .init(name: "owner", description: "Name of the responsible person.", type: String?.self),
            .init(name: "due", description: "Deadline exactly as spoken.", type: String?.self),
        ])
    }

    init(task: String, owner: String?, due: String?) {
        self.task = task
        self.owner = owner
        self.due = due
    }

    init(_ content: GeneratedContent) throws {
        guard let task = content.text("task") else { throw malformed("action item", content) }
        self.init(task: task, owner: content.text("owner"), due: content.text("due"))
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["task": task, "owner": owner, "due": due])
    }

    var raw: RawActionItem { RawActionItem(task: task, owner: owner, due: due) }
}

/// Kind of correction for a live utterance; `none` is the usual answer.
@available(macOS 26.0, *)
enum GenCorrectionKind: String, CaseIterable, Generable {
    case none
    case selfCorrection
    case contradiction
    case mishearing

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, description: "Usually none.", anyOf: allCases.map(\.rawValue))
    }

    init(_ content: GeneratedContent) throws {
        guard let value = Self(rawValue: try content.value(String.self)) else { throw malformed("correction kind", content) }
        self = value
    }

    var generatedContent: GeneratedContent { GeneratedContent(rawValue) }
}

@available(macOS 26.0, *)
struct GenInsight: Generable, Equatable {
    var intent: GenIntent
    var correctionKind: GenCorrectionKind
    var correctedText: String?
    var contradictsLine: Int?
    var suggestion: String?
    var actionItem: GenActionItem?

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, description: "Analysis of the new utterance.", properties: [
            .init(name: "intent", type: GenIntent.self),
            .init(name: "correctionKind", type: GenCorrectionKind.self),
            .init(name: "correctedText", description: "Only when correctionKind is not none.", type: String?.self),
            .init(name: "contradictsLine", description: "Context line number; only for a contradiction.", type: Int?.self),
            .init(name: "suggestion", description: "Propose:/Confirm:/Ask:/Clarify: line; only when genuinely useful.", type: String?.self),
            .init(name: "actionItem", description: "Only when someone commits to or is asked to do a task after the meeting.", type: GenActionItem?.self),
        ])
    }

    init(
        intent: GenIntent, correctionKind: GenCorrectionKind, correctedText: String?, contradictsLine: Int?,
        suggestion: String?, actionItem: GenActionItem?
    ) {
        self.intent = intent
        self.correctionKind = correctionKind
        self.correctedText = correctedText
        self.contradictsLine = contradictsLine
        self.suggestion = suggestion
        self.actionItem = actionItem
    }

    init(_ content: GeneratedContent) throws {
        self.init(
            intent: try content.value(GenIntent.self, forProperty: "intent"),
            correctionKind: (try? content.value(GenCorrectionKind.self, forProperty: "correctionKind")) ?? .none,
            correctedText: content.text("correctedText"),
            contradictsLine: (try? content.value(Int?.self, forProperty: "contradictsLine")) ?? nil,
            suggestion: content.text("suggestion"),
            actionItem: try? content.value(GenActionItem?.self, forProperty: "actionItem"))
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: [
            "intent": intent, "correctionKind": correctionKind, "correctedText": correctedText,
            "contradictsLine": contradictsLine, "suggestion": suggestion, "actionItem": actionItem,
        ])
    }

    var raw: RawInsight {
        RawInsight(
            intent: intent.rawValue, correctionKind: correctionKind.rawValue, correctedText: correctedText,
            contradictsLine: contradictsLine, suggestion: suggestion, actionItem: actionItem?.raw)
    }
}

// MARK: - Report notes (one shape for a single pass, per-part notes and merged notes)

/// Transcript line numbers an item cites, listed after the item.
@available(macOS 26.0, *)
private func linesProperty(_ description: String = "Numbers of the transcript lines that support it (3 for L3).") -> GenerationSchema.Property {
    .init(name: "lines", description: description, type: [Int].self, guides: [.maximumCount(4)])
}

/// A list entry with the transcript lines that support it.
@available(macOS 26.0, *)
struct GenItem: Generable, Equatable {
    var text: String
    var lines: [Int]

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, properties: [
            .init(name: "text", description: "In your own words, briefly.", type: String.self), linesProperty(),
        ])
    }

    init(text: String, lines: [Int]) {
        self.text = text
        self.lines = lines
    }

    init(_ content: GeneratedContent) throws {
        guard let text = content.text("text") else { throw malformed("item", content) }
        self.init(text: text, lines: content.list("lines"))
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["text": text, "lines": lines])
    }

    var raw: RawItem { RawItem(text: text, lines: lines) }
}

@available(macOS 26.0, *)
struct GenNoteActionItem: Generable, Equatable {
    var task: String
    var owner: String?
    var due: String?
    var lines: [Int]

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, properties: [
            .init(name: "task", description: "Short imperative task.", type: String.self),
            .init(name: "owner", description: "Name of the person who will do it.", type: String?.self),
            .init(name: "due", description: "Deadline words someone said, like \"Friday\"; null if none. Never a mm:ss timestamp.", type: String?.self),
            linesProperty("Numbers of the lines where it was committed to or asked for."),
        ])
    }

    init(_ content: GeneratedContent) throws {
        guard let task = content.text("task") else { throw malformed("action item", content) }
        self.task = task
        owner = content.text("owner")
        due = content.text("due")
        lines = content.list("lines")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["task": task, "owner": owner, "due": due, "lines": lines])
    }

    var raw: RawActionItem { RawActionItem(task: task, owner: owner, due: due, lines: lines) }
}

@available(macOS 26.0, *)
struct GenTopic: Generable, Equatable {
    var title: String
    var summary: String
    var speakers: [String]

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, properties: [
            .init(name: "title", type: String.self),
            .init(name: "summary", description: "Several sentences: what was said and by whom, numbers, outcome.", type: String.self),
            .init(name: "speakers", type: [String].self, guides: [.maximumCount(6)]),
        ])
    }

    init(_ content: GeneratedContent) throws {
        guard let title = content.text("title") else { throw malformed("topic", content) }
        self.title = title
        summary = content.text("summary") ?? ""
        speakers = content.list("speakers")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["title": title, "summary": summary, "speakers": speakers])
    }
}

/// Kind of a report correction (no `none`: an entry exists only for an actual correction).
@available(macOS 26.0, *)
enum GenReportCorrectionKind: String, CaseIterable, Generable {
    case selfCorrection
    case contradiction
    case mishearing

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, description: "Kind of correction.", anyOf: allCases.map(\.rawValue))
    }

    init(_ content: GeneratedContent) throws {
        guard let value = Self(rawValue: try content.value(String.self)) else { throw malformed("correction kind", content) }
        self = value
    }

    var generatedContent: GeneratedContent { GeneratedContent(rawValue) }
}

@available(macOS 26.0, *)
struct GenCorrection: Generable, Equatable {
    var kind: GenReportCorrectionKind
    var speaker: String
    var original: String
    var corrected: String
    var lines: [Int]

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, properties: [
            .init(name: "kind", type: GenReportCorrectionKind.self),
            .init(name: "speaker", type: String.self),
            .init(name: "original", description: "Original wording.", type: String.self),
            .init(name: "corrected", description: "Corrected wording.", type: String.self),
            linesProperty("The corrected line; for a contradiction also the line it contradicts."),
        ])
    }

    init(_ content: GeneratedContent) throws {
        guard let original = content.text("original"), let corrected = content.text("corrected"),
            let kind = try? content.value(GenReportCorrectionKind.self, forProperty: "kind")
        else { throw malformed("correction", content) }
        lines = content.list("lines")
        self.kind = kind
        speaker = content.text("speaker") ?? ""
        self.original = original
        self.corrected = corrected
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["kind": kind, "speaker": speaker, "original": original, "corrected": corrected, "lines": lines])
    }

    var raw: RawCorrection {
        RawCorrection(speaker: speaker.isEmpty ? nil : speaker, kind: kind.rawValue, original: original, corrected: corrected, lines: lines)
    }
}

@available(macOS 26.0, *)
struct GenParticipant: Generable, Equatable {
    var name: String
    var keyPoints: [GenItem]

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, properties: [
            .init(name: "name", type: String.self),
            .init(
                name: "keyPoints", description: "What this person said, citing their own lines; promises stay promises.",
                type: [GenItem].self, guides: [.maximumCount(4)]),
        ])
    }

    init(_ content: GeneratedContent) throws {
        guard let name = content.text("name") else { throw malformed("participant", content) }
        self.name = name
        keyPoints = content.list("keyPoints")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["name": name, "keyPoints": keyPoints])
    }
}

/// The overview as paragraphs: asked for as a list with a paragraph count, the model writes as many as asked; asked
/// for as one string, it writes one or two sentences whatever the instructions say.
@available(macOS 26.0, *)
private func overviewProperty(paragraphs: ClosedRange<Int>) -> GenerationSchema.Property {
    .init(
        name: "overview",
        description: "The overview, one paragraph per entry: what the meeting was for, what was discussed and who argued what, numbers and dates, how it ended.",
        type: [String].self, guides: [.count(paragraphs)])
}

@available(macOS 26.0, *)
extension GeneratedContent {
    /// Paragraphs of an overview list, blank ones dropped, joined by blank lines. Numbering the model adds ("[1]
    /// …", "… [2] …") marks paragraph starts, never content.
    fileprivate func paragraphs(_ key: String) -> String {
        list(key, of: String.self)
            .flatMap { $0.replacingOccurrences(of: #"\s*\[\d+\]\s+"#, with: "\n", options: .regularExpression).components(separatedBy: "\n") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

/// The summary half of a part's notes: title, topics, overview (after the topics it sums up) and each
/// participant's key points. A merge answers in the same shape, without participants (their points are joined
/// from the parts) and with room for more topics.
@available(macOS 26.0, *)
struct GenSummary: Generable, Equatable {
    var title: String
    var topics: [GenTopic]
    /// Paragraphs separated by blank lines.
    var overview: String
    var participantSummaries: [GenParticipant]

    /// The schema asking for `paragraphs` overview paragraphs: one for a thin meeting, several for one with
    /// substance.
    static func schema(paragraphs: ClosedRange<Int>) -> GenerationSchema {
        GenerationSchema(type: Self.self, description: "Meeting summary.", properties: [
            .init(name: "title", description: "Short title.", type: String.self),
            .init(name: "topics", type: [GenTopic].self, guides: [.maximumCount(5)]),
            overviewProperty(paragraphs: paragraphs),
            .init(name: "participantSummaries", type: [GenParticipant].self, guides: [.maximumCount(8)]),
        ])
    }

    /// The answer of a merge: a whole long meeting's title, topics and overview.
    static var mergeSchema: GenerationSchema {
        GenerationSchema(type: Self.self, description: "Meeting summary.", properties: [
            .init(name: "title", description: "Short title.", type: String.self),
            .init(name: "topics", type: [GenTopic].self, guides: [.maximumCount(8)]),
            overviewProperty(paragraphs: 2...4),
        ])
    }

    static var generationSchema: GenerationSchema { schema(paragraphs: 1...4) }

    init(_ content: GeneratedContent) throws {
        title = content.text("title") ?? ""
        topics = content.list("topics")
        overview = content.paragraphs("overview")
        participantSummaries = content.list("participantSummaries")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: [
            "title": title, "topics": topics, "overview": overview.components(separatedBy: "\n\n"),
            "participantSummaries": participantSummaries,
        ])
    }

    var raw: RawReport {
        RawReport(
            title: title.isEmpty ? nil : title,
            overview: overview.isEmpty ? nil : overview,
            topics: topics.map { RawTopic(title: $0.title, summary: $0.summary, speakers: $0.speakers) },
            participantSummaries: participantSummaries.map { RawParticipant(name: $0.name, keyPoints: $0.keyPoints.map(\.raw)) })
    }
}

/// The list half of a part's notes.
@available(macOS 26.0, *)
struct GenLists: Generable, Equatable {
    var decisions: [GenItem]
    var actionItems: [GenNoteActionItem]
    var notesToRemember: [GenItem]
    var missedOpportunities: [String]
    var openQuestions: [GenItem]
    var corrections: [GenCorrection]

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, description: "Meeting lists. Empty lists are normal.", properties: [
            .init(name: "decisions", description: "Explicitly agreed decisions only.", type: [GenItem].self, guides: [.maximumCount(6)]),
            .init(name: "actionItems", description: "Tasks for after the meeting only.", type: [GenNoteActionItem].self, guides: [.maximumCount(8)]),
            .init(name: "notesToRemember", description: "Facts, numbers, dates, constraints.", type: [GenItem].self, guides: [.maximumCount(6)]),
            .init(name: "missedOpportunities", description: "Important follow-ups nobody raised.", type: [String].self, guides: [.maximumCount(3)]),
            .init(name: "openQuestions", description: "Questions asked and left unanswered.", type: [GenItem].self, guides: [.maximumCount(4)]),
            .init(name: "corrections", type: [GenCorrection].self, guides: [.maximumCount(3)]),
        ])
    }

    init(_ content: GeneratedContent) throws {
        decisions = content.list("decisions")
        actionItems = content.list("actionItems")
        notesToRemember = content.list("notesToRemember")
        missedOpportunities = content.list("missedOpportunities")
        openQuestions = content.list("openQuestions")
        corrections = content.list("corrections")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: [
            "decisions": decisions, "actionItems": actionItems, "notesToRemember": notesToRemember,
            "missedOpportunities": missedOpportunities, "openQuestions": openQuestions, "corrections": corrections,
        ])
    }

    /// Both halves as one set of notes.
    func notes(with summary: GenSummary) -> RawReport {
        var notes = summary.raw
        notes.decisions = decisions.map(\.raw)
        notes.actionItems = actionItems.map(\.raw)
        notes.notesToRemember = notesToRemember.map(\.raw)
        notes.missedOpportunities = missedOpportunities
        notes.openQuestions = openQuestions.map(\.raw)
        notes.corrections = corrections.map(\.raw)
        return notes
    }
}

// MARK: - Conversation outline (map step on Apple Intelligence)

@available(macOS 26.0, *)
struct GenOutlinePoint: Generable, Equatable {
    var speaker: String
    var text: String
    var lines: [Int]

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, properties: [
            .init(name: "speaker", description: "Name of the speaker.", type: String.self),
            .init(name: "text", description: "One specific thing they said, in your own words, without their name.", type: String.self),
            linesProperty("Numbers of that speaker's own lines that say it."),
        ])
    }

    init(_ content: GeneratedContent) throws {
        guard let text = content.text("text") else { throw malformed("outline point", content) }
        self.text = text
        speaker = content.text("speaker") ?? ""
        lines = content.list("lines")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["speaker": speaker, "text": text, "lines": lines])
    }

    var raw: RawOutlinePoint { RawOutlinePoint(speaker: speaker.isEmpty ? nil : speaker, text: text, lines: lines) }
}

@available(macOS 26.0, *)
struct GenOutlineSegment: Generable, Equatable {
    var heading: String
    var points: [GenOutlinePoint]

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, properties: [
            .init(name: "heading", description: "A few words naming what this stretch is about.", type: String.self),
            .init(name: "points", description: "Two to six points, in order.", type: [GenOutlinePoint].self, guides: [.maximumCount(6)]),
        ])
    }

    init(_ content: GeneratedContent) throws {
        heading = content.text("heading") ?? ""
        points = content.list("points")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["heading": heading, "points": points])
    }

    var raw: RawOutlineSegment { RawOutlineSegment(heading: heading.isEmpty ? nil : heading, points: points.map(\.raw)) }
}

/// The outline of one transcript chunk; kept verbatim (after grounding) in the final report.
@available(macOS 26.0, *)
struct GenOutline: Generable, Equatable {
    var segments: [GenOutlineSegment]

    /// At most four segments of six points keep the answer inside `AppleIntelligenceEngine.outlineResponseReserve`.
    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, description: "What was discussed, in order.", properties: [
            .init(name: "segments", description: "A new segment where the subject changes.", type: [GenOutlineSegment].self, guides: [.maximumCount(4)]),
        ])
    }

    init(_ content: GeneratedContent) throws {
        segments = content.list("segments")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["segments": segments])
    }

    var raw: [RawOutlineSegment] { segments.map(\.raw) }
}
