import Foundation
import VCModels
import os

let intelligenceLog = Logger(subsystem: "com.voiccenger.app", category: "intelligence")

/// The request kinds a language-model report is built from.
public enum ReportRequestKind: String, Sendable, CaseIterable {
    /// Title, overview, topics and participants' key points of the meeting or one part.
    case summary
    /// Decisions, action items, notes, questions and corrections of the meeting or one part.
    case lists
    /// The conversation outline of one transcript chunk.
    case outline
    /// Part summaries merged into the meeting's.
    case merge
}

/// What happened while a report was written: every request and how it was answered, the chunks halved after a
/// refusal, the lines handled without AI, and engines standing in for others. Recording is opt-in: set
/// `ReportTrace.current` around the report (`ReportTrace.$current.withValue(trace) { … }`); requests in child
/// tasks record into it too. Holds line numbers and counts only, never transcript text.
public final class ReportTrace: Sendable {
    @TaskLocal public static var current: ReportTrace?

    public enum Outcome: String, Sendable {
        /// Answered on the first try.
        case answered
        /// Refused, then answered by the retry with permissive guardrails.
        case answeredOnRetry
        /// Refused, and refused again on the retry.
        case refusedAfterRetry
        /// Refused, and the retry's answer could not be used (not the JSON asked for, or too long).
        case retryFailed
        /// Refused, with no retry possible.
        case refused
    }

    public enum Event: Sendable, Equatable {
        /// One request over transcript lines `lines` (1-based `L` numbers; nil for a merge).
        case request(ReportRequestKind, lines: ClosedRange<Int>?, outcome: Outcome)
        /// A refused chunk split in two.
        case bisected(ReportRequestKind, lines: ClosedRange<Int>)
        /// Lines whose request stayed refused at the smallest size: handled without AI.
        case withoutAI(ReportRequestKind, lines: ClosedRange<Int>)
        /// `engine` could not write the report (`reason`); `fallback` wrote it.
        case engineFallback(engine: String, reason: String, fallback: String)
    }

    /// Totals over the events.
    public struct Summary: Sendable, Equatable {
        public var requests = 0
        public var refusals = 0
        public var retries = 0
        public var answeredOnRetry = 0
        public var bisections = 0
        /// Request kinds with lines handled without AI, and how many distinct lines each.
        public var linesWithoutAI: [ReportRequestKind: Int] = [:]
        public var engineFallbacks = 0
    }

    private let recorded = Mutex<[Event]>([])

    public init() {}

    public var events: [Event] { recorded.withLock { $0 } }

    public func record(_ event: Event) {
        recorded.withLock { $0.append(event) }
    }

    /// Records into the current trace, if any.
    static func record(_ event: Event) {
        current?.record(event)
    }

    public var summary: Summary {
        var summary = Summary()
        var withoutAI: [ReportRequestKind: Set<Int>] = [:]
        for event in events {
            switch event {
            case .request(_, _, let outcome):
                summary.requests += 1
                switch outcome {
                case .answered: break
                case .refused: summary.refusals += 1
                case .answeredOnRetry:
                    summary.refusals += 1
                    summary.retries += 1
                    summary.answeredOnRetry += 1
                case .refusedAfterRetry, .retryFailed:
                    summary.refusals += 1
                    summary.retries += 1
                }
            case .bisected: summary.bisections += 1
            case .withoutAI(let kind, let lines): withoutAI[kind, default: []].formUnion(lines)
            case .engineFallback: summary.engineFallbacks += 1
            }
        }
        summary.linesWithoutAI = withoutAI.mapValues(\.count)
        return summary
    }

    /// One line per event that was not a plain answer, for the command line.
    public var details: [String] {
        events.compactMap { event in
            switch event {
            case .request(let kind, let lines, let outcome):
                let span = lines.map { " L\($0.lowerBound)–L\($0.upperBound)" } ?? ""
                switch outcome {
                case .answered: return nil
                case .answeredOnRetry: return "\(kind.rawValue)\(span): refused, answered on the permissive retry"
                case .refusedAfterRetry: return "\(kind.rawValue)\(span): refused, and refused again on the permissive retry"
                case .retryFailed: return "\(kind.rawValue)\(span): refused; the permissive retry's answer was unusable"
                case .refused: return "\(kind.rawValue)\(span): refused"
                }
            case .bisected(let kind, let lines):
                return "\(kind.rawValue) L\(lines.lowerBound)–L\(lines.upperBound): split in two"
            case .withoutAI(let kind, let lines):
                return "\(kind.rawValue) L\(lines.lowerBound)–L\(lines.upperBound): handled without AI"
            case .engineFallback(let engine, let reason, let fallback):
                return "\(engine) failed (\(reason)); \(fallback) wrote the report"
            }
        }
    }
}
