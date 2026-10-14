import Foundation
import NaturalLanguage
import VCModels

/// The report for Macs without a language model: an outline built from the transcript alone. Nothing here
/// writes new text; every point is a sentence a speaker said, every question a line someone asked, and every
/// action item only a possible one, found by commitment and request cues.
public final class TranscriptOutlineEngine: MeetingIntelligence {
    public static let name = "Transcript outline (no AI)"

    public init() {}

    public var engineName: String { Self.name }

    /// Intent from word cues only: no corrections, suggestions or tasks without a language model.
    public func analyze(utterance: ContextLine, recentContext: [ContextLine]) async throws -> UtteranceInsight {
        let cues = Grounding.taskCues(utterance.text)
        let intent: UtteranceIntent =
            cues.contains(.commitment) ? .commitment
            : cues.contains(.request) ? .request
            : Grounding.isQuestion(utterance.text) ? .question
            : Grounding.isSmallTalk(utterance.text) ? .smallTalk : .statement
        return UtteranceInsight(intent: intent)
    }

    public func report(transcript: [ContextLine], participants: [String], meetingTitle: String?) async throws -> MeetingReport {
        TranscriptOutliner.report(transcript: transcript, participants: participants, meetingTitle: meetingTitle)
    }
}

/// Deterministic pieces of the conversation outline: segmenting a transcript where the talk pauses or its words
/// change, headings from a segment's distinctive words, and each speaker's most informative sentences. Used for
/// the whole report without a language model, and to fill stretches a language model's outline left out.
enum TranscriptOutliner {
    /// Fewest lines in a segment found by `segments`.
    static let minimumSegmentLines = 4
    /// About this many lines per segment found by `segments`.
    static let linesPerSegment = 12
    /// Lines either side of a candidate boundary compared for a change of words.
    static let comparisonWindow = 6
    /// Longest point text; longer sentences are cut at a word and end in "…".
    static let maximumPointCharacters = 220

    // MARK: Report

    static func report(transcript: [ContextLine], participants: [String], meetingTitle: String?, generatedAt: Date = Date()) -> MeetingReport {
        let title = meetingTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyText ?? "Meeting"
        guard !transcript.isEmpty else {
            return MeetingReport(
                title: title, overview: "No speech was transcribed.", topics: [], decisions: [], actionItems: [],
                notesToRemember: [], missedOpportunities: [], openQuestions: [], corrections: [], participantSummaries: [],
                kind: .transcriptOutline, generatedBy: TranscriptOutlineEngine.name, generatedAt: generatedAt)
        }
        let shape = ReportShape(Grounding.substance(transcript))
        let vocabulary = Vocabulary(transcript)
        let found = segments(transcript, vocabulary: vocabulary)
        let ranges = mergeGroups(found, weak: found.map { _ in false }, transcript: transcript).map { group in
            found[group.first!].lowerBound..<found[group.last!].upperBound
        }
        var outline = ranges.compactMap { range -> OutlineSegment? in
            let points = points(in: range, of: transcript, vocabulary: vocabulary, limit: pointLimit(range, of: transcript, cap: shape.outlinePoints))
            guard !points.isEmpty else { return nil }
            let (start, end) = times(of: range, in: transcript)
            return OutlineSegment(heading: heading(of: range, in: transcript, vocabulary: vocabulary), start: start, end: end, points: points, isExtracted: true)
        }
        outline = Array(outline.prefix(shape.outlineSegments))
        let speakers = TranscriptFormatter.speakingParticipants(participants, transcript: transcript)
        return MeetingReport(
            title: title,
            overview: overview(transcript: transcript, speakers: speakers, outline: outline),
            topics: [], decisions: [],
            actionItems: Array(possibleActionItems(transcript).prefix(shape.isThin ? 2 : 12)),
            notesToRemember: [], missedOpportunities: [],
            openQuestions: Array(questions(transcript).prefix(shape.isThin ? 1 : 10)),
            corrections: [], participantSummaries: [], outline: outline, kind: .transcriptOutline,
            generatedBy: TranscriptOutlineEngine.name, generatedAt: generatedAt)
    }

    /// Who spoke, for how long, and the headings of the stretches, in plain words.
    static func overview(transcript: [ContextLine], speakers: [String], outline: [OutlineSegment]) -> String {
        let (start, end) = times(of: transcript.indices, in: transcript)
        let lines = "\(transcript.count) line\(transcript.count == 1 ? "" : "s")"
        var text = "\(listed(speakers)) spoke \(lines) over \(spokenDuration(end - start))."
        if outline.count > 1 {
            text += " The transcript falls into \(outline.count) stretches: \(outline.map(\.heading).joined(separator: "; "))."
        }
        return text
    }

    /// Questions about the meeting's subject, as "Speaker: question". Requests phrased as questions ("Can you
    /// send…?") are possible action items instead.
    static func questions(_ transcript: [ContextLine]) -> [String] {
        var seen = Set<String>()
        return transcript.compactMap { line in
            let asked = ResultAssembler.sentences(line.text).filter { $0.contains("?") || Grounding.isQuestion($0) }
            guard Grounding.isQuestion(line.text), let question = asked.first.map(cleaned),
                Set(Grounding.contentStems(question)).count >= 2, !Grounding.isSmallTalk(question),
                !Grounding.taskCues(question).contains(.request),
                seen.insert(ResultAssembler.comparable(question)).inserted
            else { return nil }
            return "\(line.speaker): \(question)"
        }
    }

    /// Sentences where someone takes a task on or asks someone else to, with a real verb after the cue ("I'll
    /// book…", not "I can, but…"). The speaker owns a commitment; the person named owns a request, or else the
    /// next speaker when they answer it ("Yes, I can…"); a group task has no owner. A reply that only accepts a
    /// request just made to its speaker ("Sure, I'll send it") adds its deadline to that request instead of
    /// repeating it. Deadlines are the words said.
    static func possibleActionItems(_ transcript: [ContextLine]) -> [ActionItem] {
        let speakers = TranscriptFormatter.participantNames(participants: [], transcript: transcript)
        let allCues = Grounding.commitmentCues + Grounding.groupCues + Grounding.requestCues
        var items: [ActionItem] = []
        var itemLine: [Int] = []
        var seen = Set<String>()
        for (index, line) in transcript.enumerated() {
            guard let sentence = ResultAssembler.sentences(line.text).first(where: { sentence in
                !Grounding.taskCues(sentence).isEmpty
                    && Grounding.verbs(after: allCues, in: Grounding.words(sentence)).contains { verb in
                        verb.map { !notVerbs.contains($0) && !Grounding.inRoomVerbs.contains($0) } ?? false
                    }
            }), Set(Grounding.contentStems(sentence)).count >= 2, !Grounding.claimsCompletion(sentence)
            else { continue }
            let cues = Grounding.taskCues(sentence)
            let due = Grounding.deadline(in: sentence)
            // "Sure, I'll send it this afternoon" after "Tom, please send…": the same task.
            if cues.contains(.commitment), Grounding.refersBack(sentence), let last = items.indices.last,
                index - itemLine[last] <= 2, items[last].owner == line.speaker, transcript[itemLine[last]].speaker != line.speaker
            {
                if items[last].due == nil { items[last].due = due }
                continue
            }
            let task = cleaned(sentence)
            guard seen.insert(ResultAssembler.comparable(task)).inserted else { continue }
            var owner: String?
            if cues.contains(.commitment) {
                owner = line.speaker
            } else if cues.contains(.request) {
                owner = ResultAssembler.addressee(of: line, among: speakers) ?? answerer(of: index, in: transcript)
            }
            // At most one item per line, so the line's ID identifies it and the report stays deterministic.
            items.append(ActionItem(id: line.segmentID, task: task, owner: owner, due: due, sourceSegmentID: line.segmentID))
            itemLine.append(index)
        }
        return items
    }

    /// The next speaker, when their line accepts what was asked ("Yes, I can…", "Sure.").
    static func answerer(of index: Int, in transcript: [ContextLine]) -> String? {
        guard index + 1 < transcript.count, transcript[index + 1].speaker != transcript[index].speaker else { return nil }
        let reply = transcript[index + 1].text
        let accepts = ["yes", "sure", "okay", "ok", "will", "absolutely", "definitely"]
        guard Grounding.taskCues(reply).contains(.commitment) || Grounding.words(reply).first.map(accepts.contains) == true
        else { return nil }
        return transcript[index + 1].speaker
    }

    // MARK: Segments

    /// Phrases that open a new subject ("Next topic…", "Moving on…", "Last thing…").
    static let transitionCues: [[String]] = [
        ["next", "topic"], ["next", "item"], ["next", "up"], ["next", "is"], ["moving", "on"], ["move", "on"],
        ["last", "thing"], ["last", "item"], ["first", "up"], ["one", "more", "thing"], ["another", "thing"],
        ["turning", "to"], ["let", "s", "talk", "about"], ["switching", "to"],
    ]

    /// Consecutive line ranges covering the whole transcript, about `linesPerSegment` lines each. A boundary
    /// scores the change of words between the lines before and after it (weighted by how rare the words are),
    /// plus a pause longer than usual before it, plus a transition phrase opening its first line; the best
    /// boundaries at least `minimumSegmentLines` apart win. Deterministic: ties go to the earlier boundary.
    static func segments(_ transcript: [ContextLine], vocabulary: Vocabulary) -> [Range<Int>] {
        let n = transcript.count
        let wanted = min(n / minimumSegmentLines, Int((Double(n) / Double(linesPerSegment)).rounded()))
        guard n >= 2 * minimumSegmentLines, wanted > 1 else { return n == 0 ? [] : [0..<n] }
        let bags = transcript.map { vocabulary.weights(Grounding.contentStems($0.text)) }
        let pauses = (1..<n).map { transcript[$0].time - end(of: $0 - 1, in: transcript) }
        let usualPause = max(1, pauses.sorted()[pauses.count / 2])
        var candidates: [(boundary: Int, score: Double)] = []
        for boundary in minimumSegmentLines...(n - minimumSegmentLines) {
            let before = merged(bags[max(0, boundary - comparisonWindow)..<boundary])
            let after = merged(bags[boundary..<min(n, boundary + comparisonWindow)])
            let pause = min(0.5, max(0, pauses[boundary - 1] - 2 * usualPause) / 8)
            let opening = Array(Grounding.words(transcript[boundary].text).prefix(10))
            let transition = transitionCues.contains { !Grounding.ends(of: $0, in: opening).isEmpty } ? 0.5 : 0
            candidates.append((boundary, (1 - cosine(before, after)) + pause + transition))
        }
        candidates.sort { $0.score != $1.score ? $0.score > $1.score : $0.boundary < $1.boundary }
        var chosen: [Int] = []
        for candidate in candidates where chosen.count < wanted - 1 {
            if chosen.allSatisfy({ abs($0 - candidate.boundary) >= minimumSegmentLines }) { chosen.append(candidate.boundary) }
        }
        let edges = [0] + chosen.sorted() + [n]
        return zip(edges, edges.dropFirst()).map { $0..<$1 }
    }

    // MARK: Merging segments

    /// Segments with fewer substantive lines than this are merged into a neighbour.
    static let minimumSubstantiveLines = 3
    /// About one segment per this many seconds of meeting…
    static let secondsPerSegment: TimeInterval = 180
    /// …and never more than this many (an hour-long meeting).
    static let maximumSegments = 12

    /// How many segments a meeting of `duration` gets at most: one per three minutes, between 1 and 12.
    static func segmentLimit(duration: TimeInterval) -> Int {
        min(maximumSegments, max(1, Int((duration / secondsPerSegment).rounded(.up))))
    }

    static func substantiveLines(_ range: Range<Int>, of transcript: [ContextLine]) -> Int {
        transcript[range].filter { isSubstantive($0.text) }.count
    }

    /// Consecutive segments (`ranges`, adjacent and in order) grouped for merging, as lists of their indices.
    /// First every thin segment (fewer than `minimumSubstantiveLines` substantive lines, or `weak`: only quotes
    /// filled in from the transcript) joins whichever neighbour shares more of its words; then, while there are
    /// more than `segmentLimit` segments, the adjacent pair that shares the most words merges, less half its
    /// combined length relative to an even split (a merged block shares words with everything, so without the
    /// penalty one segment swallows the meeting). Ties: the earlier pair. Deterministic.
    static func mergeGroups(_ ranges: [Range<Int>], weak: [Bool], transcript: [ContextLine]) -> [[Int]] {
        guard ranges.count > 1 else { return ranges.indices.map { [$0] } }
        let vocabulary = Vocabulary(transcript)
        let bags = transcript.map { vocabulary.weights(Grounding.contentStems($0.text)) }
        var groups = ranges.indices.map { [$0] }
        func span(_ group: [Int]) -> Range<Int> { ranges[group.first!].lowerBound..<ranges[group.last!].upperBound }
        func similarity(_ a: [Int], _ b: [Int]) -> Double { cosine(merged(bags[span(a)]), merged(bags[span(b)])) }
        func isThin(_ group: [Int]) -> Bool {
            substantiveLines(span(group), of: transcript) < minimumSubstantiveLines || group.allSatisfy { weak[$0] }
        }
        func merge(_ i: Int) {
            groups[i] += groups[i + 1]
            groups.remove(at: i + 1)
        }
        while groups.count > 1, let i = groups.indices.first(where: { isThin(groups[$0]) }) {
            if i == 0 {
                merge(0)
            } else if i == groups.count - 1 {
                merge(i - 1)
            } else {
                merge(similarity(groups[i - 1], groups[i]) >= similarity(groups[i], groups[i + 1]) ? i - 1 : i)
            }
        }
        let duration = transcript.isEmpty ? 0 : times(of: transcript.indices, in: transcript).end - transcript[0].time
        let limit = segmentLimit(duration: duration)
        let evenSplit = Double(transcript.count) / Double(limit)
        while groups.count > limit {
            func score(_ i: Int) -> Double {
                similarity(groups[i], groups[i + 1]) - 0.5 * Double(span(groups[i]).count + span(groups[i + 1]).count) / evenSplit
            }
            let best = groups.indices.dropLast().max { a, b in score(a) != score(b) ? score(a) < score(b) : a > b }!
            merge(best)
        }
        return groups
    }

    /// Two to six points: about one per two substantive lines.
    static func pointLimit(_ range: Range<Int>, of transcript: [ContextLine], cap: Int) -> Int {
        let substantive = transcript[range].filter { isSubstantive($0.text) }.count
        return min(cap, max(2, substantive / 2))
    }

    static func isSubstantive(_ text: String) -> Bool {
        Grounding.contentStems(text).count >= Grounding.substantiveLineWords && !Grounding.isSmallTalk(text)
    }

    /// The most informative sentences of `range`, taking turns between speakers (best first), at most one per line,
    /// in transcript order. Each is quoted as said, minus leading fillers.
    static func points(in range: Range<Int>, of transcript: [ContextLine], vocabulary: Vocabulary, limit: Int) -> [OutlinePoint] {
        guard limit > 0 else { return [] }
        var bySpeaker: [String: [(line: Int, order: Int, text: String, score: Double)]] = [:]
        var speakerOrder: [String] = []
        for index in range {
            let line = transcript[index]
            for (order, sentence) in ResultAssembler.sentences(line.text).enumerated() {
                let score = informativeness(sentence, vocabulary: vocabulary)
                guard score > 0, !Grounding.isSmallTalk(sentence) else { continue }
                let key = line.speaker.lowercased()
                if bySpeaker[key] == nil { speakerOrder.append(key) }
                bySpeaker[key, default: []].append((index, order, sentence, score))
            }
        }
        for key in speakerOrder {
            bySpeaker[key]?.sort { $0.score != $1.score ? $0.score > $1.score : ($0.line, $0.order) < ($1.line, $1.order) }
        }
        // Speakers with the best sentence go first in each round.
        let turns = speakerOrder.sorted { (bySpeaker[$0]?.first?.score ?? 0) > (bySpeaker[$1]?.first?.score ?? 0) }
        var picked: [(line: Int, order: Int, text: String)] = []
        var usedLines = Set<Int>()
        var progress = true
        while picked.count < limit, progress {
            progress = false
            for key in turns where picked.count < limit {
                guard var queue = bySpeaker[key] else { continue }
                while let next = queue.first, usedLines.contains(next.line) { queue.removeFirst() }
                if let next = queue.first {
                    queue.removeFirst()
                    picked.append((next.line, next.order, next.text))
                    usedLines.insert(next.line)
                    progress = true
                }
                bySpeaker[key] = queue
            }
        }
        return picked.sorted { ($0.line, $0.order) < ($1.line, $1.order) }.map { pick in
            let line = transcript[pick.line]
            return OutlinePoint(speaker: line.speaker, text: cleaned(pick.text), time: line.time, segmentIDs: [line.segmentID], isQuote: true)
        }
    }

    /// Words after a task cue that show it takes no task on ("I can, but…", "we'll see if…").
    static let notVerbs: Set<String> = [
        "but", "and", "or", "so", "if", "then", "too", "also", "not", "yes", "no", "the", "a", "an", "it", "that",
        "this", "to", "be", "i", "we", "you",
    ]

    /// Nouns too vague for a heading.
    static let vagueNouns: Set<String> = [
        "topic", "topics", "thing", "things", "point", "points", "idea", "ideas", "view", "time", "minute", "minutes",
        "people", "person", "bit", "lot", "part", "stuff", "way", "case", "question", "questions",
    ]

    /// Spelled-out numbers: facts worth a bonus, never headings.
    static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty",
        "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "million", "billion", "percent", "half",
    ]

    /// Sum of the weights (`Vocabulary.weight`) of a sentence's distinct content words, plus a bonus for numbers;
    /// long sentences are scaled down. Sentences with fewer than three content words score 0.
    static func informativeness(_ sentence: String, vocabulary: Vocabulary) -> Double {
        let stems = Set(Grounding.contentStems(sentence))
        guard stems.count >= Grounding.substantiveLineWords else { return 0 }
        let words = Grounding.words(sentence)
        var score = stems.reduce(0) { $0 + vocabulary.weight($1) }
        score += 1.5 * Double(words.filter { $0.contains(where: \.isNumber) || numberWords.contains($0) }.count)
        if words.count > 30 { score *= 30 / Double(words.count) }
        return score
    }

    /// Up to three of the segment's most distinctive nouns (frequent here, rare elsewhere), as said, without
    /// speakers' names, numbers or time words: "Billing, refunds and customers".
    static func heading(of range: Range<Int>, in transcript: [ContextLine], vocabulary: Vocabulary) -> String {
        let names = Set(transcript.flatMap { Grounding.words($0.speaker).map(Grounding.stem) })
        var counts: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        var surfaces: [String: [String: Int]] = [:]
        for line in transcript[range] {
            for word in nouns(line.text) {
                guard let stem = Grounding.contentStems(word).first, !names.contains(stem), !word.contains(where: \.isNumber),
                    !numberWords.contains(word), !vagueNouns.contains(word), !Grounding.timeWords.contains(word),
                    !Grounding.smallTalkWords.contains(word)
                else { continue }
                counts[stem, default: 0] += 1
                surfaces[stem, default: [:]][word, default: 0] += 1
                if firstSeen[stem] == nil { firstSeen[stem] = firstSeen.count }
            }
        }
        let ranked = counts.keys.sorted { a, b in
            let x = Double(counts[a]!) * vocabulary.idf(a), y = Double(counts[b]!) * vocabulary.idf(b)
            return x != y ? x > y : firstSeen[a]! < firstSeen[b]!
        }
        let words = ranked.prefix(3).compactMap { stem in
            surfaces[stem]?.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
        }
        guard let first = words.first else { return "Conversation" }
        return listed([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst())
    }

    /// The words `NLTagger` tags as nouns, lowercased.
    static func nouns(_ text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var nouns: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitPunctuation, .omitWhitespace]) { tag, range in
            if tag == .noun { nouns.append(text[range].lowercased()) }
            return true
        }
        return nouns
    }

    // MARK: Times

    /// When the lines of `range` start and end. A line's end is its own when known, else the next line's start,
    /// else an estimate from its length.
    static func times(of range: Range<Int>, in transcript: [ContextLine]) -> (start: TimeInterval, end: TimeInterval) {
        guard !range.isEmpty else { return (0, 0) }
        let start = transcript[range.lowerBound].time
        return (start, max(start, end(of: range.upperBound - 1, in: transcript)))
    }

    static func end(of index: Int, in transcript: [ContextLine]) -> TimeInterval {
        let line = transcript[index]
        if let end = line.end, end >= line.time { return end }
        if index + 1 < transcript.count { return max(line.time, transcript[index + 1].time) }
        // About 2.5 words a second.
        return line.time + max(1, Double(Grounding.words(line.text).count) / 2.5)
    }

    // MARK: Text

    private static let leadingFiller =
        #"^\s*(?:(?:um+|uh+|uhm|erm?|ah|oh|so|and|but|well|okay|ok|yeah|right|like|hmm)\b[\s,.…-]*)+"#

    /// `sentence` without leading fillers, capitalised, cut to `maximumPointCharacters` at a word.
    static func cleaned(_ sentence: String) -> String {
        var text = TranscriptFormatter.collapseWhitespace(sentence)
        if let range = text.range(of: leadingFiller, options: [.regularExpression, .caseInsensitive]), range.upperBound < text.endIndex {
            text = String(text[range.upperBound...])
        }
        if text.count > maximumPointCharacters {
            let cut = text.prefix(maximumPointCharacters)
            text = (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut))
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-")) + "…"
        }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func listed(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }

    static func spokenDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 90 { return "\(total) second\(total == 1 ? "" : "s")" }
        let minutes = Int((Double(total) / 60).rounded())
        return "about \(minutes) minutes"
    }

    // MARK: Vocabulary

    /// How rare each content word is across the meeting's lines (inverse document frequency), and how topical:
    /// a word said on only one line ("the train was stuck") is usually an aside, not the subject.
    struct Vocabulary {
        private let lineFrequency: [String: Int]
        private let lines: Double

        /// Weight of a word said on a single line, relative to one said on several.
        static let asideWeight = 0.35

        init(_ transcript: [ContextLine]) {
            var frequency: [String: Int] = [:]
            for line in transcript {
                for stem in Set(Grounding.contentStems(line.text)) { frequency[stem, default: 0] += 1 }
            }
            lineFrequency = frequency
            lines = Double(transcript.count)
        }

        func idf(_ stem: String) -> Double {
            log((lines + 1) / (Double(lineFrequency[stem] ?? 0) + 1)) + 1
        }

        /// Rarity, scaled down for words said on one line only.
        func weight(_ stem: String) -> Double {
            idf(stem) * ((lineFrequency[stem] ?? 0) > 1 ? 1 : Self.asideWeight)
        }

        func weights(_ stems: [String]) -> [String: Double] {
            stems.reduce(into: [:]) { $0[$1, default: 0] += weight($1) }
        }
    }

    private static func merged(_ bags: ArraySlice<[String: Double]>) -> [String: Double] {
        bags.reduce(into: [:]) { result, bag in result.merge(bag, uniquingKeysWith: +) }
    }

    private static func cosine(_ a: [String: Double], _ b: [String: Double]) -> Double {
        let dot = a.reduce(0) { $0 + $1.value * (b[$1.key] ?? 0) }
        let norms = sqrt(a.values.reduce(0) { $0 + $1 * $1 }) * sqrt(b.values.reduce(0) { $0 + $1 * $1 })
        return norms > 0 ? dot / norms : 0
    }
}

extension String {
    /// Nil when empty.
    fileprivate var nonEmptyText: String? { isEmpty ? nil : self }
}
