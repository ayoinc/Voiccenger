import Foundation
import VCModels

// Report clean-up: every list item must cite transcript lines that support it. Shared by every engine.

extension ResultAssembler {
    /// Cleans the model's report and keeps only what the transcript supports: every list item must cite existing
    /// lines (`L1` is `transcript[0]`) that share content words with it and carry the right kind of speech act.
    /// Meetings with little substance get a brief report; others get lists capped by transcript length.
    /// `declined` lines were handled without AI: the outline quotes them, the lists add the questions and possible
    /// action items found in them by word cues, and an overview declined everywhere is the transcript overview.
    static func report(
        from raw: RawReport, transcript: [ContextLine], participants: [String], meetingTitle: String?,
        generatedBy: String, generatedAt: Date = Date(), declined: DeclinedLines = DeclinedLines()
    ) -> MeetingReport {
        let givenTitle = meetingTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (givenTitle?.isEmpty == false ? givenTitle : nil) ?? raw.title ?? "Meeting"
        let shape = ReportShape(Grounding.substance(transcript))
        let evidence = Evidence(transcript)

        var actionItems = Array(groundedActionItems(raw.actionItems, evidence: evidence).prefix(shape.actionItems))
        // A decision is a statement ("What's the budget?" is not one, whatever line it cites).
        let decisions = Array(groundedItems(raw.decisions, evidence: evidence) { text, lines in
            !text.contains("?") && lines.contains { Grounding.hasDecisionCue($0.text) }
                && Grounding.namesOnlyWhatWasSaid(text, evidence: evidence.around(lines), names: evidence.speakers)
        }.prefix(shape.decisions))
        // The question itself must be about the item, not just some other cited line.
        var openQuestions = Array(groundedItems(raw.openQuestions, evidence: evidence) { text, lines in
            lines.contains { Grounding.isQuestion($0.text) && Grounding.sharesContent(text, with: $0.text) }
        }.prefix(shape.openQuestions))
        let settled = decisions + actionItems.map(\.task) + openQuestions
        let notes = groundedItems(raw.notesToRemember, evidence: evidence) { text, lines in
            !Grounding.overstatesCompletion(text, lines: lines.map(\.text))
                && Grounding.namesOnlyWhatWasSaid(text, evidence: evidence.around(lines), names: evidence.speakers)
        }.filter { note in !settled.contains { restates(note, $0) } }
        // These cite nothing, so they must be about something specific that was said: two content words shared
        // with one line ("Nobody checked the three weeks' notice" against Karen's line, not "Discuss strategies").
        let missed = deduplicated(raw.missedOpportunities).filter { item in
            evidence.transcript.contains { Grounding.sharedContent(item, with: $0.text) >= 2 }
        }

        let topics = raw.topics.compactMap { topic -> TopicSummary? in
            guard let title = topic.title,
                Grounding.sharesContent(title + " " + (topic.summary ?? ""), with: evidence.allText)
            else { return nil }
            let summary = unoverstated(sentences(topic.summary ?? ""), evidence: evidence).joined(separator: " ")
            return TopicSummary(title: title, summary: summary, speakers: deduplicated(topic.speakers.compactMap(evidence.speaker)))
        }
        // Sentences claiming as done what was only promised go; the first sentence always stays. Paragraphs are
        // kept; a thin meeting gets at most two sentences.
        var overview = groundedOverview(raw.overview ?? "", evidence: evidence, isThin: shape.isThin)
        let conversation = outline(raw.outline, evidence: evidence, shape: shape, declined: declined.outline)
        if overview.isEmpty, !declined.summary.isEmpty {
            overview = TranscriptOutliner.overview(
                transcript: transcript, speakers: TranscriptFormatter.speakingParticipants(participants, transcript: transcript), outline: conversation)
        }
        if !declined.lists.isEmpty {
            let extracted = extractedLists(declined.lists, transcript: transcript)
            openQuestions += extracted.questions.filter { question in !openQuestions.contains { restates(question, $0) } }
            actionItems += extracted.actionItems.filter { item in !actionItems.contains { restates(item.task, $0.task) } }
        }

        return MeetingReport(
            title: title,
            overview: overview,
            topics: Array(topics.prefix(shape.topics)),
            decisions: decisions,
            actionItems: actionItems,
            notesToRemember: Array(notes.prefix(shape.notes)),
            missedOpportunities: Array(missed.prefix(shape.missedOpportunities)),
            openQuestions: openQuestions,
            corrections: Array(groundedCorrections(raw.corrections, evidence: evidence).prefix(shape.corrections)),
            participantSummaries: shape.keyPoints == 0
                ? [] : participantSummaries(raw.participantSummaries, participants: participants, evidence: evidence, limit: shape.keyPoints),
            outline: conversation,
            generatedBy: generatedBy,
            generatedAt: generatedAt)
    }

    /// Most questions and possible action items `extractedLists` adds, as in a report without AI.
    static let extractedQuestionLimit = 10
    static let extractedActionItemLimit = 12

    /// The questions and possible action items `TranscriptOutliner` finds by word cues in `ranges` (lines whose
    /// lists request the model declined), each range on its own.
    static func extractedLists(_ ranges: [Range<Int>], transcript: [ContextLine]) -> (questions: [String], actionItems: [ActionItem]) {
        let pieces = ranges.filter { $0.upperBound <= transcript.count }.map { Array(transcript[$0]) }
        return (
            Array(deduplicated(pieces.flatMap(TranscriptOutliner.questions)).prefix(extractedQuestionLimit)),
            Array(pieces.flatMap(TranscriptOutliner.possibleActionItems).prefix(extractedActionItemLimit)))
    }

    /// The overview's paragraphs without sentences that call promises done; the first sentence always stays.
    /// A thin meeting keeps its first two sentences, as one paragraph.
    static func groundedOverview(_ text: String, evidence: Evidence, isThin: Bool) -> String {
        let paragraphs = text.components(separatedBy: "\n").map(sentences).filter { !$0.isEmpty }
        guard let first = paragraphs.first else { return "" }
        if isThin {
            let all = Array(paragraphs.joined())
            return ([all[0]] + unoverstated(Array(all.dropFirst()), evidence: evidence)).prefix(2).joined(separator: " ")
        }
        let kept = [[first[0]] + unoverstated(Array(first.dropFirst()), evidence: evidence)]
            + paragraphs.dropFirst().map { unoverstated($0, evidence: evidence) }
        return kept.filter { !$0.isEmpty }.map { $0.joined(separator: " ") }.joined(separator: "\n\n")
    }

    /// Items whose text shares content words with the lines they cite, when `supports` accepts the item's text
    /// and those lines.
    static func groundedItems(_ items: [RawItem], evidence: Evidence, supports: (String, [ContextLine]) -> Bool) -> [String] {
        var seen = Set<String>()
        return items.compactMap { item in
            guard let (text, numbers) = item.text.map({ Evidence.citation(in: $0) }), !comparable(text).isEmpty else { return nil }
            let lines = evidence.lines(item.lines + numbers)
            guard !lines.isEmpty, supports(text, lines), Grounding.sharesContent(text, with: Evidence.joined(lines)),
                seen.insert(comparable(text)).inserted
            else { return nil }
            return text
        }
    }

    /// Action items backed by a cited line that commits to or asks for a task to be done after the conversation.
    /// The owner must be who committed (the speaker) or who was asked (the person named); an owner the evidence
    /// contradicts is replaced by the only one it supports, else cleared. Copies of a task keep the majority owner
    /// and any deadline another copy carried; a deadline must have been said, and one the model left out is taken
    /// from the line that set the task.
    static func groundedActionItems(_ items: [RawActionItem], evidence: Evidence) -> [ActionItem] {
        let items = items.map { item in
            var item = item
            if let task = item.task {
                let (text, numbers) = Evidence.citation(in: task)
                item.task = text
                item.lines += numbers
            }
            return item
        }
        let spoken = comparable(evidence.allText)
        // A copy of a task may carry the deadline another copy omitted.
        var dueByTask: [String: String] = [:]
        for item in items {
            guard let task = item.task, dueByTask[comparable(task)] == nil, let due = item.due.flatMap({ groundedDue($0, spoken: spoken) })
            else { continue }
            dueByTask[comparable(task)] = due
        }
        // The same task may come back several times (small models repeat themselves); keep it once, owned by
        // whoever most of the copies name (earliest wins ties).
        var ownerVotes: [String: [String: Int]] = [:]
        var firstOwnerIndex: [String: [String: Int]] = [:]
        for (index, item) in items.enumerated() {
            guard let task = item.task, let owner = cleanedOwner(item.owner) else { continue }
            ownerVotes[comparable(task), default: [:]][owner, default: 0] += 1
            if firstOwnerIndex[comparable(task)]?[owner] == nil { firstOwnerIndex[comparable(task), default: [:]][owner] = index }
        }

        var kept: [(item: ActionItem, support: [Int])] = []
        var seenTasks = Set<String>()
        for item in items {
            guard let task = item.task, !comparable(task).isEmpty, !seenTasks.contains(comparable(task)) else { continue }
            let numbers = evidence.numbers(item.lines)
            guard Grounding.sharesContent(task, with: Evidence.joined(evidence.lines(numbers))) else { continue }
            // Who each supporting line makes responsible: the committing speaker, or the person asked.
            var support: [(number: Int, line: ContextLine, owner: String?)] = []
            for number in numbers {
                let line = evidence.transcript[number - 1]
                let cues = Grounding.taskCues(line.text)
                if cues.contains(.commitment) { support.append((number, line, line.speaker)) }
                if cues.contains(.request) { support.append((number, line, addressee(of: line, among: evidence.speakers))) }
                if cues.contains(.group) { support.append((number, line, nil)) }
            }
            guard !support.isEmpty else { continue }
            seenTasks.insert(comparable(task))

            let votes = ownerVotes[comparable(task)] ?? [:]
            let firsts = firstOwnerIndex[comparable(task)] ?? [:]
            let favourite = votes.max { a, b in a.value != b.value ? a.value < b.value : firsts[a.key, default: 0] > firsts[b.key, default: 0] }?.key
            let committer = support.first { $0.owner == $0.line.speaker }?.line.speaker ?? support[0].line.speaker
            let claimed = resolveOwner(favourite ?? item.owner, speaker: committer)
            let supported = deduplicated(support.compactMap(\.owner))
            let owner = supported.first { $0.caseInsensitiveCompare(claimed ?? "") == .orderedSame }
                ?? (supported.count == 1 ? supported[0] : nil)
            // Prefer the owner's own commitment, then the request made to them.
            let source = support.first { owner != nil && $0.owner == owner && $0.line.speaker == owner }?.line
                ?? support.first { owner != nil && $0.owner == owner }?.line ?? support[0].line
            // A deadline the model left out may still be on the line that set the task ("I'll book them this week"),
            // or on the other line between the same people ("Tom, please send it today." "Will do.").
            let due = dueByTask[comparable(task)] ?? Grounding.deadline(in: source.text)
                ?? support.lazy.filter { $0.owner == owner }.compactMap { Grounding.deadline(in: $0.line.text) }.first
            let candidate = ActionItem(task: task, owner: owner, due: due, sourceSegmentID: source.segmentID)
            let supportNumbers = support.map(\.number)
            // A reworded copy of a kept task: same owner, same subject, evidence at most two lines apart (the
            // request and the reply that accepts it).
            guard !kept.contains(where: { other in
                other.item.owner == owner && restates(task, other.item.task)
                    && other.support.contains { a in supportNumbers.contains { abs(a - $0) <= 2 } }
            }) else { continue }
            kept.append((candidate, supportNumbers))
        }
        return kept.map(\.item)
    }

    /// Corrections of a cited line that fit their kind; the speaker is that line's speaker and the reason comes
    /// from the kind.
    static func groundedCorrections(_ notes: [RawCorrection], evidence: Evidence) -> [CorrectionNote] {
        var seen = Set<String>()
        return notes.compactMap { note -> CorrectionNote? in
            guard let kind = CorrectionKind(lenient: note.kind), let original = note.original.map(unquoted),
                let corrected = note.corrected.map(unquoted), !original.isEmpty, !corrected.isEmpty,
                comparable(original) != comparable(corrected)
            else { return nil }
            let cited = evidence.lines(note.lines)
            // The corrected line holds the original wording; any other cited line is what it contradicts.
            guard let line = cited.first(where: { comparable($0.text).contains(comparable(original)) })
                ?? cited.first(where: { Grounding.sharesContent(original, with: $0.text) })
            else { return nil }
            let stretch = comparable(line.text).contains(comparable(original)) ? original : line.text
            let others = cited.filter { $0 != line }
            let reason = kind == .contradiction
                ? others.lazy.compactMap { correctionReason(kind, original: stretch, corrected: corrected, line: line, contradicted: $0) }.first
                : correctionReason(kind, original: stretch, corrected: corrected, line: line, contradicted: nil)
            guard let reason, seen.insert(comparable(line.text) + "|" + comparable(corrected)).inserted else { return nil }
            // A self-correction quoted without the words it replaced ("Sorry, I mean Wednesday") reads better as
            // the whole line.
            let fixed = Grounding.contentStems(corrected)
            let replacesSomething = Grounding.contentStems(stretch).contains { word in !fixed.contains { Grounding.related(word, $0) } }
            let shown = kind == .selfCorrection && !replacesSomething ? line.text : stretch
            return CorrectionNote(speaker: line.speaker, original: shown, corrected: corrected, reason: reason)
        }
    }

    /// `text` says nothing beyond `other`: at least 60% of its content words appear there.
    static func restates(_ text: String, _ other: String) -> Bool {
        let stems = Grounding.contentStems(text)
        let otherStems = Grounding.contentStems(other)
        guard !stems.isEmpty else { return true }
        let shared = stems.filter { word in otherStems.contains { Grounding.related(word, $0) } }.count
        return Double(shared) >= 0.6 * Double(stems.count)
    }

    /// Summaries only for people who spoke, in the given participant order, then other speakers.
    static func participantSummaries(_ raw: [RawParticipant], participants: [String], evidence: Evidence, limit: Int) -> [ParticipantSummary] {
        var points: [String: [RawItem]] = [:]
        for entry in raw {
            guard let name = entry.name.flatMap(evidence.speaker) else { continue }
            points[name.lowercased(), default: []].append(contentsOf: entry.keyPoints)
        }
        let order = deduplicated(participants.compactMap(evidence.speaker) + evidence.speakers)
        return order.compactMap { name in
            let keyPoints = deduplicated((points[name.lowercased()] ?? []).compactMap { groundedPoint($0, by: name, evidence: evidence)?.text })
            guard !keyPoints.isEmpty else { return nil }
            return ParticipantSummary(name: name, keyPoints: Array(keyPoints.prefix(limit)))
        }
    }

    /// A key point of `name`'s, kept when it cites at least one of their own lines that is not small talk, shares
    /// content words with those lines (two when the point has four or more), does not call a promise done, and
    /// names nothing those lines do not. A cited line that refers back ("Sure, I'll book them this week") also
    /// lends the words of the line just before it ("Priya, could you book the tickets?"). Returns the text and
    /// the 1-based numbers of `name`'s cited lines.
    static func groundedPoint(_ point: RawItem, by name: String, evidence: Evidence) -> (text: String, lines: [Int])? {
        guard let (text, numbers) = point.text.map({ Evidence.citation(in: $0) }), !comparable(text).isEmpty else { return nil }
        let cited = evidence.numbers(point.lines + numbers).filter {
            evidence.transcript[$0 - 1].speaker.caseInsensitiveCompare(name) == .orderedSame
        }
        let own = cited.map { evidence.transcript[$0 - 1] }
        guard own.contains(where: { !Grounding.isSmallTalk($0.text) }) else { return nil }
        let referents = cited.filter { $0 > 1 && Grounding.refersBack(evidence.transcript[$0 - 1].text) }.map { evidence.transcript[$0 - 2] }
        let said = Evidence.joined(own + referents)
        let needed = Set(Grounding.contentStems(text)).count >= 4 ? 2 : 1
        guard Grounding.sharedContent(text, with: said) >= needed,
            !Grounding.overstatesCompletion(text, lines: own.map(\.text)),
            Grounding.namesOnlyWhatWasSaid(text, evidence: said, names: evidence.speakers)
        else { return nil }
        return (text, cited)
    }

    /// `sentences` without the ones claiming as done what the lines about them only promise or ask for. Each clause
    /// is checked on its own ("Priya booked the passes, and Leo needs the slides reviewed" claims the booking done
    /// even though its second clause states a need). The lines about a clause are those sharing at least two
    /// content words with it.
    static func unoverstated(_ sentences: [String], evidence: Evidence) -> [String] {
        sentences.filter { sentence in
            clauses(sentence).allSatisfy { clause in
                let about = evidence.transcript.filter { Grounding.sharedContent(clause, with: $0.text) >= 2 }.map(\.text)
                return about.isEmpty || !Grounding.overstatesCompletion(clause, lines: about)
            }
        }
    }

    /// The clauses of `sentence`: split at commas, semicolons, colons, dashes and "and"/"but"/"while"/"whereas".
    static func clauses(_ sentence: String) -> [String] {
        sentence.components(separatedBy: CharacterSet(charactersIn: ",;:—–"))
            .flatMap { $0.components(separatedBy: " and ") }
            .flatMap { $0.components(separatedBy: " but ") }
            .flatMap { $0.components(separatedBy: " while ") }
            .flatMap { $0.components(separatedBy: " whereas ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !Grounding.contentStems($0).isEmpty }
    }

    /// The sentences of `text`, trimmed.
    static func sentences(_ text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { substring, _, _, _ in
            if let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty { sentences.append(sentence) }
        }
        return sentences
    }
}

/// The transcript as evidence: cited line numbers resolved to lines, and who actually spoke.
struct Evidence {
    let transcript: [ContextLine]
    /// Distinct speakers with at least one line, in order of first line.
    let speakers: [String]
    let allText: String

    init(_ transcript: [ContextLine]) {
        self.transcript = transcript
        speakers = TranscriptFormatter.participantNames(participants: [], transcript: transcript)
        allText = Self.joined(transcript)
    }

    /// Lines within this distance of a cited decision or note may supply its nouns: the on-device model cites the
    /// answer and not the question it answers ("about six thousand euros" for the travel budget asked a line
    /// earlier), or misses the line by one. Measured on the 40-line meeting, cited lines alone dropped three
    /// correct items; two lines either side kept them all.
    static let nounWindow = 2

    /// The text of `lines` and the lines within `nounWindow` of them.
    func around(_ lines: [ContextLine]) -> String {
        let cited = Set(lines.map(\.segmentID))
        let indices = transcript.indices.filter { cited.contains(transcript[$0].segmentID) }
        let near = transcript.indices.filter { i in indices.contains { abs($0 - i) <= Self.nounWindow } }
        return Self.joined(near.map { transcript[$0] })
    }

    /// Existing 1-based line numbers among `numbers`, each once, in citation order.
    func numbers(_ numbers: [Int]) -> [Int] {
        var seen = Set<Int>()
        return numbers.filter { transcript.indices.contains($0 - 1) && seen.insert($0).inserted }
    }

    /// Existing lines for 1-based `numbers`, each once, in citation order; unknown numbers are ignored.
    func lines(_ numbers: [Int]) -> [ContextLine] {
        self.numbers(numbers).map { transcript[$0 - 1] }
    }

    /// The transcript speaker called `name` (case-insensitive), in the transcript's spelling.
    func speaker(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return speakers.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    static func joined(_ lines: [ContextLine]) -> String {
        lines.map(\.text).joined(separator: " ")
    }

    /// Splits a trailing "(L3, L7)" citation, as rendered for the merge step, off `text`.
    static func citation(in text: String) -> (text: String, lines: [Int]) {
        guard let range = text.range(of: #"\s*\(\s*L\d+(\s*,\s*L\d+)*\s*\)\s*$"#, options: .regularExpression) else {
            return (text, [])
        }
        let lines = text[range].split { !$0.isNumber }.compactMap { Int($0) }
        return (String(text[..<range.lowerBound]), lines)
    }
}

/// How long each report list may be. A meeting with little substance gets a brief report: overview and at most
/// one topic, plus decisions, action items, questions and corrections only when they survive grounding.
struct ReportShape: Equatable {
    var isThin: Bool
    var topics: Int
    var decisions: Int
    var actionItems: Int
    var notes: Int
    var missedOpportunities: Int
    var openQuestions: Int
    var corrections: Int
    /// Key points per participant; 0 drops participant summaries.
    var keyPoints: Int
    /// Outline segments and points per segment. A thin meeting gets one short segment, and stretches the model
    /// left out are not filled in.
    var outlineSegments: Int
    var outlinePoints: Int

    /// Thin below either threshold. Measured with `Grounding.substance`: the user's failed one-minute meeting has
    /// 4 content words on 1 substantive line; the 10-line fixture meeting has 54 on 10 (about 5 per line), and
    /// its first four lines alone (greeting, agenda, two status updates) reach 22 on 4. Four substantive lines
    /// and about 20 content words are the least that carries a decision or task with its context.
    static let minimumContentWords = 20
    static let minimumSubstantiveLines = 4

    init(_ substance: Grounding.Substance) {
        isThin = substance.contentWords < Self.minimumContentWords || substance.substantiveLines < Self.minimumSubstantiveLines
        let n = substance.substantiveLines
        if isThin {
            (topics, decisions, actionItems, notes, missedOpportunities, openQuestions, corrections, keyPoints) = (1, 2, 2, 0, 0, 1, 1, 0)
            (outlineSegments, outlinePoints) = (1, 2)
        } else {
            // About one decision per four substantive lines, one task per three, and so on. Up to about 50
            // substantive lines (one on-device request) the caps are the on-device schema maximums; longer meetings,
            // whose parts' lists are joined, get more, up to a ceiling that keeps the report readable.
            let parts = max(1, (n + 49) / 50)
            topics = min(5 + 3 * (parts - 1), 8, 1 + n / 6)
            decisions = min(6 * parts, 12, max(2, n / 4))
            actionItems = min(8 * parts, 20, max(3, n / 3))
            notes = min(6 * parts, 12, max(2, n / 5))
            missedOpportunities = min(3, max(1, n / 10))
            openQuestions = min(4 * parts, 8, max(1, n / 8))
            corrections = min(3 * parts, 5, max(1, n / 10))
            keyPoints = min(4 + 2 * (parts - 1), 6, max(2, n / 8))
            // A segment needs a few substantive lines to say anything; six points keep each one readable.
            outlineSegments = max(1, n / 2)
            outlinePoints = 6
        }
    }
}
