import Foundation
import VCIntelligence
import VCModels

/// Engine selection and report generation shared by live sessions and saved meetings.
public enum ReportWriter {
    public enum ReportWriterError: LocalizedError {
        case emptyTranscript

        public var errorDescription: String? {
            switch self {
            case .emptyTranscript: "Nothing was transcribed, so there is no report."
            }
        }
    }

    /// The preferred engine; else the other language model; else the transcript outline, which runs on every Mac.
    /// `isFallback` is true when the preferred one was unavailable.
    public static func engine(preferring kind: IntelligenceEngineKind) -> (engine: any MeetingIntelligence, isFallback: Bool) {
        if let e = IntelligenceFactory.make(kind: kind) { return (e, false) }
        let order: [IntelligenceEngineKind] = kind == .claude ? [.apple] : [.claude, .apple]
        for fallback in order where fallback != kind {
            if let e = IntelligenceFactory.make(kind: fallback) { return (e, true) }
        }
        return (TranscriptOutlineEngine(), true)
    }

    /// The meeting's transcript in time order, with display names, as given to the language model.
    public static func transcript(of m: Meeting) -> [ContextLine] {
        m.segments.sorted { $0.range.start < $1.range.start }.map {
            ContextLine(
                segmentID: $0.id, speaker: ReportRenderer.displayName(for: $0.speakerKey, in: m), time: $0.range.start,
                text: $0.text, end: $0.range.end)
        }
    }

    /// Writes the report for `m`. `title` is a user-chosen title the engine should keep (nil lets it propose one).
    /// The user always gets a report: when `engine` cannot write one (its model declined the meeting, or failed),
    /// the next of `fallbacks` writes it (by default the other language model when it can run, then the transcript
    /// outline), with a notice saying so. Throws only when every engine failed, or when cancelled.
    public static func report(
        for m: Meeting, engine: any MeetingIntelligence, title: String?, fallbacks: [any MeetingIntelligence]? = nil
    ) async throws -> MeetingReport {
        guard !m.segments.isEmpty else { throw ReportWriterError.emptyTranscript }
        let lines = transcript(of: m)
        let participants = ReportRenderer.speakingParticipants(m).map(\.displayName)
        let failure: any Error
        do {
            return try await engine.report(transcript: lines, participants: participants, meetingTitle: title)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            failure = error
        }
        var last = (engine: engine, error: failure)
        for fallback in fallbacks ?? Self.fallbacks(after: engine) {
            ReportTrace.current?.record(
                .engineFallback(engine: last.engine.engineName, reason: last.error.localizedDescription, fallback: fallback.engineName))
            do {
                var report = try await fallback.report(transcript: lines, participants: participants, meetingTitle: title)
                report.notices.insert(fallbackNotice(failed: engine, error: failure, fallback: fallback, report: report, meeting: m), at: 0)
                return report
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                last = (fallback, error)
            }
        }
        throw last.error
    }

    /// Engines that stand in when `engine` fails: the other language model when it can run, then the transcript
    /// outline (none after the transcript outline itself).
    public static func fallbacks(after engine: any MeetingIntelligence) -> [any MeetingIntelligence] {
        guard !(engine is TranscriptOutlineEngine) else { return [] }
        let other: IntelligenceEngineKind = engine is ClaudeEngine ? .apple : .claude
        return [IntelligenceFactory.make(kind: other)].compactMap { $0 } + [TranscriptOutlineEngine()]
    }

    /// What the reader is told when `fallback` wrote the report because `failed` could not.
    static func fallbackNotice(
        failed: any MeetingIntelligence, error: any Error, fallback: any MeetingIntelligence, report: MeetingReport, meeting: Meeting
    ) -> ReportNotice {
        let why = if case IntelligenceError.refused = error {
            "\(failed.engineName) declined to write a report for this meeting"
        } else {
            "\(failed.engineName) couldn't write this report (\(error.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: ". "))))"
        }
        guard report.kind == .transcriptOutline else {
            return ReportNotice(reason: .engineFallback, message: "\(why), so \(fallback.engineName) wrote it instead.")
        }
        let spoken = meeting.segments.map(\.range.end).max().map { end in end - (meeting.segments.map(\.range.start).min() ?? 0) } ?? 0
        return ReportNotice(
            reason: .engineFallback,
            message: "\(why), so this report was built from the transcript without AI (\(ReportRenderer.durationText(spoken))).",
            timeWithoutAI: spoken)
    }
}
