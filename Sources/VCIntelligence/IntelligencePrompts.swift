import Foundation
import VCModels

/// Prompt text shared by every engine, so Apple Intelligence and Claude are asked exactly the same questions.
public enum IntelligencePrompts {
    /// System instructions for live, per-utterance analysis.
    public static let analysisInstructions = """
        You assist a live meeting. You receive one new utterance from a speech-recognition transcript, \
        plus numbered recent lines for context. Context lines look like "L3 [mm:ss] Speaker: text".
        Analyse only the new utterance:
        1. intent: the single best label. statement; question; proposal; decision; commitment (the speaker \
        promises to do something later); request (the speaker asks someone else to do something later); \
        objection; correction (the speaker corrects themselves or someone else); smallTalk (greetings, thanks, \
        chit-chat).
        2. correctionKind: almost always none. Use another kind only when it clearly applies:
        - selfCorrection: the speaker repairs their own words ("sorry", "I mean", "no", "actually"). \
        correctedText is the repaired part: for "Tuesday the fourteenth, sorry, I mean Wednesday the fifteenth" \
        it is "Wednesday the fifteenth".
        - contradiction: the utterance contradicts a context line. contradictsLine is that line's number and \
        correctedText states the utterance in agreement with that line.
        - mishearing: speech recognition clearly got a word wrong. correctedText is the utterance with only \
        that word fixed ("last weak" becomes "last week").
        Fillers (uh, um, hmm), repeated words, hesitations and unfinished sentences are normal speech: kind \
        none. Never guess what someone meant, never rephrase or polish. With kind none, leave correctedText \
        and contradictsLine empty.
        3. suggestion: only when it would genuinely help the meeting right now, one short complete line \
        starting with "Propose:", "Confirm:", "Ask:" or "Clarify:". Most utterances need no suggestion.
        4. actionItem: only when someone commits to, or is asked to do, a concrete task after the \
        conversation. Not for things said or done in the room (introductions, thanks, a question answered on \
        the spot). task is a short imperative; owner is the person who will do it: the speaker when they say \
        "I will", the person addressed when the speaker asks someone else. due is the deadline exactly as \
        spoken, if any; never invent one.
        """

    /// Rules shared by the single-pass report and the per-part notes.
    private static let evidenceRules = """
        Write every item briefly in your own words; never copy a transcript line. Every decision, action item, \
        note, open question and correction cites in lines the numbers of the transcript lines that say it (7 \
        for L7); check that each cited line really says it. Empty lists are normal and expected, especially \
        for short or chatty meetings. Never create items for greetings, thanks, introductions or meeting \
        logistics.
        """

    /// List rules shared by the single-pass report and the per-part notes.
    private static let listRules = """
        - decisions: only what the participants explicitly agreed or decided; the corrected version when \
        someone corrected themselves.
        - actionItems: tasks to be done after the meeting that someone committed to ("I'll…") or was asked to \
        do ("Sam, can you…"); not things asked and answered in the room. owner: the person who will do it (the \
        person asked, not the one asking). due: deadline words actually said, else null; never a mm:ss \
        timestamp. Write tasks in the third person, without "I", "my" or "you".
        - notesToRemember: facts, numbers, dates and constraints stated in the meeting; not repeats of \
        decisions or action items.
        - missedOpportunities: at most a few important follow-ups, risks or questions nobody raised.
        - openQuestions: questions someone asked that stayed unanswered.
        - corrections: kind selfCorrection (a speaker repaired their own words), contradiction (a line \
        contradicts an earlier one; cite both) or mishearing (a word clearly misrecognised); speaker, original \
        wording, corrected wording. Fillers, repetitions and hesitations are not corrections.
        - participantSummaries: for each speaker, key points from their own lines, each citing those lines; a \
        promise or plan stays a promise ("will send the budget"), never something done; no small talk.
        """

    /// System instructions for building the whole report in one pass.
    public static let reportInstructions = """
        You write the post-meeting report from a speech-recognition transcript. Lines look like \
        "L3 [mm:ss] Speaker: text", where L3 is the line number. Be faithful: include only what the transcript \
        says, and read past obvious recognition errors.
        \(evidenceRules)
        - title: a short meeting title (keep the given title when there is one).
        - overview: one to three sentences about what was actually said.
        - topics: the subjects actually discussed, in order, each with a short summary and the speakers involved.
        \(listRules)
        """

    /// Map step: notes for one part of a meeting too long for a single request.
    public static let partNotesInstructions = """
        You take notes on one part of a longer meeting, from a speech-recognition transcript. Lines look like \
        "L3 [mm:ss] Speaker: text", where L3 is the line number. Be faithful: include only what this part says.
        \(evidenceRules)
        - title: a short title for this part. overview: one or two sentences.
        - topics with short summaries and speakers.
        \(listRules)
        """

    /// Reduce step: merge notes from consecutive parts into one set.
    public static let mergeNotesInstructions = """
        You merge notes taken on consecutive parts of one meeting into a single set of notes for the \
        whole meeting. Items carry the transcript line numbers that support them, like (L3, L7): keep them on \
        every merged item, combining the numbers of merged duplicates, and never add new ones. Remove \
        duplicates. When a later decision supersedes an earlier one, keep only the later one. Keep every \
        distinct action item with its owner and due date. Drop open questions that a later part answered. \
        Combine each participant's key points. Write a title and a one to three sentence overview for \
        everything covered. Do not add anything the notes do not support; empty lists are fine.
        """

    /// User turn for live analysis. Context lines are numbered from L1 so a contradiction can cite one.
    public static func analysisPrompt(utterance: ContextLine, recentContext: [ContextLine]) -> String {
        var prompt = ""
        if recentContext.isEmpty {
            prompt += "Recent context: (none)\n\n"
        } else {
            prompt += "Recent context:\n" + TranscriptFormatter.format(NumberedLine.numbering(recentContext)) + "\n\n"
        }
        prompt += "New utterance:\n" + TranscriptFormatter.format(utterance)
        return prompt
    }

    /// User turn for a report over (part of) a numbered transcript. A whole meeting with little substance gets
    /// a reminder to keep the report brief.
    public static func reportPrompt(
        transcript: [NumberedLine], participants: [String], meetingTitle: String?, part: (index: Int, count: Int)? = nil
    ) -> String {
        let lines = transcript.map(\.line)
        var prompt = header(participants: participants, meetingTitle: meetingTitle, transcript: lines)
        if let part, part.count > 1 {
            prompt += "This is part \(part.index + 1) of \(part.count).\n"
        } else if ReportShape(Grounding.substance(lines)).isThin {
            prompt += """
                This meeting is short and has little substance: write a one or two sentence overview and at most \
                one topic, and leave the other lists empty unless a line clearly supports an item.

                """
        }
        prompt += "Transcript:\n" + TranscriptFormatter.format(transcript)
        return prompt
    }

    /// User turn for merging rendered part notes.
    public static func mergePrompt(renderedNotes: [String], participants: [String], meetingTitle: String?) -> String {
        var prompt = header(participants: participants, meetingTitle: meetingTitle, transcript: [])
        for (index, notes) in renderedNotes.enumerated() {
            prompt += "\nNotes for part \(index + 1):\n" + notes + "\n"
        }
        return prompt
    }

    private static func header(participants: [String], meetingTitle: String?, transcript: [ContextLine]) -> String {
        var header = ""
        if let title = meetingTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            header += "Meeting title: \(title)\n"
        }
        let names = transcript.isEmpty
            ? TranscriptFormatter.participantNames(participants: participants, transcript: [])
            : TranscriptFormatter.speakingParticipants(participants, transcript: transcript)
        if !names.isEmpty {
            header += "Participants: \(names.joined(separator: ", "))\n"
        }
        return header
    }
}

/// A transcript line with its 1-based number in the whole meeting: the `L` handle reports cite as evidence.
/// Pieces of a line split to fit a request keep the line's number.
public struct NumberedLine: Sendable, Hashable {
    public var number: Int
    public var line: ContextLine

    public init(number: Int, line: ContextLine) {
        self.number = number
        self.line = line
    }

    /// `lines` numbered from 1.
    public static func numbering(_ lines: [ContextLine]) -> [NumberedLine] {
        lines.enumerated().map { NumberedLine(number: $0.offset + 1, line: $0.element) }
    }
}

/// Renders transcript lines as `[mm:ss] Speaker: text`, numbered lines as `L3 [mm:ss] Speaker: text`.
public enum TranscriptFormatter {
    /// `mm:ss` with minutes allowed past 59 (a 75-minute meeting shows `75:03`). Negative times clamp to zero.
    public static func timestamp(_ time: TimeInterval) -> String {
        let total = time.isFinite ? max(0, Int(time.rounded(.down))) : 0
        let minutes = total / 60
        let seconds = total % 60
        return (minutes < 10 ? "0" : "") + String(minutes) + ":" + (seconds < 10 ? "0" : "") + String(seconds)
    }

    public static func format(_ line: ContextLine) -> String {
        let speaker = line.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = collapseWhitespace(line.text)
        return "[\(timestamp(line.time))] \(speaker.isEmpty ? "Unknown" : speaker): \(text)"
    }

    public static func format(_ line: NumberedLine) -> String {
        "L\(line.number) " + format(line.line)
    }

    public static func format(_ lines: [ContextLine]) -> String {
        lines.map(format).joined(separator: "\n")
    }

    public static func format(_ lines: [NumberedLine]) -> String {
        lines.map(format).joined(separator: "\n")
    }

    /// Explicit participants first (in the given order), then any other speaker heard in the transcript.
    static func participantNames(participants: [String], transcript: [ContextLine]) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for name in participants + transcript.map(\.speaker) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            names.append(trimmed)
        }
        return names
    }

    /// The people who actually spoke: given participants with at least one line, in the given order, then any
    /// other speaker heard. A participant without lines (a diarization blip) is not a person in the meeting.
    static func speakingParticipants(_ participants: [String], transcript: [ContextLine]) -> [String] {
        let speakers = Set(transcript.map { $0.speaker.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let speaking = participants.filter { speakers.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        return participantNames(participants: speaking, transcript: transcript)
    }

    /// Newlines inside an utterance would break the one-line-per-utterance format the models rely on.
    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
