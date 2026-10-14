import Foundation
import Synchronization

/// One WebSocket to Deepgram's live endpoint. Sends are queued in call order and never block; a failed send
/// surfaces as an error from `receive()`. Tests substitute a scripted socket.
protocol DeepgramSocket: AnyObject, Sendable {
    /// Starts the handshake and waits for it. Throws `DeepgramError` (`.invalidKey` for HTTP 401/403).
    func open() async throws
    func send(_ data: Data)
    func send(text: String)
    /// The next text message; nil once the server closed the stream normally or `close()` was called.
    func receive() async throws -> String?
    func close()
}

/// `URLSessionWebSocketTask` with its own session, whose delegate reports the handshake.
final class URLSessionDeepgramSocket: DeepgramSocket, @unchecked Sendable {
    // @unchecked: every stored property is immutable and thread-safe (URLSession, its task and a Mutex-guarded
    // delegate); older SDKs don't annotate URLSessionWebSocketTask as Sendable.
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let delegate: Delegate

    init(request: URLRequest) {
        delegate = Delegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        task = session.webSocketTask(with: request)
    }

    func open() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                delegate.onOpen(continuation)
                task.resume()
            }
        } onCancel: {
            close()
        }
    }

    func send(_ data: Data) {
        task.send(.data(data)) { [delegate] error in if let error { delegate.sendFailed(error) } }
    }

    func send(text: String) {
        task.send(.string(text)) { [delegate] error in if let error { delegate.sendFailed(error) } }
    }

    func receive() async throws -> String? {
        if let error = delegate.sendError { throw DeepgramError.unreachable(error.localizedDescription) }
        do {
            switch try await task.receive() {
            case .string(let text): return text
            case .data(let data): return String(decoding: data, as: UTF8.self)
            @unknown default: return ""
            }
        } catch {
            if task.closeCode == .normalClosure || delegate.isClosedLocally { return nil }
            let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) }?.nonEmptyTrimmed
            if let reason { throw DeepgramError.requestFailed(task.closeCode.rawValue, reason) }
            throw DeepgramError.unreachable(error.localizedDescription)
        }
    }

    func close() {
        delegate.markClosed()
        task.cancel(with: .normalClosure, reason: nil)
        session.finishTasksAndInvalidate()
    }

    private final class Delegate: NSObject, URLSessionWebSocketDelegate, Sendable {
        private struct State {
            var opening: CheckedContinuation<Void, any Error>?
            var opened = false
            var closedLocally = false
            var sendError: (any Error)?
        }

        private let state = Mutex(State())

        var sendError: (any Error)? { state.withLock { $0.sendError } }
        var isClosedLocally: Bool { state.withLock { $0.closedLocally } }

        func onOpen(_ continuation: CheckedContinuation<Void, any Error>) {
            state.withLock { $0.opening = continuation }
        }

        func sendFailed(_ error: any Error) {
            state.withLock { if $0.sendError == nil { $0.sendError = error } }
        }

        func markClosed() {
            let pending = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                state.closedLocally = true
                defer { state.opening = nil }
                return state.opening
            }
            pending?.resume(throwing: CancellationError())
        }

        func urlSession(
            _ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?
        ) {
            let pending = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                state.opened = true
                defer { state.opening = nil }
                return state.opening
            }
            pending?.resume()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            let pending = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                defer { state.opening = nil }
                return state.opening
            }
            guard let pending else { return }
            let status = (task.response as? HTTPURLResponse)?.statusCode
            if let status, let failure = DeepgramError.status(status, body: Data()) {
                pending.resume(throwing: failure)
            } else {
                pending.resume(throwing: DeepgramError.unreachable(error?.localizedDescription ?? "connection closed"))
            }
        }
    }
}

extension String {
    fileprivate var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
