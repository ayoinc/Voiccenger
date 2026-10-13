import Foundation
import Testing
import VCModels

@testable import VCPipeline

private func final(_ text: String, _ start: Double, _ end: Double, channel: AudioChannel = .microphone) -> TranscriptUpdate {
    TranscriptUpdate(channel: channel, text: text, range: TimeRange(start: start, end: end), confidence: 0.9, localeID: "en-US")
}

@Suite("PendingAlignmentQueue")
struct PendingAlignmentQueueTests {
    @Test("A final is held until diarization covers the end of its range")
    func waitsForCoverage() {
        var q = PendingAlignmentQueue(timeout: 15)
        q.enqueue(final("first", 0, 4), at: 4.2)
        #expect(q.release(now: 5).isEmpty)

        q.advanceCoverage(to: 3.9, for: .microphone)
        #expect(q.release(now: 6).isEmpty, "coverage just short of the end must not release")

        q.advanceCoverage(to: 4.0, for: .microphone)
        #expect(q.release(now: 6).map(\.text) == ["first"])
        #expect(q.isEmpty)
    }

    @Test("Coverage never moves backwards")
    func coverageMonotonic() {
        var q = PendingAlignmentQueue(timeout: nil)
        q.advanceCoverage(to: 10, for: .microphone)
        q.advanceCoverage(to: 5, for: .microphone)
        #expect(q.coverage(for: .microphone) == 10)
        #expect(q.coverage(for: .system) == -.infinity)
    }

    @Test("After the timeout a final is released with whatever turns exist")
    func timeoutReleases() {
        var q = PendingAlignmentQueue(timeout: 15)
        q.enqueue(final("late", 0, 3), at: 3)
        #expect(q.release(now: 17.9).isEmpty)
        #expect(q.release(now: 18).map(\.text) == ["late"])
    }

    @Test("Without a timeout (offline) nothing is released until covered or drained")
    func offlineWaitsIndefinitely() {
        var q = PendingAlignmentQueue(timeout: nil)
        q.enqueue(final("a", 0, 2), at: 2)
        q.enqueue(final("b", 2, 4), at: 4)
        #expect(q.release(now: 10_000).isEmpty)
        #expect(q.drain().map(\.text) == ["a", "b"])
        #expect(q.isEmpty)
    }

    @Test("Within a channel, an uncovered final holds back later ones so text never reorders")
    func noReorderingWithinChannel() {
        var q = PendingAlignmentQueue(timeout: 15)
        // A long utterance followed by a short one that ends earlier than the coverage point would allow
        // the second to overtake the first if entries were released independently.
        q.enqueue(final("long", 0, 12), at: 12)
        q.enqueue(final("short", 12, 13), at: 13)
        q.advanceCoverage(to: 11, for: .microphone)
        #expect(q.release(now: 14).isEmpty)
        q.advanceCoverage(to: 13, for: .microphone)
        #expect(q.release(now: 14).map(\.text) == ["long", "short"])
    }

    @Test("Channels are independent and released finals are ordered by start time")
    func channelsIndependent() {
        var q = PendingAlignmentQueue(timeout: 15)
        q.enqueue(final("room", 5, 6), at: 6)
        q.enqueue(final("remote", 1, 2, channel: .system), at: 6.5)
        q.advanceCoverage(to: 10, for: .system)
        #expect(q.release(now: 7).map(\.text) == ["remote"], "the uncovered microphone final must not block the system channel")
        q.markComplete(.microphone)
        q.enqueue(final("remote 2", 7, 8, channel: .system), at: 8)
        q.enqueue(final("room 2", 3, 4), at: 8)
        let released = q.release(now: 8)
        #expect(released.map(\.text) == ["room 2", "room", "remote 2"])
    }

    @Test("Marking a channel complete releases everything pending on it")
    func markCompleteReleases() {
        var q = PendingAlignmentQueue(timeout: nil)
        q.enqueue(final("x", 100, 200), at: 200)
        q.markComplete(.microphone)
        #expect(q.release(now: 0).map(\.text) == ["x"])
    }
}
