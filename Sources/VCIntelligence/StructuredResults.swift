import Foundation
import VCModels

// Engine-neutral structured output. Claude's tool input decodes straight into these (leniently, so a
// slightly off-schema answer still yields everything usable); Apple's Generable output converts into them.
// Both engines then go through the same clean-up and grounding checks into VCModels types.

/// What kind of slip a correction fixes. Anything that fits none of these is not shown as a correction.
enum CorrectionKind: String, CaseIterable, Equatable {
    /// The speaker repaired their own words ("Tuesday, sorry, I mean Wednesday").
    case selfCorrection
    /// The line contradicts an earlier line.
    case contradiction
    /// Speech recognition got a word wrong ("last weak").
    case mishearing

    /// Case- and punctuation-insensitive; "none" and unknown kinds read as nil.
    init?(lenient text: String?) {
        let key = (text ?? "").lowercased().filter(\.isLetter)
        guard let kind = Self.allCases.first(where: { $0.rawValue.lowercased() == key }) else { return nil }
        self = kind
    }
}

/// A report list entry with the transcript lines (1-based `L` numbers) that support it.
struct RawItem: Decodable, Equatable {
    var text: String?
    var lines: [Int]

    init(text: String?, lines: [Int] = []) {
        self.text = text
        self.lines = lines
    }

    /// `{"text": …, "lines": […]}`, or a bare string citing nothing.
    init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.init(text: trimmed.isEmpty ? nil : trimmed)
            return
        }
        let c = try decoder.container(keyedBy: AnyKey.self)
        self.init(text: c.lenientString("text"), lines: c.lenientLines("lines"))
    }
}

struct RawActionItem: Decodable, Equatable {
    var task: String?
    var owner: String?
    var due: String?
    /// Transcript lines where the task was committed to or asked for (reports only).
    var lines: [Int]

    init(task: String?, owner: String?, due: String?, lines: [Int] = []) {
        self.task = task
        self.owner = owner
        self.due = due
        self.lines = lines
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        task = c.lenientString("task")
        owner = c.lenientString("owner")
        due = c.lenientString("due")
        lines = c.lenientLines("lines")
    }
}

struct RawInsight: Decodable, Equatable {
    var intent: String?
    var correctionKind: String?
    var correctedText: String?
    /// Number of the context line a contradiction contradicts.
    var contradictsLine: Int?
    var suggestion: String?
    var actionItem: RawActionItem?

    init(
        intent: String?, correctionKind: String? = nil, correctedText: String?, contradictsLine: Int? = nil,
        suggestion: String?, actionItem: RawActionItem?
    ) {
        self.intent = intent
        self.correctionKind = correctionKind
        self.correctedText = correctedText
        self.contradictsLine = contradictsLine
        self.suggestion = suggestion
        self.actionItem = actionItem
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        intent = c.lenientString("intent")
        correctionKind = c.lenientString("correctionKind")
        correctedText = c.lenientString("correctedText")
        contradictsLine = c.lenientLines("contradictsLine").first
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
    var kind: String?
    var original: String?
    var corrected: String?
    /// The corrected line, plus for a contradiction the line it contradicts.
    var lines: [Int]

    init(speaker: String?, kind: String?, original: String?, corrected: String?, lines: [Int]) {
        self.speaker = speaker
        self.kind = kind
        self.original = original
        self.corrected = corrected
        self.lines = lines
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        speaker = c.lenientString("speaker")
        kind = c.lenientString("kind")
        original = c.lenientString("original")
        corrected = c.lenientString("corrected")
        lines = c.lenientLines("lines")
    }
}

struct RawParticipant: Decodable, Equatable {
    var name: String?
    /// Each point cites the participant's own lines.
    var keyPoints: [RawItem]

    init(name: String?, keyPoints: [RawItem]) {
        self.name = name
        self.keyPoints = keyPoints
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        name = c.lenientString("name")
        keyPoints = c.lossyArray("keyPoints")
    }
}

/// One outline point: what one speaker said, citing that speaker's lines.
struct RawOutlinePoint: Decodable, Equatable {
    var speaker: String?
    var text: String?
    var lines: [Int]

    init(speaker: String?, text: String?, lines: [Int]) {
        self.speaker = speaker
        self.text = text
        self.lines = lines
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        speaker = c.lenientString("speaker")
        text = c.lenientString("text")
        lines = c.lenientLines("lines")
    }
}

/// One stretch of the conversation outline.
struct RawOutlineSegment: Decodable, Equatable {
    var heading: String?
    var points: [RawOutlinePoint]

    init(heading: String?, points: [RawOutlinePoint]) {
        self.heading = heading
        self.points = points
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        heading = c.lenientString("heading")
        points = c.lossyArray("points")
    }
}

struct RawReport: Decodable, Equatable {
    var title: String?
    var overview: String?
    var topics: [RawTopic]
    var decisions: [RawItem]
    var actionItems: [RawActionItem]
    var notesToRemember: [RawItem]
    var missedOpportunities: [String]
    var openQuestions: [RawItem]
    var corrections: [RawCorrection]
    var participantSummaries: [RawParticipant]
    var outline: [RawOutlineSegment]

    init(
        title: String? = nil, overview: String? = nil, topics: [RawTopic] = [], decisions: [RawItem] = [],
        actionItems: [RawActionItem] = [], notesToRemember: [RawItem] = [], missedOpportunities: [String] = [],
        openQuestions: [RawItem] = [], corrections: [RawCorrection] = [], participantSummaries: [RawParticipant] = [],
        outline: [RawOutlineSegment] = []
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
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        title = c.lenientString("title")
        overview = c.lenientString("overview")
        topics = c.lossyArray("topics")
        decisions = c.lossyArray("decisions")
        actionItems = c.lossyArray("actionItems")
        notesToRemember = c.lossyArray("notesToRemember")
        missedOpportunities = c.lenientStrings("missedOpportunities")
        openQuestions = c.lossyArray("openQuestions")
        corrections = c.lossyArray("corrections")
        participantSummaries = c.lossyArray("participantSummaries")
        outline = c.lossyArray("outline")
    }
}

// MARK: - Clean-up into VCModels types

enum ResultAssembler {
    /// Intents under which an utterance can carry a task. On other lines (statements, thanks, decisions already
    /// made) small models invent tasks, contradicting the intent they chose themselves.
    private static let taskIntents: Set<UtteranceIntent> = [.commitment, .request, .proposal]

    /// `context` is the numbered recent context the model saw (`L1` is `context[0]`); a due date must have been
    /// spoken there or in the utterance, and a contradiction must cite one of its lines.
    static func insight(from raw: RawInsight, utterance: ContextLine, context: [ContextLine] = []) -> UtteranceInsight {
        let intent = Self.intent(from: raw.intent)
        let correction = raw.correctedText.flatMap { text -> (text: String, reason: String)? in
            let corrected = unquoted(text)
            guard !corrected.isEmpty, let kind = CorrectionKind(lenient: raw.correctionKind) else { return nil }
            let contradicted = raw.contradictsLine.flatMap { context.indices.contains($0 - 1) ? context[$0 - 1] : nil }
            return correctionReason(kind, original: utterance.text, corrected: corrected, line: utterance, contradicted: contradicted)
                .map { (corrected, $0) }
        }
        let spoken = comparable(([utterance] + context).map(\.text).joined(separator: " "))
        let cues = Grounding.taskCues(utterance.text)
        let action = raw.actionItem.flatMap { item -> ActionItem? in
            let body = item.task.map { labelled($0).body } ?? ""
            guard taskIntents.contains(intent), !cues.isEmpty, !comparable(body).isEmpty else { return nil }
            var owner = resolveOwner(item.owner, speaker: utterance.speaker)
            // Whoever asks is not the one who does it; the person named in the request is.
            let ownerIsSpeaker = owner?.caseInsensitiveCompare(utterance.speaker) == .orderedSame
            if cues.contains(.request), !cues.contains(.commitment), owner == nil || ownerIsSpeaker {
                owner = addressee(of: utterance, among: context.map(\.speaker))
            }
            let due = item.due.flatMap { groundedDue($0, spoken: spoken) } ?? Grounding.deadline(in: utterance.text)
            return ActionItem(task: body, owner: owner, due: due, sourceSegmentID: utterance.segmentID)
        }
        return UtteranceInsight(
            intent: intent,
            correctedText: correction?.text,
            correctionReason: correction?.reason,
            suggestion: raw.suggestion.flatMap(meaningfulSuggestion).flatMap { echoes($0, utterance.text) ? nil : $0 },
            actionItem: action)
    }

    /// The other participant named in a request ("Samantha, can you…"): the only one named, or else the only
    /// one named before the request itself ("Leo, can you estimate it once Priya's designs are ready?"); nil
    /// when that is still ambiguous or nobody is named.
    static func addressee(of utterance: ContextLine, among speakers: [String]) -> String? {
        let said = words(utterance.text)
        var named: [(speaker: String, at: Int)] = []
        for speaker in speakers where speaker.caseInsensitiveCompare(utterance.speaker) != .orderedSame {
            let name = words(speaker)
            guard !name.isEmpty, !named.contains(where: { $0.speaker == speaker }),
                let end = Grounding.ends(of: name, in: said).first
            else { continue }
            named.append((speaker, end - name.count))
        }
        if named.count == 1 { return named[0].speaker }
        let request = Grounding.requestCues.flatMap { cue in Grounding.ends(of: cue, in: said).map { $0 - cue.count } }.min()
        let beforeRequest = named.filter { name in request.map { name.at < $0 } ?? false }
        return beforeRequest.count == 1 ? beforeRequest[0].speaker : nil
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

    /// The user-facing reason for correcting `original` (a stretch of `line`, or all of it) to `corrected`, or nil
    /// when the correction is not one of the three kinds. The reason comes from the kind, never from the model.
    /// Edits that only drop fillers, hesitations or repeated words are never corrections.
    static func correctionReason(
        _ kind: CorrectionKind, original: String, corrected: String, line: ContextLine, contradicted: ContextLine?
    ) -> String? {
        guard isGenuineCorrection(corrected, of: line.text), Grounding.fluent(corrected) != Grounding.fluent(original),
            Grounding.fluent(corrected) != Grounding.fluent(line.text)
        else { return nil }
        switch kind {
        case .selfCorrection:
            guard isRepair(corrected, in: line.text) else { return nil }
            let speaker = line.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
            return speaker.isEmpty ? "Corrected themselves" : "\(speaker) corrected themselves"
        case .contradiction:
            guard let contradicted, contradicted != line, contradicts(corrected, said: line.text, cited: contradicted.text)
            else { return nil }
            let speaker = contradicted.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
            let when = TranscriptFormatter.timestamp(contradicted.time)
            return speaker.isEmpty ? "Contradicts \(when)" : "Contradicts \(when) (\(speaker))"
        case .mishearing:
            return isLikelyMishearing(corrected, of: original) ? "Probably misheard" : nil
        }
    }

    /// The speaker repaired themselves and `corrected` comes from the repair: the line has a repair cue with
    /// replaced words before it ("Tuesday the fourteenth, sorry, I mean…") and `corrected` takes its new words
    /// from after the cue, adding nothing the speaker did not say.
    static func isRepair(_ corrected: String, in line: String) -> Bool {
        let fixed = Grounding.contentStems(corrected)
        let said = words(line)
        let saidStems = Grounding.contentStems(line)
        guard !fixed.isEmpty, fixed.allSatisfy({ word in saidStems.contains { Grounding.related(word, $0) } }) else { return false }
        for cue in repairCues {
            for end in Grounding.ends(of: cue, in: said) {
                let start = end - cue.count
                let replaced = Grounding.contentStems(said[max(0, start - 6)..<start].joined(separator: " "))
                let repair = Grounding.contentStems(said[end...].joined(separator: " "))
                let fromRepair = fixed.contains { word in
                    repair.contains { Grounding.related(word, $0) } && !replaced.contains { Grounding.related(word, $0) }
                }
                let dropsSomething = replaced.contains { word in !fixed.contains { Grounding.related(word, $0) } }
                if fromRepair, dropsSomething { return true }
            }
        }
        return false
    }

    /// `corrected` restates `cited`: its words that the speaker did not say all come from the cited line, and the
    /// speaker and the cited line talk about the same thing.
    static func contradicts(_ corrected: String, said: String, cited: String) -> Bool {
        let saidStems = Grounding.contentStems(said)
        let citedStems = Grounding.contentStems(cited)
        let added = Grounding.contentStems(corrected).filter { word in !saidStems.contains { Grounding.related(word, $0) } }
        return !added.isEmpty
            && added.allSatisfy { word in citedStems.contains { Grounding.related(word, $0) } }
            && saidStems.contains { word in citedStems.contains { Grounding.related(word, $0) } }
    }

    /// A likely recognition error: one stretch of at most three words swapped for a similar-length stretch that
    /// sounds alike ("last weak" → "last week"), the rest unchanged.
    static func isLikelyMishearing(_ corrected: String, of original: String) -> Bool {
        let said = Grounding.fluent(original)
        let fixed = Grounding.fluent(corrected)
        let prefix = zip(said, fixed).prefix { $0 == $1 }.count
        let suffix = zip(said.dropFirst(prefix).reversed(), fixed.dropFirst(prefix).reversed()).prefix { $0 == $1 }.count
        let heard = said[prefix..<(said.count - suffix)]
        let meant = fixed[prefix..<(fixed.count - suffix)]
        guard !heard.isEmpty, !meant.isEmpty, heard.count <= 3, meant.count <= 3, abs(heard.count - meant.count) <= 1
        else { return false }
        return Grounding.soundsAlike(heard.joined(), meant.joined())
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

    /// A suggestion that only repeats the utterance ("Clarify: Can you introduce yourself?").
    static func echoes(_ suggestion: String, _ utterance: String) -> Bool {
        Grounding.fluent(labelled(suggestion).body) == Grounding.fluent(utterance)
    }

    /// Lowercased alphanumeric words.
    static func words(_ text: String) -> [String] {
        Grounding.words(text)
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

    static func deduplicated(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { !comparable($0).isEmpty && seen.insert(comparable($0)).inserted }
    }

    static func unquoted(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’").union(.whitespaces))
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

/// A cited line as a number (3) or a label ("L3", "lines 3 and 4"); null or anything else cites nothing.
private struct LineLabel: Decodable {
    var numbers: [Int]

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let number = try? c.decode(Double.self), number.isFinite, number >= 1, number < 1_000_000 {
            numbers = [Int(number)]
        } else if let text = try? c.decode(String.self) {
            numbers = text.split { !$0.isNumber }.compactMap { Int($0) }
        } else {
            numbers = []
        }
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

    /// Cited line numbers: numbers or "L3"-style labels, as an array or a single value ("L3, L5"); every digit run
    /// counts once.
    func lenientLines(_ key: String) -> [Int] {
        let labels: [LineLabel]
        if let many = try? decodeIfPresent([LineLabel].self, forKey: AnyKey(key)) {
            labels = many
        } else if let one = try? decodeIfPresent(LineLabel.self, forKey: AnyKey(key)) {
            labels = [one]
        } else {
            labels = []
        }
        return labels.flatMap(\.numbers)
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
