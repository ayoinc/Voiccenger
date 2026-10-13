import Foundation
import VCModels

// Engine-neutral structured output. Claude's tool input decodes straight into these (leniently, so a
// slightly off-schema answer still yields everything usable); Apple's @Generable output converts into them.
// Both engines then go through the same clean-up into VCModels types.

struct RawActionItem: Decodable, Equatable {
    var task: String?
    var owner: String?
    var due: String?
    /// `mm:ss` of the line where the task came up (reports only).
    var timestamp: String?

    init(task: String?, owner: String?, due: String?, timestamp: String? = nil) {
        self.task = task
        self.owner = owner
        self.due = due
        self.timestamp = timestamp
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        task = c.lenientString("task")
        owner = c.lenientString("owner")
        due = c.lenientString("due")
        timestamp = c.lenientString("timestamp")
    }
}

struct RawInsight: Decodable, Equatable {
    var intent: String?
    var correctedText: String?
    var correctionReason: String?
    var suggestion: String?
    var actionItem: RawActionItem?

    init(intent: String?, correctedText: String?, correctionReason: String?, suggestion: String?, actionItem: RawActionItem?) {
        self.intent = intent
        self.correctedText = correctedText
        self.correctionReason = correctionReason
        self.suggestion = suggestion
        self.actionItem = actionItem
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        intent = c.lenientString("intent")
        correctedText = c.lenientString("correctedText")
        correctionReason = c.lenientString("correctionReason")
        suggestion = c.lenientString("suggestion")
        actionItem = (try? c.decodeIfPresent(RawActionItem.self, forKey: AnyKey("actionItem"))) ?? nil
    }
}

struct RawTopic: Decodable, Equatable {
    var title: String?
    var summary: String?
    var speakers: [String]

    init(title: String?, summary: String?, speakers: [String]) {
        self.title = title
        self.summary = summary
        self.speakers = speakers
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        title = c.lenientString("title")
        summary = c.lenientString("summary")
        speakers = c.lenientStrings("speakers")
    }
}

struct RawCorrection: Decodable, Equatable {
    var speaker: String?
    var original: String?
    var corrected: String?
    var reason: String?

    init(speaker: String?, original: String?, corrected: String?, reason: String?) {
        self.speaker = speaker
        self.original = original
        self.corrected = corrected
        self.reason = reason
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        speaker = c.lenientString("speaker")
        original = c.lenientString("original")
        corrected = c.lenientString("corrected")
        reason = c.lenientString("reason")
    }
}

struct RawParticipant: Decodable, Equatable {
    var name: String?
    var keyPoints: [String]

    init(name: String?, keyPoints: [String]) {
        self.name = name
        self.keyPoints = keyPoints
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        name = c.lenientString("name")
        keyPoints = c.lenientStrings("keyPoints")
    }
}

struct RawReport: Decodable, Equatable {
    var title: String?
    var overview: String?
    var topics: [RawTopic]
    var decisions: [String]
    var actionItems: [RawActionItem]
    var notesToRemember: [String]
    var missedOpportunities: [String]
    var openQuestions: [String]
    var corrections: [RawCorrection]
    var participantSummaries: [RawParticipant]

    init(
        title: String?, overview: String?, topics: [RawTopic], decisions: [String], actionItems: [RawActionItem],
        notesToRemember: [String], missedOpportunities: [String], openQuestions: [String],
        corrections: [RawCorrection], participantSummaries: [RawParticipant]
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
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        title = c.lenientString("title")
        overview = c.lenientString("overview")
        topics = c.lossyArray("topics")
        decisions = c.lenientStrings("decisions")
        actionItems = c.lossyArray("actionItems")
        notesToRemember = c.lenientStrings("notesToRemember")
        missedOpportunities = c.lenientStrings("missedOpportunities")
        openQuestions = c.lenientStrings("openQuestions")
        corrections = c.lossyArray("corrections")
        participantSummaries = c.lossyArray("participantSummaries")
    }
}

// MARK: - Clean-up into VCModels types

enum ResultAssembler {
    /// Intents under which an utterance can carry a task. On other lines (statements, thanks, decisions already
    /// made) small models invent tasks, contradicting the intent they chose themselves.
    private static let taskIntents: Set<UtteranceIntent> = [.commitment, .request, .proposal]

    /// `context` is the recent context the model saw; a due date must have been spoken there or in the utterance.
    static func insight(from raw: RawInsight, utterance: ContextLine, context: [ContextLine] = []) -> UtteranceInsight {
        let intent = Self.intent(from: raw.intent)
        let corrected = raw.correctedText.flatMap { text -> String? in
            let unquoted = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’").union(.whitespaces))
            guard !unquoted.isEmpty, isGenuineCorrection(unquoted, of: utterance.text) else { return nil }
            return unquoted
        }
        let spoken = comparable(([utterance] + context).map(\.text).joined(separator: " "))
        let action = raw.actionItem.flatMap { item -> ActionItem? in
            let body = item.task.map { labelled($0).body } ?? ""
            guard taskIntents.contains(intent), !comparable(body).isEmpty else { return nil }
            var owner = resolveOwner(item.owner, speaker: utterance.speaker)
            if intent == .request, owner == nil || owner?.caseInsensitiveCompare(utterance.speaker) == .orderedSame {
                owner = addressee(of: utterance, among: context.map(\.speaker)) ?? owner
            }
            return ActionItem(
                task: body, owner: owner, due: item.due.flatMap { groundedDue($0, spoken: spoken) },
                sourceSegmentID: utterance.segmentID)
        }
        return UtteranceInsight(
            intent: intent,
            correctedText: corrected,
            correctionReason: corrected == nil ? nil : raw.correctionReason,
            suggestion: raw.suggestion.flatMap(meaningfulSuggestion),
            actionItem: action)
    }

    /// The one other participant named in a request ("Samantha, can you…"); nil when none or several are.
    static func addressee(of utterance: ContextLine, among speakers: [String]) -> String? {
        let said = words(utterance.text)
        var named: [String] = []
        for speaker in speakers where speaker.caseInsensitiveCompare(utterance.speaker) != .orderedSame {
            let name = words(speaker)
            guard !name.isEmpty, name.count <= said.count, !named.contains(speaker),
                (0...(said.count - name.count)).contains(where: { Array(said[$0..<($0 + name.count)]) == name })
            else { continue }
            named.append(speaker)
        }
        return named.count == 1 ? named[0] : nil
    }

    /// Words that signal a speaker repairing what they just said ("Tuesday, sorry, I mean Wednesday").
    private static let repairCues: [[String]] = [
        ["sorry"], ["i", "mean"], ["i", "meant"], ["rather"], ["no"], ["correction"], ["scratch", "that"],
        ["make", "that"], ["actually"], ["wait"], ["pardon"], ["that", "is"], ["i", "should", "say"],
    ]

    /// A correction must change what was said. Text identical to the utterance, or to a stretch of it, only
    /// counts when that stretch is the speaker's own repair (directly preceded by a cue such as "sorry, I mean");
    /// otherwise the model has merely repeated correct speech.
    static func isGenuineCorrection(_ corrected: String, of utterance: String) -> Bool {
        let fixed = words(corrected)
        let said = words(utterance)
        guard !fixed.isEmpty, fixed != said else { return false }
        guard fixed.count < said.count else { return true }
        let starts = (0...(said.count - fixed.count)).filter { Array(said[$0..<($0 + fixed.count)]) == fixed }
        guard !starts.isEmpty else { return true }
        return starts.contains { start in
            let before = said[..<start]
            return repairCues.contains { cue in cue.count <= before.count && Array(before.suffix(cue.count)) == cue }
        }
    }

    private static let labels: Set<String> = ["propose", "confirm", "ask", "clarify", "suggest", "suggestion", "task"]

    /// Splits leading labels off `text`. Small models stack them ("Propose: Confirm: …"); the last one is kept.
    static func labelled(_ text: String) -> (label: String?, body: String) {
        var body = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var label: String?
        while let colon = body.firstIndex(of: ":") {
            let candidate = body[..<colon].trimmingCharacters(in: .whitespaces)
            guard labels.contains(candidate.lowercased()) else { break }
            label = candidate
            body = body[body.index(after: colon)...].drop(while: \.isWhitespace)
        }
        return (label, String(body))
    }

    /// Drops suggestions that are only a label ("Confirm:") and collapses stacked labels to the last one.
    static func meaningfulSuggestion(_ text: String) -> String? {
        let (label, body) = labelled(text)
        guard !comparable(body).isEmpty else { return nil }
        return label.map { "\($0): \(body)" } ?? body
    }

    /// Lowercased alphanumeric words.
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// A due date is kept only when it was actually said: clock labels ("00:34", "[01:05]") are transcript
    /// timestamps the model copied, and anything absent from `spoken` (a `comparable` form) was invented.
    static func groundedDue(_ due: String, spoken: String) -> String? {
        let trimmed = due.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = comparable(trimmed)
        guard !key.isEmpty, spoken.contains(key),
            trimmed.range(of: #"^\[?\d{1,2}:\d{2}(:\d{2})?\]?$"#, options: .regularExpression) == nil
        else { return nil }
        return trimmed
    }

    static func report(
        from raw: RawReport, transcript: [ContextLine], participants: [String], meetingTitle: String?,
        generatedBy: String, generatedAt: Date = Date()
    ) -> MeetingReport {
        let givenTitle = meetingTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (givenTitle?.isEmpty == false ? givenTitle : nil) ?? raw.title ?? "Meeting"

        var linesByTimestamp: [String: [ContextLine]] = [:]
        for line in transcript { linesByTimestamp[TranscriptFormatter.timestamp(line.time), default: []].append(line) }
        let spoken = comparable(transcript.map(\.text).joined(separator: " "))
        // A copy of a task may carry the deadline another copy omitted.
        var dueByTask: [String: String] = [:]
        for item in raw.actionItems {
            guard let task = item.task, dueByTask[comparable(task)] == nil, let due = item.due.flatMap({ groundedDue($0, spoken: spoken) })
            else { continue }
            dueByTask[comparable(task)] = due
        }

        // The same task may come back several times (small models repeat themselves); keep it once, owned by
        // whoever most of the copies name (earliest wins ties).
        var ownerVotes: [String: [String: Int]] = [:]
        var firstOwnerIndex: [String: [String: Int]] = [:]
        for (index, item) in raw.actionItems.enumerated() {
            guard let task = item.task, let owner = cleanedOwner(item.owner) else { continue }
            ownerVotes[comparable(task), default: [:]][owner, default: 0] += 1
            if firstOwnerIndex[comparable(task)]?[owner] == nil { firstOwnerIndex[comparable(task), default: [:]][owner] = index }
        }
        var seenTasks = Set<String>()
        let actionItems = raw.actionItems.compactMap { item -> ActionItem? in
            guard let task = item.task, seenTasks.insert(comparable(task)).inserted else { return nil }
            let votes = ownerVotes[comparable(task)] ?? [:]
            let firsts = firstOwnerIndex[comparable(task)] ?? [:]
            let favourite = votes.max { a, b in a.value != b.value ? a.value < b.value : firsts[a.key, default: 0] > firsts[b.key, default: 0] }?.key
            let claimedOwner = favourite ?? item.owner
            let candidates = item.timestamp.map { linesByTimestamp[normalizedTimestamp($0)] ?? [] } ?? []
            let ownerLine = candidates.first { $0.speaker.caseInsensitiveCompare(claimedOwner ?? "") == .orderedSame }
            let source = ownerLine ?? candidates.first
            let owner = source.map { resolveOwner(claimedOwner, speaker: $0.speaker) } ?? cleanedOwner(claimedOwner)
            return ActionItem(task: task, owner: owner, due: dueByTask[comparable(task)], sourceSegmentID: source?.segmentID)
        }

        let topics = raw.topics.compactMap { topic -> TopicSummary? in
            guard let title = topic.title else { return nil }
            return TopicSummary(title: title, summary: topic.summary ?? "", speakers: deduplicated(topic.speakers))
        }

        let corrections = raw.corrections.compactMap { note -> CorrectionNote? in
            guard let original = note.original, let corrected = note.corrected,
                comparable(original) != comparable(corrected)
            else { return nil }
            return CorrectionNote(speaker: note.speaker ?? "Unknown", original: original, corrected: corrected, reason: note.reason ?? "")
        }

        return MeetingReport(
            title: title,
            overview: raw.overview ?? "",
            topics: topics,
            decisions: deduplicated(raw.decisions),
            actionItems: actionItems,
            notesToRemember: deduplicated(raw.notesToRemember),
            missedOpportunities: deduplicated(raw.missedOpportunities),
            openQuestions: deduplicated(raw.openQuestions),
            corrections: corrections,
            participantSummaries: participantSummaries(raw.participantSummaries, participants: participants, transcript: transcript),
            generatedBy: generatedBy,
            generatedAt: generatedAt)
    }

    /// Known participants first, in their given order; each name once with its points merged.
    static func participantSummaries(_ raw: [RawParticipant], participants: [String], transcript: [ContextLine]) -> [ParticipantSummary] {
        var order: [String] = []
        var points: [String: [String]] = [:]
        var displayName: [String: String] = [:]
        for name in TranscriptFormatter.participantNames(participants: participants, transcript: transcript) {
            let key = name.lowercased()
            order.append(key)
            displayName[key] = name
        }
        for entry in raw {
            guard let name = entry.name else { continue }
            let key = name.lowercased()
            if displayName[key] == nil {
                order.append(key)
                displayName[key] = name
            }
            points[key, default: []].append(contentsOf: entry.keyPoints)
        }
        return order.compactMap { key in
            let keyPoints = deduplicated(points[key] ?? [])
            guard !keyPoints.isEmpty, let name = displayName[key] else { return nil }
            return ParticipantSummary(name: name, keyPoints: keyPoints)
        }
    }

    static func intent(from text: String?) -> UtteranceIntent {
        let key = (text ?? "").lowercased().filter(\.isLetter)
        return UtteranceIntent.allCases.first { $0.rawValue.lowercased() == key } ?? .statement
    }

    /// First-person owners ("I", "me") are the speaker; vague owners ("we", "someone") are no owner at all.
    static func resolveOwner(_ owner: String?, speaker: String) -> String? {
        guard let owner = cleanedOwner(owner) else { return nil }
        let key = owner.lowercased()
        if ["i", "me", "myself", "speaker", "the speaker"].contains(key) {
            let name = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }
        return owner
    }

    static func cleanedOwner(_ owner: String?) -> String? {
        guard let owner = owner?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty else { return nil }
        let vague: Set<String> = ["we", "us", "you", "they", "someone", "somebody", "everyone", "team", "the team", "unknown", "unassigned", "tbd"]
        return vague.contains(owner.lowercased()) ? nil : owner
    }

    /// Accepts "1:05", "01:05", "[01:05]" or "1:05:00" style labels and returns the transcript's `mm:ss` form.
    static func normalizedTimestamp(_ text: String) -> String {
        let parts = text.filter { $0.isNumber || $0 == ":" }.split(separator: ":").compactMap { Int($0) }
        let seconds: Int
        switch parts.count {
        case 2: seconds = parts[0] * 60 + parts[1]
        case 3: seconds = parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return text
        }
        return TranscriptFormatter.timestamp(TimeInterval(seconds))
    }

    static func deduplicated(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { !comparable($0).isEmpty && seen.insert(comparable($0)).inserted }
    }

    /// Case-, punctuation- and spacing-insensitive form used to compare free text.
    static func comparable(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}

// MARK: - Lenient decoding

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// Consumes one element of any shape so a bad array element can be skipped.
private struct Skip: Decodable {
    init(from decoder: any Decoder) throws {}
}

extension KeyedDecodingContainer where Key == AnyKey {
    /// Trimmed string; numbers are stringified; empty, "null", "none" and "n/a" mean absent.
    func lenientString(_ key: String) -> String? {
        let key = AnyKey(key)
        let value: String?
        if let string = try? decodeIfPresent(String.self, forKey: key) {
            value = string
        } else if let number = try? decodeIfPresent(Double.self, forKey: key) {
            value = number.rounded() == number ? String(Int(number)) : String(number)
        } else {
            value = nil
        }
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return ["null", "none", "n/a", "nil"].contains(trimmed.lowercased()) ? nil : trimmed
    }

    /// Array of strings, a single string, or nothing; blank entries dropped.
    func lenientStrings(_ key: String) -> [String] {
        let key = AnyKey(key)
        if let strings = try? decodeIfPresent([String?].self, forKey: key) {
            return strings.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        if let single = lenientString(key.stringValue) { return [single] }
        return []
    }

    /// Decodes each element independently, skipping the ones that fail.
    func lossyArray<T: Decodable>(_ key: String) -> [T] {
        guard var container = try? nestedUnkeyedContainer(forKey: AnyKey(key)) else { return [] }
        var result: [T] = []
        while !container.isAtEnd {
            if let element = try? container.decode(T.self) {
                result.append(element)
            } else if (try? container.decode(Skip.self)) == nil {
                break
            }
        }
        return result
    }
}
