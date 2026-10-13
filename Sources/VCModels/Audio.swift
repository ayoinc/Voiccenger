import Foundation

/// Which physical stream a piece of audio came from. Online meetings use both:
/// `.microphone` is the people in the room with this Mac, `.system` is remote participants.
public enum AudioChannel: String, Codable, Sendable, CaseIterable, Hashable {
    case microphone
    case system

    /// Prefix used to namespace speaker keys so a remote voice can never collide with a local one.
    public var keyPrefix: String {
        switch self {
        case .microphone: "mic"
        case .system: "sys"
        }
    }
}

/// A block of captured audio. Value type so it crosses actor boundaries without sharing buffers.
public struct AudioChunk: Sendable {
    public let channel: AudioChannel
    /// Seconds since the session clock origin at the first sample of this chunk.
    public let startTime: TimeInterval
    public let sampleRate: Double
    /// Mono mixdown, Float32 in [-1, 1].
    public let samples: [Float]
    /// De-interleaved raw channels, present only when capturing a multi-microphone array
    /// (needed for direction-of-arrival). `channelSamples[i]` is device channel `i`.
    public let channelSamples: [[Float]]?

    public init(
        channel: AudioChannel, startTime: TimeInterval, sampleRate: Double, samples: [Float],
        channelSamples: [[Float]]? = nil
    ) {
        self.channel = channel
        self.startTime = startTime
        self.sampleRate = sampleRate
        self.samples = samples
        self.channelSamples = channelSamples
    }

    public var duration: TimeInterval { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }
    public var range: TimeRange { TimeRange(start: startTime, end: startTime + duration) }
}

/// Shared time origin for every source in a session so mic, system audio,
/// transcripts and speaker turns land on one timeline.
public final class SessionClock: Sendable {
    public let origin: ContinuousClock.Instant

    public init(origin: ContinuousClock.Instant = .now) {
        self.origin = origin
    }

    /// Seconds elapsed since `origin`.
    public func now() -> TimeInterval {
        let d = ContinuousClock.now - origin
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}

/// Anything that produces audio chunks: microphone, system-audio tap, file playback.
public protocol AudioSource: AnyObject, Sendable {
    var channel: AudioChannel { get }
    /// Starts capture. The stream finishes after `stop()` or on unrecoverable error.
    func start() async throws -> AsyncStream<AudioChunk>
    func stop() async
}

public struct TimeRange: Codable, Sendable, Hashable {
    public var start: TimeInterval
    public var end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = max(start, end)
    }

    public var duration: TimeInterval { end - start }

    /// Length of the intersection with `other` (0 when disjoint).
    public func overlap(with other: TimeRange) -> TimeInterval {
        max(0, min(end, other.end) - max(start, other.start))
    }

    public func contains(_ t: TimeInterval) -> Bool { t >= start && t < end }
}
