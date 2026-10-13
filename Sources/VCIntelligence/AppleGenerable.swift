import Foundation
import FoundationModels
import VCModels

// Guided-generation output types for the on-device model.
//
// These conform to `Generable` by hand, spelling out exactly what `@Generable`/`@Guide` expand to:
// the FoundationModels macro plugin ships with Xcode only, and this package builds with the Command
// Line Tools. Property order is generation order, so each type lists what the model should decide first.

private func malformed(_ type: String, _ content: GeneratedContent) -> IntelligenceError {
    .malformedResponse("unexpected \(type) content: \(content.jsonString.prefix(200))")
}

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

struct GenInsight: Generable, Equatable {
    var intent: GenIntent
    var correctedText: String?
    var correctionReason: String?
    var suggestion: String?
    var actionItem: GenActionItem?

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, description: "Analysis of the new utterance.", properties: [
            .init(name: "intent", type: GenIntent.self),
            .init(name: "correctedText", description: "What the speaker meant; only when the utterance is wrong.", type: String?.self),
            .init(name: "correctionReason", description: "Why the utterance was corrected.", type: String?.self),
            .init(name: "suggestion", description: "Propose:/Confirm:/Ask:/Clarify: line; only when genuinely useful.", type: String?.self),
            .init(name: "actionItem", description: "Only when someone commits to or is asked to do a task.", type: GenActionItem?.self),
        ])
    }

    init(intent: GenIntent, correctedText: String?, correctionReason: String?, suggestion: String?, actionItem: GenActionItem?) {
        self.intent = intent
        self.correctedText = correctedText
        self.correctionReason = correctionReason
        self.suggestion = suggestion
        self.actionItem = actionItem
    }

    init(_ content: GeneratedContent) throws {
        self.init(
            intent: try content.value(GenIntent.self, forProperty: "intent"),
            correctedText: content.text("correctedText"),
            correctionReason: content.text("correctionReason"),
            suggestion: content.text("suggestion"),
            actionItem: try? content.value(GenActionItem?.self, forProperty: "actionItem"))
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: [
            "intent": intent, "correctedText": correctedText, "correctionReason": correctionReason,
            "suggestion": suggestion, "actionItem": actionItem,
        ])
    }

    var raw: RawInsight {
        RawInsight(
            intent: intent.rawValue, correctedText: correctedText, correctionReason: correctionReason,
            suggestion: suggestion, actionItem: actionItem?.raw)
    }
}

// MARK: - Report notes (one shape for a single pass, per-part notes and merged notes)

struct GenNoteActionItem: Generable, Equatable {
    var task: String
    var owner: String?
    var due: String?
    var timestamp: String?

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, properties: [
            .init(name: "task", description: "Short imperative task.", type: String.self),
            .init(name: "owner", description: "Responsible person's name.", type: String?.self),
            .init(name: "timestamp", description: "mm:ss of the line where it was agreed.", type: String?.self),
            .init(name: "due", description: "Deadline words someone said, like \"Friday\"; null if none. Never a mm:ss timestamp.", type: String?.self),
        ])
    }

    init(_ content: GeneratedContent) throws {
        guard let task = content.text("task") else { throw malformed("action item", content) }
        self.task = task
        owner = content.text("owner")
        due = content.text("due")
        timestamp = content.text("timestamp")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["task": task, "owner": owner, "due": due, "timestamp": timestamp])
    }
}

struct GenTopic: Generable, Equatable {
    var title: String
    var summary: String
    var speakers: [String]

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, properties: [
            .init(name: "title", type: String.self),
            .init(name: "summary", description: "One or two sentences.", type: String.self),
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

struct GenCorrection: Generable, Equatable {
    var speaker: String
    var original: String
    var corrected: String
    var reason: String

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, properties: [
            .init(name: "speaker", type: String.self),
            .init(name: "original", description: "Original wording.", type: String.self),
            .init(name: "corrected", description: "Corrected meaning.", type: String.self),
            .init(name: "reason", type: String.self),
        ])
    }

    init(_ content: GeneratedContent) throws {
        guard let original = content.text("original"), let corrected = content.text("corrected") else {
            throw malformed("correction", content)
        }
        speaker = content.text("speaker") ?? ""
        self.original = original
        self.corrected = corrected
        reason = content.text("reason") ?? ""
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["speaker": speaker, "original": original, "corrected": corrected, "reason": reason])
    }
}

struct GenParticipant: Generable, Equatable {
    var name: String
    var keyPoints: [String]

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, properties: [
            .init(name: "name", type: String.self),
            .init(name: "keyPoints", type: [String].self, guides: [.maximumCount(4)]),
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

struct GenNotes: Generable, Equatable {
    var title: String
    var overview: String
    var topics: [GenTopic]
    var decisions: [String]
    var actionItems: [GenNoteActionItem]
    var notesToRemember: [String]
    var missedOpportunities: [String]
    var openQuestions: [String]
    var corrections: [GenCorrection]
    var participantSummaries: [GenParticipant]

    /// Caps keep the answer well inside the on-device context window.
    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, description: "Meeting notes.", properties: [
            .init(name: "title", description: "Short title.", type: String.self),
            .init(name: "overview", description: "Two to four sentences.", type: String.self),
            .init(name: "topics", type: [GenTopic].self, guides: [.maximumCount(6)]),
            .init(name: "decisions", type: [String].self, guides: [.maximumCount(8)]),
            .init(name: "actionItems", type: [GenNoteActionItem].self, guides: [.maximumCount(10)]),
            .init(name: "notesToRemember", description: "Facts, numbers, dates, caveats.", type: [String].self, guides: [.maximumCount(8)]),
            .init(name: "missedOpportunities", description: "What could have been said, asked or followed up.", type: [String].self, guides: [.maximumCount(5)]),
            .init(name: "openQuestions", type: [String].self, guides: [.maximumCount(5)]),
            .init(name: "corrections", type: [GenCorrection].self, guides: [.maximumCount(5)]),
            .init(name: "participantSummaries", type: [GenParticipant].self, guides: [.maximumCount(8)]),
        ])
    }

    init(_ content: GeneratedContent) throws {
        title = content.text("title") ?? ""
        overview = content.text("overview") ?? ""
        topics = content.list("topics")
        decisions = content.list("decisions")
        actionItems = content.list("actionItems")
        notesToRemember = content.list("notesToRemember")
        missedOpportunities = content.list("missedOpportunities")
        openQuestions = content.list("openQuestions")
        corrections = content.list("corrections")
        participantSummaries = content.list("participantSummaries")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: [
            "title": title, "overview": overview, "topics": topics, "decisions": decisions, "actionItems": actionItems,
            "notesToRemember": notesToRemember, "missedOpportunities": missedOpportunities, "openQuestions": openQuestions,
            "corrections": corrections, "participantSummaries": participantSummaries,
        ])
    }

    var raw: RawReport {
        RawReport(
            title: title.isEmpty ? nil : title,
            overview: overview.isEmpty ? nil : overview,
            topics: topics.map { RawTopic(title: $0.title, summary: $0.summary, speakers: $0.speakers) },
            decisions: decisions,
            actionItems: actionItems.map { RawActionItem(task: $0.task, owner: $0.owner, due: $0.due, timestamp: $0.timestamp) },
            notesToRemember: notesToRemember,
            missedOpportunities: missedOpportunities,
            openQuestions: openQuestions,
            corrections: corrections.map {
                RawCorrection(speaker: $0.speaker.isEmpty ? nil : $0.speaker, original: $0.original, corrected: $0.corrected, reason: $0.reason)
            },
            participantSummaries: participantSummaries.map { RawParticipant(name: $0.name, keyPoints: $0.keyPoints) })
    }
}
