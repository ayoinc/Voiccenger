import Foundation
import VCModels

/// Keeps offline input on one clock: a chunk is forwarded only once every consumer of every channel has taken the
/// audio up to `lead` seconds before it. A meeting's microphone and computer-audio recordings then replay together
/// (as they were captured) instead of one racing ahead, and decoded audio never piles up in front of a slow
/// consumer (a whole meeting at 48 kHz would be hundreds of MB per channel).
final class ReplayPacer: Sendable {
    let lead: TimeInterval
    private let state = Mutex(State())

    private struct State {
        var consumed: [Int: TimeInterval] = [:]
        var nextID = 0
        /// Nothing is forwarded until every channel's consumers are registered.
        var open = false
    }

    init(lead: TimeInterval = 4) {
        self.lead = lead
    }

    /// A new consumer, at the start of the audio.
    func register() -> Int {
        state.withLock { s in
            defer { s.nextID += 1 }
            s.consumed[s.nextID] = 0
            return s.nextID
        }
    }

    /// Every consumer is registered: forwarding may begin.
    func open() {
        state.withLock { $0.open = true }
    }

    func consumed(_ id: Int, through time: TimeInterval) {
        state.withLock { s in
            if let t = s.consumed[id] { s.consumed[id] = max(t, time) }
        }
    }

    /// The consumer's input ended; it no longer holds anything back.
    func finish(_ id: Int) {
        state.withLock { _ = $0.consumed.removeValue(forKey: id) }
    }

    /// Whether a chunk starting at `start` is within `lead` of every remaining consumer.
    func mayForward(_ start: TimeInterval) -> Bool {
        state.withLock { s in s.open && start <= (s.consumed.values.min() ?? .infinity) + lead }
    }

    /// Waits until a chunk starting at `start` may be forwarded (or the task is cancelled).
    func waitToForward(_ start: TimeInterval) async {
        while !mayForward(start), !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A consumer's stream that reports to the pacer: each pull means the previous chunk was consumed.
    func paced(_ stream: AsyncStream<AudioChunk>) -> AsyncStream<AudioChunk> {
        let cursor = Cursor(stream.makeAsyncIterator(), id: register(), pacer: self)
        return AsyncStream(unfolding: { await cursor.next() })
    }

    /// Iterates one consumer's stream. `@unchecked`: only the stream's single consumer calls `next()`, one call at
    /// a time.
    private final class Cursor: @unchecked Sendable {
        private var iterator: AsyncStream<AudioChunk>.Iterator
        private var previousEnd: TimeInterval?
        private let id: Int
        private let pacer: ReplayPacer

        init(_ iterator: AsyncStream<AudioChunk>.Iterator, id: Int, pacer: ReplayPacer) {
            self.iterator = iterator
            self.id = id
            self.pacer = pacer
        }

        func next() async -> AudioChunk? {
            if let previousEnd { pacer.consumed(id, through: previousEnd) }
            var it = iterator
            let chunk = await it.next()
            iterator = it
            if let chunk {
                previousEnd = chunk.range.end
            } else {
                pacer.finish(id)
            }
            return chunk
        }
    }
}
