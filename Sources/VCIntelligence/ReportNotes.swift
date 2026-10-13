import Foundation

/// Text form and shrinking of intermediate report notes, used by the map-reduce report on small context windows.
enum ReportNotes {
    /// Compact plain-text rendering fed to the merge step; items keep their line citations as "(L3, L7)" so
    /// merged notes still cite the transcript. Empty sections are omitted.
    static func render(_ notes: RawReport) -> String {
        var lines: [String] = []
        if let title = notes.title { lines.append("Title: \(title)") }
        if let overview = notes.overview { lines.append("Overview: \(overview)") }
        section("Topics", notes.topics.compactMap { topic in
            guard let title = topic.title else { return nil }
            var line = title
            if let summary = topic.summary { line += ": \(summary)" }
            if !topic.speakers.isEmpty { line += " (\(topic.speakers.joined(separator: ", ")))" }
            return line
        }, into: &lines)
        section("Decisions", notes.decisions.compactMap(cited), into: &lines)
        section("Action items", notes.actionItems.compactMap { item in
            guard let task = item.task else { return nil }
            var line = task
            if let owner = item.owner { line += " | owner: \(owner)" }
            if let due = item.due { line += " | due: \(due)" }
            return line + citation(item.lines)
        }, into: &lines)
        section("Notes to remember", notes.notesToRemember.compactMap(cited), into: &lines)
        section("Missed opportunities", notes.missedOpportunities, into: &lines)
        section("Open questions", notes.openQuestions.compactMap(cited), into: &lines)
        section("Corrections", notes.corrections.compactMap { note in
            guard let original = note.original, let corrected = note.corrected else { return nil }
            var line = "\(note.speaker ?? "Someone"): \"\(original)\" -> \"\(corrected)\""
            if let kind = note.kind { line += " [\(kind)]" }
            return line + citation(note.lines)
        }, into: &lines)
        section("Participants", notes.participantSummaries.compactMap { participant in
            guard let name = participant.name, !participant.keyPoints.isEmpty else { return nil }
            return "\(name): " + participant.keyPoints.compactMap(cited).joined(separator: "; ")
        }, into: &lines)
        return lines.joined(separator: "\n")
    }

    private static func cited(_ item: RawItem) -> String? {
        item.text.map { $0 + citation(item.lines) }
    }

    /// " (L3, L7)", or nothing for an item citing no lines.
    private static func citation(_ lines: [Int]) -> String {
        lines.isEmpty ? "" : " (" + lines.map { "L\($0)" }.joined(separator: ", ") + ")"
    }

    private static func section(_ title: String, _ items: [String], into lines: inout [String]) {
        guard !items.isEmpty else { return }
        lines.append("\(title):")
        lines.append(contentsOf: items.map { "- \($0)" })
    }

    /// Roughly halves the notes: every list keeps its first ⌈n/2⌉ items and the overview keeps its first
    /// sentence. Returns nil when nothing can shrink any further.
    static func compacted(_ notes: RawReport) -> RawReport? {
        var result = notes
        result.topics = halved(notes.topics)
        result.decisions = halved(notes.decisions)
        result.actionItems = halved(notes.actionItems)
        result.notesToRemember = halved(notes.notesToRemember)
        result.missedOpportunities = halved(notes.missedOpportunities)
        result.openQuestions = halved(notes.openQuestions)
        result.corrections = halved(notes.corrections)
        result.participantSummaries = halved(notes.participantSummaries).map {
            RawParticipant(name: $0.name, keyPoints: halved($0.keyPoints))
        }
        result.overview = notes.overview.map(firstSentence)
        return result == notes ? nil : result
    }

    private static func halved<T>(_ items: [T]) -> [T] {
        Array(items.prefix((items.count + 1) / 2))
    }

    private static func firstSentence(_ text: String) -> String {
        var sentence = ""
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { substring, _, _, stop in
            sentence = substring ?? ""
            stop = true
        }
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? text : trimmed
    }
}
