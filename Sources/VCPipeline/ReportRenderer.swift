import Foundation
import VCModels

/// Renders a meeting (report + attributed transcript) as Markdown.
public enum ReportRenderer {
    public static func markdown(_ m: Meeting) -> String {
        var out: [String] = []
        out.append("# \(m.report?.title.nonEmpty ?? m.title)")
        out.append("")
        out.append(contentsOf: metadata(m))
        out.append("")

        if let r = m.report {
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
        } else {
            out.append("> No report was generated for this meeting.")
            out.append("")
        }

        out.append(contentsOf: section("Participants", participantTable(m)))
        out.append(contentsOf: section("Transcript", transcript(m), trailingBlank: false))
        return out.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
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
        if !m.participants.isEmpty {
            lines.append("- **Participants:** \(m.participants.map(\.displayName).joined(separator: ", "))")
        }
        if !m.localeIDs.isEmpty { lines.append("- **Languages:** \(m.localeIDs.joined(separator: ", "))") }
        if let r = m.report { lines.append("- **Report by:** \(r.generatedBy)") }
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

    private static func participantTable(_ m: Meeting) -> [String] {
        guard !m.participants.isEmpty else { return [] }
        var lines = [
            "| Name | Source | Language | Seat | Speaking time |",
            "| --- | --- | --- | --- | --- |",
        ]
        for p in m.participants {
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
