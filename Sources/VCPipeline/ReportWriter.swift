import Foundation
import VCIntelligence
import VCModels

/// Engine selection and report generation shared by live sessions and saved meetings.
public enum ReportWriter {
    public enum ReportWriterError: LocalizedError {
        case noEngine
        case emptyTranscript

        public var errorDescription: String? {
            switch self {
            case .noEngine: "No intelligence engine is available to write the report."
            case .emptyTranscript: "Nothing was transcribed, so there is no report."
            }
        }
    }

    /// The preferred engine, else the other one. `isFallback` is true when the preferred one was unavailable.
    public static func engine(preferring kind: IntelligenceEngineKind) -> (engine: any MeetingIntelligence, isFallback: Bool)? {
        if let e = IntelligenceFactory.make(kind: kind) { return (e, false) }
        let fallback: IntelligenceEngineKind = kind == .apple ? .claude : .apple
        if let e = IntelligenceFactory.make(kind: fallback) { return (e, true) }
        return nil
    }

    /// The meeting's transcript in time order, with display names, as given to the language model.
    public static func transcript(of m: Meeting) -> [ContextLine] {
        m.segments.sorted { $0.range.start < $1.range.start }.map {
            ContextLine(
                segmentID: $0.id, speaker: ReportRenderer.displayName(for: $0.speakerKey, in: m), time: $0.range.start,
                text: $0.text)
        }
    }

    /// Writes the report for `m`. `title` is a user-chosen title the engine should keep (nil lets it propose one).
    public static func report(
        for m: Meeting, engine: any MeetingIntelligence, title: String?
    ) async throws -> MeetingReport {
        guard !m.segments.isEmpty else { throw ReportWriterError.emptyTranscript }
        return try await engine.report(
            transcript: transcript(of: m), participants: ReportRenderer.speakingParticipants(m).map(\.displayName),
            meetingTitle: title)
    }
}
