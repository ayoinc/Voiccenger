import Foundation
import VCModels
import VCTranscription

/// Renders a meeting (report + attributed transcript) as Markdown.
public enum ReportRenderer {
    public static func markdown(_ m: Meeting) -> String {
        var out: [String] = []
        out.append("# \(m.report?.title.nonEmpty ?? m.title)")
        out.append("")
        out.append(contentsOf: metadata(m))
        out.append("")

        if let r = m.report, r.kind == .transcriptOutline {
            out.append(contentsOf: transcriptOutlineSections(r))
        } else if let r = m.report {
            out.append(contentsOf: section("Overview", r.overview.nonEmpty.map { [$0] } ?? []))
            out.append(contentsOf: section("Topics", r.topics.map { topic in
                var line = "- **\(topic.title)**"
                if !topic.summary.isEmpty { line += " — \(topic.summary)" }
                if !topic.speakers.isEmpty { line += " _(\(topic.speakers.joined(separator: ", ")))_" }
                return line
            }))
            out.append(contentsOf: section("Decisions", r.decisions.map { "- \($0)" }))
            out.append(contentsOf: section("Action Items", r.actionItems.map(actionLine)))
            out.append(contentsOf: section("Notes to Remember", r.notesToRemember.map { "- \($0)" }))
            out.append(contentsOf: section("Things That Could Have Been Said", r.missedOpportunities.map { "- \($0)" }))
            out.append(contentsOf: section("Open Questions", r.openQuestions.map { "- \($0)" }))
            out.append(contentsOf: section("Corrections", r.corrections.map { c in
                var line = "- **\(c.speaker)**: “\(c.original)” → “\(c.corrected)”"
                if !c.reason.isEmpty { line += " — \(c.reason)" }
                return line
            }))
            out.append(contentsOf: section("Participant Summaries", r.participantSummaries.flatMap { p -> [String] in
                ["### \(p.name)", ""] + (p.keyPoints.isEmpty ? ["_No key points._"] : p.keyPoints.map { "- \($0)" })
                    + [""]
            }, trailingBlank: false))
            // Reports written before the outline existed have none.
            if !r.outline.isEmpty {
                out.append(contentsOf: section("Conversation Outline", outline(r.outline, extractedNote: true), trailingBlank: false))
            }
        } else {
            out.append("> No report was generated for this meeting.")
            out.append("")
        }

        out.append(contentsOf: section("Participants", participantTable(m)))
        out.append(contentsOf: section("Transcript", transcript(m), trailingBlank: false))
        return out.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }

    /// How a report without a language model is labelled wherever it is shown.
    public static let transcriptOutlineNote =
        "Built from the transcript without a language model: points are sentences quoted as spoken, questions are lines someone asked, and action items are only possible ones, found by phrases such as “I'll” or “can you”."

    /// How an outline segment filled in from the transcript is labelled in a language-model report.
    public static let extractedSegmentNote = "Not in the AI outline: quoted from the transcript."

    /// How an outline segment whose lines the safety filter declined is labelled.
    public static let declinedSegmentNote = "Apple Intelligence's safety filter declined this part; quoted from the transcript."

    /// The label of an outline segment built from the transcript in a language-model report, if it has one.
    public static func segmentNote(_ segment: OutlineSegment) -> String? {
        segment.isDeclined ? declinedSegmentNote : segment.isExtracted ? extractedSegmentNote : nil
    }

    /// `[mm:ss–mm:ss]` for an outline segment.
    public static func timeRange(_ start: TimeInterval, _ end: TimeInterval) -> String {
        "[\(timestamp(start))–\(timestamp(end))]"
    }

    /// `mm:ss` (or `h:mm:ss`) for a session offset.
    public static func timestamp(_ t: TimeInterval) -> String {
        let total = max(0, Int(t.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    /// Human duration, e.g. "1 h 4 min", "48 s".
    public static func durationText(_ d: TimeInterval) -> String {
        let total = max(0, Int(d.rounded()))
        if total < 60 { return "\(total) s" }
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h) h \(m) min" : "\(m) min"
    }

    public static func displayName(for key: String, in m: Meeting) -> String {
        m.participant(key)?.displayName ?? key
    }

    // MARK: - Pieces

    private static func metadata(_ m: Meeting) -> [String] {
        var lines: [String] = []
        let date = m.startedAt.formatted(date: .complete, time: .shortened)
        lines.append("- **Date:** \(date)")
        if let end = m.endedAt {
            lines.append("- **Duration:** \(durationText(end.timeIntervalSince(m.startedAt)))")
        }
        let kind = m.kind == .online ? "Online" + (m.appName.map { " (\($0))" } ?? "") : "In person"
        lines.append("- **Type:** \(kind)")
        let speaking = speakingParticipants(m)
        if !speaking.isEmpty {
            lines.append("- **Participants:** \(speaking.map(\.displayName).joined(separator: ", "))")
        }
        if !m.localeIDs.isEmpty { lines.append("- **Languages:** \(m.localeIDs.joined(separator: ", "))") }
        if let engine = transcriptionEngine(m) {
            lines.append("- **Transcribed by:** \(SpeechModelLibrary.info(engine).displayName)")
        }
        if let r = m.report {
            lines.append("- **Report by:** \(r.generatedBy)")
            for notice in r.notices { lines.append("- **Report note:** \(notice.message)") }
        }
        for warning in m.captureWarnings { lines.append("- **Capture warning:** \(warning.message)") }
        return lines
    }

    private static func section(_ title: String, _ body: [String], trailingBlank: Bool = true) -> [String] {
        var lines = ["## \(title)", ""]
        lines.append(contentsOf: body.isEmpty ? ["_None._"] : body)
        if trailingBlank || body.isEmpty { lines.append("") }
        return lines
    }

    private static func actionLine(_ a: ActionItem) -> String {
        var line = "- [ ] \(a.task)"
        var meta: [String] = []
        if let owner = a.owner?.nonEmpty { meta.append("owner: **\(owner)**") }
        if let due = a.due?.nonEmpty { meta.append("due: \(due)") }
        if !meta.isEmpty { line += " — " + meta.joined(separator: ", ") }
        return line
    }

    /// The report of the transcript outline engine, labelled as not written by AI.
    private static func transcriptOutlineSections(_ r: MeetingReport) -> [String] {
        var lines = ["> **\(r.generatedBy).** \(transcriptOutlineNote)", ""]
        lines += section("Summary", r.overview.nonEmpty.map { [$0] } ?? [])
        lines += section("Transcript Outline (no AI)", outline(r.outline, extractedNote: false), trailingBlank: false)
        lines += section("Questions Asked", r.openQuestions.map { "- \($0)" })
        lines += section("Possible Action Items (not verified)", r.actionItems.map(actionLine))
        return lines
    }

    /// `### [mm:ss–mm:ss] Heading` per segment, then one bullet per point: speaker, text (quoted when it is the
    /// speaker's own sentence) and when it was said. `extractedNote` marks segments filled from the transcript.
    private static func outline(_ segments: [OutlineSegment], extractedNote: Bool) -> [String] {
        segments.flatMap { segment -> [String] in
            var lines = ["### \(timeRange(segment.start, segment.end)) \(segment.heading)", ""]
            if extractedNote, let note = segmentNote(segment) {
                lines += ["_\(note)_", ""]
            }
            lines += segment.points.map { point in
                let text = point.isQuote ? "“\(point.text)”" : point.text
                return "- **\(point.speaker):** \(text) _(\(timestamp(point.time)))_"
            }
            return lines + [""]
        }
    }

    /// Participants with at least one transcript line. Diarization blips (a second of audio clustered as a new
    /// voice, never transcribed) stay in the meeting data but are not people in the report.
    public static func speakingParticipants(_ m: Meeting) -> [Participant] {
        let speakers = Set(m.segments.map(\.speakerKey))
        return m.participants.filter { speakers.contains($0.id) }
    }

    /// The voice model that transcribed most segments; nil when no segment records one.
    public static func transcriptionEngine(_ m: Meeting) -> SpeechEngineKind? {
        var counts: [SpeechEngineKind: Int] = [:]
        for engine in m.segments.compactMap(\.engine) { counts[engine, default: 0] += 1 }
        // Ties go to the engine listed first, so the result does not depend on dictionary order.
        return SpeechEngineKind.allCases.reduce(nil) { best, kind in
            counts[kind, default: 0] > best.map { counts[$0, default: 0] } ?? 0 ? kind : best
        }
    }

    private static func participantTable(_ m: Meeting) -> [String] {
        let participants = speakingParticipants(m)
        guard !participants.isEmpty else { return [] }
        var lines = [
            "| Name | Source | Language | Seat | Speaking time |",
            "| --- | --- | --- | --- | --- |",
        ]
        for p in participants {
            let source = p.channel == .microphone ? "In room" : "Remote"
            let enrolled = p.isEnrolled ? " (enrolled)" : ""
            let seat = p.seatAzimuthDegrees.map { String(format: "%.0f°", $0) } ?? "—"
            lines.append(
                "| \(escapeCell(p.displayName))\(enrolled) | \(source) | \(p.localeID ?? "—") | \(seat) | \(durationText(p.speakingTime)) |"
            )
        }
        return lines
    }

    private static func transcript(_ m: Meeting) -> [String] {
        var lines: [String] = []
        for s in m.segments.sorted(by: { $0.range.start < $1.range.start }) {
            lines.append("**[\(timestamp(s.range.start))] \(displayName(for: s.speakerKey, in: m))** `\(s.localeID)`: \(s.text)")
            if let corrected = s.insight?.correctedText?.nonEmpty {
                var note = "> *Correction:* “\(corrected)”"
                if let reason = s.insight?.correctionReason?.nonEmpty { note += " — \(reason)" }
                lines.append(note)
            }
            lines.append("")
        }
        return lines
    }

    private static func escapeCell(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|") }
}

extension String {
    /// Nil when empty after trimming whitespace.
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
