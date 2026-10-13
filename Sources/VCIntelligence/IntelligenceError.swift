import Foundation

public enum IntelligenceError: LocalizedError, Sendable, Equatable {
    /// The engine cannot run on this Mac right now (reason is user-facing).
    case unavailable(String)
    /// Non-2xx HTTP response, with the API's error type and message when it sent one.
    case http(status: Int, type: String?, message: String)
    /// The response did not contain the structured output that was asked for.
    case malformedResponse(String)
    /// The model stopped before finishing the structured output.
    case truncatedResponse
    /// The model declined to answer.
    case refused(String?)
    /// The transcript is larger than one request can carry.
    case transcriptTooLong(characters: Int, limit: Int)
    /// Even the smallest possible request does not fit the model's context window.
    case contextWindowExceeded

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            reason
        case .http(let status, let type, let message):
            "HTTP \(status)\(type.map { " \($0)" } ?? ""): \(message)"
        case .malformedResponse(let detail):
            "The model's response could not be read: \(detail)"
        case .truncatedResponse:
            "The model's response was cut off before it was complete."
        case .refused(let detail):
            "The model declined to answer\(detail.map { ": \($0)" } ?? ".")"
        case .transcriptTooLong(let characters, let limit):
            "The transcript has \(characters) characters; the limit for one request is \(limit)."
        case .contextWindowExceeded:
            "The text does not fit in the model's context window."
        }
    }
}
