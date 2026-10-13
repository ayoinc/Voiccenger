import Foundation
import VCModels

/// Prompt text shared by every engine, so Apple Intelligence and Claude are asked exactly the same questions.
public enum IntelligencePrompts {
    /// System instructions for live, per-utterance analysis.
    public static let analysisInstructions = """
        You assist a live meeting. You receive one new utterance from a speech-recognition transcript, \
        plus recent lines for context. Lines look like "[mm:ss] Speaker: text".
        Analyse only the new utterance:
        1. intent: the single best label. statement; question; proposal; decision; commitment (the speaker \
        promises to do something); request (the speaker asks someone else to do something); objection; \
        correction (the speaker corrects themselves or someone else); smallTalk.
        2. Correction: most utterances are fine. Set correctedText only when the utterance contains a slip, \
        a self-correction, a misstatement, a contradiction of the context, or an obvious speech-recognition \
        error. correctedText is what the speaker actually meant, stated briefly, and must differ in meaning \
        from what was said. Example: for "Tuesday the fourteenth, sorry, I mean Wednesday the fifteenth" \
        correctedText is "Wednesday the fifteenth". correctionReason explains the problem in one short \
        sentence. When the utterance is fine, leave both empty. Never repeat, rephrase, polish or summarise \
        correct speech, and never "correct" a statement that agrees with the context.
        3. suggestion: only when it would genuinely help the meeting right now, one short complete line \
        starting with "Propose:", "Confirm:", "Ask:" or "Clarify:". Most utterances need no suggestion.
        4. actionItem: only when someone commits to, or is asked to do, a concrete task. task is a short \
        imperative; owner is the person who will do it: the speaker when they say "I will", the person \
        addressed when the speaker asks someone else. due is the deadline exactly as spoken, if any; never \
        invent one.
        """

    /// System instructions for building the whole report in one pass.
    public static let reportInstructions = """
        You write the post-meeting report from a speech-recognition transcript. Lines look like \
        "[mm:ss] Speaker: text". Be faithful: include only what the transcript supports, and read past \
        obvious recognition errors.
        - title: a short meeting title (keep the given title when there is one).
        - overview: two to four sentences.
        - topics: the main topics in order, each with a short summary and the speakers involved.
        - decisions: final decisions as agreed. When someone corrected themselves, record the corrected version.
        - actionItems: concrete tasks, each once, with the owner's name, the deadline words someone actually said \
        (null when nobody named one; never a mm:ss timestamp), and the \
        mm:ss timestamp of the line where the task was agreed. The owner is the person who will do the task: \
        when one person asks another ("Sam, can you…"), the owner is the person asked, not the one asking. \
        Write tasks in the third person, without "I", "my" or "you".
        - notesToRemember: facts, numbers, dates, constraints and caveats worth remembering.
        - missedOpportunities: what could have been said, asked or followed up: unaddressed risks, tasks \
        without an owner or deadline, dependencies nobody checked, questions nobody asked.
        - openQuestions: questions raised but not resolved.
        - corrections: slips, self-corrections and misstatements: speaker, original wording, corrected \
        meaning, reason.
        - participantSummaries: for each participant who spoke, their key points.
        Leave a list empty rather than inventing items.
        """

    /// Map step: notes for one part of a meeting too long for a single request.
    public static let partNotesInstructions = """
        You take notes on one part of a longer meeting, from a speech-recognition transcript. Lines look \
        like "[mm:ss] Speaker: text". Be faithful: include only what this part supports.
        - title: a short title for this part. overview: two sentences.
        - topics with short summaries and speakers; decisions as agreed (corrected version when someone \
        corrected themselves); actionItems, each once, with the name of the person who will do the task (the \
        person asked, not the one asking), due only as spoken (null if none, never a timestamp) and the mm:ss timestamp of the line. Write tasks in \
        the third person, without "I", "my" or "you".
        - notesToRemember: facts, numbers, dates, constraints.
        - missedOpportunities: risks, follow-ups or questions nobody raised.
        - openQuestions: questions left unresolved in this part.
        - corrections: slips and self-corrections with speaker, original, corrected meaning and reason.
        - participantSummaries: key points per speaker in this part.
        Leave a list empty rather than inventing items.
        """

    /// Reduce step: merge notes from consecutive parts into one set.
    public static let mergeNotesInstructions = """
        You merge notes taken on consecutive parts of one meeting into a single set of notes for the \
        whole meeting. Remove duplicates. When a later decision supersedes an earlier one, keep only the \
        later one. Keep every distinct action item with its owner, due date and timestamp. Drop open \
        questions that a later part answered. Combine each participant's key points. Write a title and a \
        two to four sentence overview for everything covered. Do not add anything the notes do not support.
        """

    /// User turn for live analysis.
    public static func analysisPrompt(utterance: ContextLine, recentContext: [ContextLine]) -> String {
        var prompt = ""
        if recentContext.isEmpty {
            prompt += "Recent context: (none)\n\n"
        } else {
            prompt += "Recent context:\n" + TranscriptFormatter.format(recentContext) + "\n\n"
        }
        prompt += "New utterance:\n" + TranscriptFormatter.format(utterance)
        return prompt
    }

    /// User turn for a report over (part of) a transcript.
    public static func reportPrompt(
        transcript: [ContextLine], participants: [String], meetingTitle: String?, part: (index: Int, count: Int)? = nil
    ) -> String {
        var prompt = header(participants: participants, meetingTitle: meetingTitle, transcript: transcript)
        if let part, part.count > 1 {
            prompt += "This is part \(part.index + 1) of \(part.count).\n"
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
        let names = TranscriptFormatter.participantNames(participants: participants, transcript: transcript)
        if !names.isEmpty {
            header += "Participants: \(names.joined(separator: ", "))\n"
        }
        return header
    }
}

/// Renders transcript lines as `[mm:ss] Speaker: text`.
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

    public static func format(_ lines: [ContextLine]) -> String {
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

    /// Newlines inside an utterance would break the one-line-per-utterance format the models rely on.
    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
