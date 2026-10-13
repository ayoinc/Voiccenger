import Foundation
import VCModels

/// Holds final transcripts until diarization covers their time range.
///
/// Speaker identification works on fixed windows (≈10 s), so speaker turns for a stretch of audio arrive
/// well after the recognizer has finalized its text. A final is released once the channel's diarization
/// coverage reaches the end of its range, once it has waited longer than `timeout` (it is then aligned with
/// whatever turns exist), or when the channel's diarization is marked complete.
public struct PendingAlignmentQueue: Sendable {
    public struct Entry: Sendable, Hashable {
        public var update: TranscriptUpdate
        /// Session time at which the final was received.
        public var enqueuedAt: TimeInterval
    }

    /// Maximum wait in session seconds; nil waits for coverage (offline processing, where `drain()` ends it).
    public var timeout: TimeInterval?
    public private(set) var entries: [Entry] = []
    private var coverage: [AudioChannel: TimeInterval] = [:]

    public init(timeout: TimeInterval?) {
        self.timeout = timeout
    }

    public var isEmpty: Bool { entries.isEmpty }

    public mutating func enqueue(_ update: TranscriptUpdate, at now: TimeInterval) {
        entries.append(Entry(update: update, enqueuedAt: now))
    }

    /// Diarization for `channel` is final up to `time` (monotonic: lower values are ignored).
    public mutating func advanceCoverage(to time: TimeInterval, for channel: AudioChannel) {
        coverage[channel] = max(coverage[channel] ?? -.infinity, time)
    }

    /// No more turns will arrive for `channel` (identifier finished or unavailable).
    public mutating func markComplete(_ channel: AudioChannel) {
        coverage[channel] = .infinity
    }

    public func coverage(for channel: AudioChannel) -> TimeInterval { coverage[channel] ?? -.infinity }

    /// Removes and returns every entry that is ready, ordered by start time. Within a channel, entries are
    /// released in arrival order: a not-yet-ready entry holds back later ones so text never reorders.
    public mutating func release(now: TimeInterval) -> [TranscriptUpdate] {
        var blocked: Set<AudioChannel> = []
        var ready: [TranscriptUpdate] = []
        var kept: [Entry] = []
        for entry in entries {
            let channel = entry.update.channel
            if !blocked.contains(channel) && isReady(entry, now: now) {
                ready.append(entry.update)
            } else {
                blocked.insert(channel)
                kept.append(entry)
            }
        }
        entries = kept
        return ready.sorted { $0.range.start < $1.range.start }
    }

    /// Removes and returns everything (end of session), ordered by start time.
    public mutating func drain() -> [TranscriptUpdate] {
        defer { entries.removeAll() }
        return entries.map(\.update).sorted { $0.range.start < $1.range.start }
    }

    private func isReady(_ entry: Entry, now: TimeInterval) -> Bool {
        if coverage(for: entry.update.channel) >= entry.update.range.end { return true }
        if let timeout, now - entry.enqueuedAt >= timeout { return true }
        return false
    }
}
