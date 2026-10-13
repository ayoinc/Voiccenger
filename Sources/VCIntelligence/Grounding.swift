import Foundation
import VCModels

/// Deterministic word-level checks that tie model output to the transcript: content words with light stemming,
/// speech-act cues (commitments, requests, decisions, questions, repairs) and how much substance a meeting has.
/// Nothing here understands language; each check only rejects output the cited lines cannot possibly support.
enum Grounding {
    // MARK: Words

    /// Lowercased words. Apostrophes split contractions ("I'll" → "i", "ll"), which the cue lists rely on.
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Function words, pronouns, auxiliaries, contraction fragments and light verbs that carry no topic.
    static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "so", "then", "than", "that", "this", "these", "those", "there",
        "here", "it", "its", "is", "are", "was", "were", "be", "been", "being", "am", "do", "does", "did", "done",
        "doing", "have", "has", "had", "having", "will", "would", "shall", "should", "can", "could", "may", "might",
        "must", "i", "me", "my", "mine", "myself", "we", "us", "our", "ours", "ourselves", "you", "your", "yours",
        "yourself", "he", "him", "his", "she", "her", "hers", "they", "them", "their", "theirs", "themselves", "what",
        "which", "who", "whom", "whose", "when", "where", "why", "how", "all", "any", "some", "each", "every", "no",
        "not", "nor", "only", "own", "same", "too", "very", "just", "also", "of", "to", "in", "on", "at", "by", "for",
        "with", "about", "into", "through", "during", "before", "after", "from", "up", "down", "out", "off", "over",
        "under", "again", "once", "more", "most", "other", "such", "as", "until", "while", "because", "both", "few",
        "s", "t", "ll", "re", "ve", "d", "m", "don", "didn", "doesn", "isn", "aren", "wasn", "weren", "won", "wouldn",
        "couldn", "shouldn", "hasn", "haven", "let", "lets", "get", "gets", "got", "go", "goes", "going", "gone",
        "went", "make", "makes", "made", "take", "takes", "took", "put", "come", "came", "really", "well", "like",
        "kind", "sort", "one", "now", "still", "yet", "already", "even", "much", "many", "lot", "lots", "bit", "quite",
        "maybe", "perhaps", "think", "know", "guess", "mean", "want", "way", "able", "today", "something", "anything",
        "everything", "nothing", "someone", "anyone", "somebody", "anybody", "nobody", "noone", "first", "1st", "last",
        "next", "back", "else", "though", "although", "actually", "basically", "literally", "probably", "definitely",
        "yes", "yeah", "important", "crucial",
    ]

    /// Hesitations and backchannels.
    static let fillers: Set<String> = [
        "uh", "um", "umm", "uhm", "uhh", "er", "erm", "ah", "ahh", "eh", "hmm", "hm", "mm", "mmm", "mhm", "huh", "oh",
        "ooh", "ha", "haha",
    ]

    /// Greetings, thanks and politeness.
    static let social: Set<String> = [
        "hey", "hi", "hello", "morning", "afternoon", "evening", "thanks", "thank", "thankyou", "welcome", "bye",
        "goodbye", "cheers", "sorry", "please", "everyone", "everybody", "guys", "folks", "great", "good", "nice",
        "okay", "ok", "sure", "right", "cool", "fine", "awesome", "lovely", "glad", "appreciate", "appreciated",
    ]

    /// Words about the meeting itself: items built only from these ("Introduce the discussion", "Thank
    /// attendees") are logistics, not content.
    static let meta: Set<String> = [
        "meeting", "meetings", "call", "session", "discuss", "discussed", "discussing", "discussion", "discussions",
        "introduce", "introduced", "introducing", "introduction", "introductions", "attend", "attending", "attended",
        "attendee", "attendees", "attendance", "join", "joining", "joined", "agenda", "speaker", "speakers",
        "participant", "participants", "talk", "talked", "talking", "ask", "asked", "asking", "question", "questions",
        "say", "said", "saying", "mention", "mentioned", "thing", "things", "item", "items", "start", "started",
        "begin", "opened",
    ]

    /// Topic-bearing words of `text`, stemmed: no stopwords, fillers, greetings or meeting logistics.
    static func contentStems(_ text: String) -> [String] {
        words(text).compactMap { word in
            guard !stopwords.contains(word), !fillers.contains(word), !social.contains(word), !meta.contains(word),
                word.count >= 2 || word.allSatisfy(\.isNumber)
            else { return nil }
            return stem(word)
        }
    }

    /// Strips one common English suffix ("budgets" → "budget", "boxes" → "box", "companies" → "company",
    /// "planning" → "plann"); `related` absorbs what this leaves behind. Words ending in "ss" keep it ("press").
    static func stem(_ word: String) -> String {
        if word.hasSuffix("ss") { return word }
        for (suffix, replacement) in [
            ("ations", ""), ("ation", ""), ("ments", ""), ("ment", ""), ("ings", ""), ("ing", ""), ("ies", "y"),
            ("ied", "y"), ("sses", "ss"), ("xes", "x"), ("ches", "ch"), ("shes", "sh"), ("ers", ""), ("ed", ""),
            ("s", ""), ("ly", ""),
        ] where word.hasSuffix(suffix) && word.count - suffix.count >= 3 {
            return String(word.dropLast(suffix.count)) + replacement
        }
        return word
    }

    /// Same stem, one stem a prefix of the other (at least 4 letters: "introduc" / "introduction"), or a
    /// shared prefix of 6+ letters ("estimate" / "estimating").
    static func related(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        if short.count >= 4, long.hasPrefix(short) { return true }
        return zip(a, b).prefix { $0 == $1 }.count >= 6
    }

    /// At least one content word of `text` is related to a content word of `evidence`.
    static func sharesContent(_ text: String, with evidence: String) -> Bool {
        sharedContent(text, with: evidence) > 0
    }

    /// How many distinct content words of `text` are related to a content word of `evidence`.
    static func sharedContent(_ text: String, with evidence: String) -> Int {
        let stems = contentStems(evidence)
        return Set(contentStems(text)).filter { word in stems.contains { related(word, $0) } }.count
    }

    // MARK: Speech acts

    /// Finds `phrase` in `words`; returns the index just past each match.
    static func ends(of phrase: [String], in words: [String]) -> [Int] {
        guard !phrase.isEmpty, phrase.count <= words.count else { return [] }
        return (0...(words.count - phrase.count)).compactMap { start in
            Array(words[start..<(start + phrase.count)]) == phrase ? start + phrase.count : nil
        }
    }

    /// The speaker takes a task on ("I'll", "I'm going to", "let me", "will do").
    static let commitmentCues: [[String]] = [
        ["i", "will"], ["i", "ll"], ["i", "shall"], ["i", "m", "going", "to"], ["i", "am", "going", "to"], ["i", "can"],
        ["let", "me"], ["i", "need", "to"], ["i", "have", "to"], ["i", "must"], ["i", "plan", "to"], ["i", "promise"],
        ["will", "do"], ["on", "it"], ["leave", "it", "with", "me"],
    ]

    /// The group takes a task on ("we need to", "let's").
    static let groupCues: [[String]] = [
        ["we", "will"], ["we", "ll"], ["we", "re", "going", "to"], ["we", "are", "going", "to"], ["we", "need", "to"],
        ["we", "have", "to"], ["we", "must"], ["we", "should"], ["let", "s"], ["let", "us"],
    ]

    /// The speaker asks someone else to do something.
    static let requestCues: [[String]] = [
        ["can", "you"], ["could", "you"], ["would", "you"], ["will", "you"], ["please"], ["you", "need", "to"],
        ["you", "have", "to"], ["you", "should"], ["you", "must"], ["make", "sure"], ["need", "you", "to"],
        ["like", "you", "to"], ["want", "you", "to"],
    ]

    /// Verbs for things done in the room, during the conversation ("introduce yourself", "tell us", "let's get
    /// started"): asking for them creates no task.
    static let inRoomVerbs: Set<String> = [
        "introduce", "tell", "say", "explain", "repeat", "describe", "clarify", "answer", "elaborate", "speak", "talk",
        "summarize", "summarise", "recap", "walk", "go", "start", "begin", "continue", "kick", "wrap", "get", "move",
        "thank", "welcome", "hear", "listen", "discuss", "think", "see", "hold", "pause", "stop",
    ]

    /// Words skipped between a cue and its verb ("can you please quickly tell us").
    private static let cueSkips: Set<String> = [
        "please", "just", "also", "quickly", "briefly", "maybe", "all", "now", "first", "then", "us", "both", "again",
        "kindly", "actually", "definitely", "certainly", "really", "probably",
    ]

    /// Time words and phrases that put a task after the conversation ("by Friday", "next week", "before the freeze").
    static let timeWords: Set<String> = [
        "today", "tomorrow", "tonight", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "weekend", "week", "weeks", "month", "months", "quarter", "year", "january", "february", "march", "april",
        "june", "july", "august", "september", "october", "november", "december", "eod", "eow", "asap", "later",
        "afterwards", "soon", "deadline", "noon", "midday",
    ]

    static func hasTimeMarker(_ words: [String]) -> Bool {
        if words.contains(where: timeWords.contains) { return true }
        if !ends(of: ["after", "the", "meeting"], in: words).isEmpty || !ends(of: ["end", "of"], in: words).isEmpty {
            return true
        }
        // "by the end", "by Friday", "before the freeze", but not "by the way".
        for marker in ["by", "before"] {
            for end in ends(of: [marker], in: words) where end < words.count {
                if Array(words[end..<min(words.count, end + 2)]) != ["the", "way"] { return true }
            }
        }
        return false
    }

    /// The verb after each match of `cues` (nil when the cue ends the utterance, as in "Will do.").
    static func verbs(after cues: [[String]], in words: [String]) -> [String?] {
        cues.flatMap { cue in
            ends(of: cue, in: words).map { end -> String? in
                words[end...].first { !cueSkips.contains($0) && !fillers.contains($0) }
            }
        }
    }

    enum TaskCue: Equatable {
        /// The speaker will do it.
        case commitment
        /// The group will do it; no single owner.
        case group
        /// Someone else was asked.
        case request
    }

    /// Task cues on a line, excluding ones whose verb is a conversational act done in the room ("can you introduce
    /// yourself?") unless a time marker puts it after the meeting.
    static func taskCues(_ text: String) -> [TaskCue] {
        let words = words(text)
        let later = hasTimeMarker(words)
        func live(_ cues: [[String]]) -> Bool {
            verbs(after: cues, in: words).contains { verb in later || verb.map { !inRoomVerbs.contains($0) } ?? true }
        }
        var result: [TaskCue] = []
        if live(commitmentCues) { result.append(.commitment) }
        if live(groupCues) { result.append(.group) }
        if live(requestCues) { result.append(.request) }
        return result
    }

    static let decisionWords: Set<String> = [
        "agree", "agreed", "agreement", "decide", "decided", "decision", "decisions", "final", "finalise", "finalize",
        "finalised", "finalized", "confirm", "confirmed", "approve", "approved", "settle", "settled", "deal",
    ]

    static let decisionPhrases: [[String]] = [["go", "with"], ["going", "with"], ["sounds", "good"], ["fine", "with", "me"]]

    /// Verbs that put a choice off ("we'll figure that out next week"): not decisions.
    static let deferringVerbs: Set<String> = ["figure", "revisit", "circle", "look", "follow", "check", "sort", "come", "decide", "wait"]

    /// "agreed", "decided", "let's ship…", "we'll go with…"; "let's get started" and other logistics, and
    /// deferrals like "we'll figure that out", do not count.
    static func hasDecisionCue(_ text: String) -> Bool {
        let words = words(text)
        if words.contains(where: decisionWords.contains) { return true }
        if decisionPhrases.contains(where: { !ends(of: $0, in: words).isEmpty }) { return true }
        let groupVerbs = verbs(after: [["let", "s"], ["let", "us"], ["we", "will"], ["we", "ll"], ["we", "re", "going", "to"], ["we", "are", "going", "to"]], in: words)
        return groupVerbs.contains { verb in verb.map { !inRoomVerbs.contains($0) && !deferringVerbs.contains($0) } ?? false }
    }

    /// Deadline phrases ("by Friday", "before the freeze", "this week"). A pattern string, compiled per call:
    /// `NSRegularExpression` is not `Sendable` in every SDK this builds with, and a call costs microseconds.
    private static let deadlinePattern: String = {
        let day = "monday|tuesday|wednesday|thursday|friday|saturday|sunday"
        let month = "january|february|march|april|may|june|july|august|september|october|november|december"
        let when = [
            "today", "tomorrow", "tonight", "noon", "midday", "eod", "eow", "the weekend", day,
            "(?:this|next) (?:week|month|quarter|year|\(day))", "(?:the )?end of (?:the |this |next )?\\w+",
            "the \\w+(?:th|st|nd|rd)", "\\d{1,2}(?::\\d{2})? ?(?:am|pm)?", "(?:\(month))(?: \\d{1,2}(?:st|nd|rd|th)?)?",
        ].joined(separator: "|")
        return "\\b(?:(?:by|until|on) (?<at>\(when))|(?<before>before (?:\(when)|the \\w+))|(?<bare>today|tomorrow|tonight|asap|(?:this|next) (?:week|month|quarter)))\\b"
    }()

    /// The deadline words in `text`, as said: "by Friday" → "Friday", "before the freeze", "today", "this week".
    static func deadline(in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: deadlinePattern, options: [.caseInsensitive]),
            let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        for name in ["at", "before", "bare"] {
            if let found = Range(match.range(withName: name), in: text) { return String(text[found]) }
        }
        return nil
    }

    // MARK: Claims

    /// Past forms of task verbs: a point using one says the task is done ("Sent the list", "Booked tickets").
    static let completionVerbs: Set<String> = [
        "sent", "booked", "shipped", "fixed", "finished", "completed", "delivered", "updated", "emailed", "scheduled",
        "decided", "shared", "prepared", "submitted", "released", "launched", "signed", "paid", "refunded", "resolved",
        "implemented", "deployed", "published", "organised", "organized", "arranged", "covered", "handled", "built",
        "designed", "tested", "bought", "ordered", "cancelled", "canceled", "uploaded", "drafted", "finalised",
        "finalized", "wrote", "written", "estimated", "reviewed", "merged", "hired", "created", "installed",
        "contacted", "invited", "done",
    ]

    /// Words that say something already happened.
    private static let completionCues: Set<String> = ["done", "already", "finished", "complete", "completed", "yesterday", "ago"]

    /// Promises, plans and requests: the thing is still to happen.
    private static let intentPhrases: [[String]] = [
        ["will"], ["ll"], ["going", "to"], ["gonna"], ["need", "to"], ["needs", "to"], ["plan", "to"], ["have", "to"],
        ["can", "you"], ["could", "you"], ["would", "you"], ["please"], ["let", "me"], ["let", "s"], ["let", "us"],
    ]

    /// `text` states something as done: a past task verb ("Sent finance the list") or have + past participle,
    /// and no promise of its own ("Will send…", "Promised to share…" claim nothing).
    static func claimsCompletion(_ text: String) -> Bool {
        let words = words(text)
        guard !expressesIntent(words) else { return false }
        if hasPastTaskVerb(words) { return true }
        return zip(words, words.dropFirst()).contains { auxiliary, verb in
            ["has", "have", "had"].contains(auxiliary) && (verb.hasSuffix("ed") || completionVerbs.contains(verb))
        }
    }

    /// A past task verb used as a verb, not as an adjective after a determiner ("the updated budget").
    private static func hasPastTaskVerb(_ words: [String]) -> Bool {
        let determiners: Set<String> = ["the", "a", "an", "this", "that", "our", "my", "your", "their", "its"]
        return words.indices.contains { i in
            completionVerbs.contains(words[i]) && (i == 0 || !determiners.contains(words[i - 1]))
        }
    }

    static func expressesIntent(_ text: String) -> Bool {
        let words = words(text)
        return expressesIntent(words) || deadline(in: text) != nil
    }

    private static func expressesIntent(_ words: [String]) -> Bool {
        intentPhrases.contains { !ends(of: $0, in: words).isEmpty }
    }

    /// "done", "already", "last week", or a past task verb on the line itself ("We finished the integration"), but
    /// not one used as an adjective ("the updated budget").
    static func hasCompletionCue(_ text: String) -> Bool {
        let words = words(text)
        return words.contains(where: completionCues.contains) || hasPastTaskVerb(words) || !ends(of: ["last", "week"], in: words).isEmpty
    }

    /// A claim that something was done, when the lines behind it only promise, plan or ask for it ("Booked
    /// tickets" from "I'll book them this week").
    static func overstatesCompletion(_ text: String, lines: [String]) -> Bool {
        claimsCompletion(text) && lines.contains(where: expressesIntent) && !lines.contains(where: hasCompletionCue)
    }

    /// Off-topic chat ("Finally got out on the bike, the weather was great").
    static let smallTalkWords: Set<String> = [
        "weekend", "weather", "flat", "holiday", "holidays", "vacation", "lunch", "coffee", "bike", "cycling", "garden",
        "gardening", "tomato", "tomatoes", "tired", "sleep", "kids", "family", "birthday", "football", "traffic",
        "commute", "rain", "sunny", "movie", "dinner", "breakfast", "tea", "drinks", "party",
    ]

    /// Off-topic chat, or a short line that takes nothing on ("Great, thanks.", "Sounds good."). "Sure, I'll book
    /// them this week" is short but not small talk.
    static func isSmallTalk(_ line: String) -> Bool {
        if words(line).contains(where: smallTalkWords.contains) { return true }
        return contentStems(line).count < substantiveLineWords && taskCues(line).isEmpty
    }

    /// The line points back at something said before it ("I'll book them", "I can take that").
    static func refersBack(_ text: String) -> Bool {
        words(text).contains { ["it", "them", "that", "those", "this", "these"].contains($0) }
    }

    /// Verbs (base and irregular past forms) that also pass the noun-like test below; regular past and -ing forms
    /// are recognised by their endings.
    private static let verbLike: Set<String> = [
        "send", "share", "book", "ship", "fix", "update", "review", "propose", "agree", "confirm", "request", "plan",
        "estimate", "finish", "complete", "deliver", "email", "schedule", "decide", "prepare", "submit", "release",
        "sign", "pay", "refund", "resolve", "implement", "deploy", "publish", "organise", "organize", "arrange",
        "cover", "handle", "build", "design", "test", "buy", "order", "cancel", "upload", "draft", "finalise",
        "finalize", "write", "create", "check", "follow", "provide", "raise", "explain", "report", "suggest",
        "recommend", "approve", "move", "keep", "give", "stop", "hold", "set", "wait", "become", "becomes", "need",
        "needs", "sent", "wrote", "written", "built", "paid", "bought", "found", "gave", "given", "took", "led",
        "spent", "held", "kept", "told", "brought", "met", "ran", "began", "chose", "chosen", "done", "lead",
        "leads", "discuss", "consider", "assign", "assigned", "attend", "ask", "asks", "work", "works",
    ]

    /// The misreading check for short items (at most `maximumWords` content words): every noun-like content word
    /// (not a known verb, not an -ed/-ing/-ly form) must appear in `evidence` or be a speaker's name. Catches
    /// "budget freeze" stitched from "freeze features" and "updated budget" on another line.
    static func namesOnlyWhatWasSaid(_ text: String, evidence: String, names: [String], maximumWords: Int = 6) -> Bool {
        let candidates = words(text).filter { word in
            !stopwords.contains(word) && !fillers.contains(word) && !social.contains(word) && !meta.contains(word)
                && (word.count >= 2 || word.allSatisfy(\.isNumber))
        }
        guard Set(candidates.map(stem)).count <= maximumWords else { return true }
        let available = contentStems(evidence) + names.flatMap { words($0).map(stem) }
        return candidates.allSatisfy { word in
            let isNounLike = !verbLike.contains(word) && !word.hasSuffix("ed") && !word.hasSuffix("ing") && !word.hasSuffix("ly")
            return !isNounLike || available.contains { related(stem(word), $0) }
        }
    }

    private static let questionStarts: Set<String> = [
        "what", "who", "whom", "whose", "which", "when", "where", "why", "how", "is", "are", "was", "were", "do",
        "does", "did", "can", "could", "should", "would", "will", "shall", "have", "has", "had", "may", "might", "any",
    ]

    /// A question mark, or a clause opening with a question word or inverted auxiliary ("Who's covering…").
    static func isQuestion(_ text: String) -> Bool {
        if text.contains("?") { return true }
        let leading: Set<String> = ["so", "and", "but", "okay", "ok", "well", "also", "then", "now"]
        guard let first = words(text).first(where: { !leading.contains($0) && !fillers.contains($0) }) else { return false }
        return questionStarts.contains(first)
    }

    // MARK: Disfluency

    /// Words with fillers removed and immediate repetitions collapsed ("I don't, I don't really" → "i don t really").
    static func fluent(_ text: String) -> [String] {
        var result: [String] = []
        for word in words(text) where !fillers.contains(word) {
            result.append(word)
            // Drop a repeated run of 1–4 words ("i don t i don t" → "i don t").
            for length in stride(from: min(4, result.count / 2), through: 1, by: -1)
            where Array(result.suffix(length)) == Array(result.dropLast(length).suffix(length)) {
                result.removeLast(length)
                break
            }
        }
        return result
    }

    // MARK: Substance

    struct Substance: Equatable {
        /// Content words (`contentStems`) over the whole transcript.
        var contentWords: Int
        /// Lines with at least `substantiveLineWords` content words.
        var substantiveLines: Int
        /// Distinct speakers with at least one line.
        var speakers: Int
    }

    static let substantiveLineWords = 3

    static func substance(_ transcript: [ContextLine]) -> Substance {
        var content = 0
        var substantive = 0
        for line in transcript {
            let count = contentStems(line.text).count
            content += count
            if count >= substantiveLineWords { substantive += 1 }
        }
        return Substance(
            contentWords: content, substantiveLines: substantive,
            speakers: Set(transcript.map { $0.speaker.lowercased() }).count)
    }

    // MARK: Sound

    /// Plausibly confused by speech recognition: same Soundex code ("weak"/"week"), or same first letter and at
    /// most half the letters different ("forty"/"fourteen").
    static func soundsAlike(_ a: String, _ b: String) -> Bool {
        let x = Array(a.lowercased().filter(\.isLetter))
        let y = Array(b.lowercased().filter(\.isLetter))
        guard !x.isEmpty, !y.isEmpty else { return false }
        if soundex(x) == soundex(y) { return true }
        return x[0] == y[0] && 2 * editDistance(x, y) <= max(x.count, y.count)
    }

    /// American Soundex code of lowercase letters ("week" → "w200").
    static func soundex(_ letters: [Character]) -> String {
        func code(_ c: Character) -> Character? {
            switch c {
            case "b", "f", "p", "v": "1"
            case "c", "g", "j", "k", "q", "s", "x", "z": "2"
            case "d", "t": "3"
            case "l": "4"
            case "m", "n": "5"
            case "r": "6"
            default: nil
            }
        }
        guard let first = letters.first else { return "" }
        var result = String(first)
        var previous = code(first)
        for letter in letters.dropFirst() where result.count < 4 {
            let current = code(letter)
            if let current, current != previous { result.append(current) }
            // "h" and "w" do not separate equal codes; vowels do.
            if letter != "h", letter != "w" { previous = current }
        }
        return result.padding(toLength: 4, withPad: "0", startingAt: 0)
    }

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var diagonal = row[0]
            row[0] = i + 1
            for (j, y) in b.enumerated() {
                let above = row[j + 1]
                row[j + 1] = min(above + 1, row[j] + 1, diagonal + (x == y ? 0 : 1))
                diagonal = above
            }
        }
        return row[b.count]
    }
}
