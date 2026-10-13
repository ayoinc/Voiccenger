import CoreAudio
import Foundation
import Synchronization
import VCModels

/// Debounces snapshots of "which meeting apps are using the microphone" into start/end events.
///
/// An app counts as started once it has been seen continuously for `startDelay` (a flap resets the
/// count) and as ended once it has been absent for `endDelay`. Apps are tracked independently, keyed by
/// display name so an app's helper processes and companion daemons (FaceTime + avconferenced, Safari +
/// WebKit GPU) count as one meeting. Pure: time is passed in, so it is unit-testable.
public struct MeetingDetectionStateMachine: Sendable {
    public struct Observation: Sendable, Hashable {
        public let app: MeetingApp
        public let processIDs: [Int32]

        public init(app: MeetingApp, processIDs: [Int32]) {
            self.app = app
            self.processIDs = processIDs
        }
    }

    private struct Track: Sendable {
        var app: MeetingApp
        var processIDs: [Int32]
        /// When the app was first seen in the current unbroken run of observations.
        var seenSince: TimeInterval?
        var lastSeen: TimeInterval
        var meeting: DetectedMeeting?
    }

    public let startDelay: TimeInterval
    public let endDelay: TimeInterval
    private var tracks: [String: Track] = [:]

    public init(startDelay: TimeInterval = 2, endDelay: TimeInterval = 5) {
        self.startDelay = startDelay
        self.endDelay = endDelay
    }

    /// Meetings currently considered in progress, by app display name.
    public var activeMeetings: [DetectedMeeting] {
        tracks.values.compactMap(\.meeting).sorted { $0.app.displayName < $1.app.displayName }
    }

    /// Feeds one snapshot taken at monotonic `time` (seconds); `date` stamps new meetings.
    public mutating func update(_ observations: [Observation], at time: TimeInterval, date: Date = Date()) -> [MeetingDetectionEvent] {
        var seen: [String: Observation] = [:]
        for o in observations {
            let key = o.app.displayName
            if let existing = seen[key] {
                seen[key] = Observation(app: existing.app, processIDs: Array(Set(existing.processIDs + o.processIDs)).sorted())
            } else {
                seen[key] = Observation(app: o.app, processIDs: Array(Set(o.processIDs)).sorted())
            }
        }

        var ended: [MeetingDetectionEvent] = []
        var started: [MeetingDetectionEvent] = []
        for key in Set(tracks.keys).union(seen.keys).sorted() {
            if let o = seen[key] {
                var track = tracks[key] ?? Track(app: o.app, processIDs: o.processIDs, seenSince: nil, lastSeen: time)
                if track.seenSince == nil { track.seenSince = time }
                track.lastSeen = time
                track.processIDs = o.processIDs
                if track.meeting == nil, let since = track.seenSince, time - since >= startDelay {
                    let meeting = DetectedMeeting(app: track.app, processIDs: track.processIDs, startedAt: date)
                    track.meeting = meeting
                    started.append(.meetingStarted(meeting))
                }
                tracks[key] = track
            } else if var track = tracks[key] {
                track.seenSince = nil
                if let meeting = track.meeting {
                    if time - track.lastSeen >= endDelay {
                        ended.append(.meetingEnded(meeting))
                        tracks[key] = nil
                    } else {
                        tracks[key] = track
                    }
                } else {
                    // Never confirmed: forget it so a later appearance restarts the start debounce.
                    tracks[key] = nil
                }
            }
        }
        return ended + started
    }

    /// Groups raw microphone users into catalog apps (helper processes map to their parent app).
    public static func observations(from processes: [(bundleID: String, pid: Int32)]) -> [Observation] {
        var byApp: [MeetingApp: [Int32]] = [:]
        for p in processes {
            guard let app = MeetingAppCatalog.app(forBundleID: p.bundleID) else { continue }
            byApp[app, default: []].append(p.pid)
        }
        return byApp.map { Observation(app: $0.key, processIDs: $0.value.sorted()) }
            .sorted { $0.app.bundleID < $1.app.bundleID }
    }
}

/// Polls Core Audio process objects (kAudioHardwarePropertyProcessObjectList, kAudioProcessPropertyIsRunningInput, kAudioProcessPropertyBundleID/PID). Debounced start (≥2 s) and end (≥5 s).
public final class MeetingDetector: Sendable {
    private let pollInterval: TimeInterval
    private let origin = ContinuousClock.now
    private let state = Mutex(State())

    private struct State {
        var machine = MeetingDetectionStateMachine()
        var continuations: [UUID: AsyncStream<MeetingDetectionEvent>.Continuation] = [:]
        var task: Task<Void, Never>?
        var stopped = false
    }

    public init(pollInterval: TimeInterval = 1.5) {
        self.pollInterval = max(0.1, pollInterval)
    }

    deinit {
        let (task, continuations) = state.withLock { ($0.task, $0.continuations.values) }
        task?.cancel()
        for c in continuations { c.finish() }
    }

    /// A stream of debounced events. Polling starts with the first stream and runs until `stop()`.
    public func events() -> AsyncStream<MeetingDetectionEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: MeetingDetectionEvent.self, bufferingPolicy: .unbounded)
        let id = UUID()
        let (registered, shouldStart) = state.withLock { s -> (Bool, Bool) in
            guard !s.stopped else { return (false, false) }
            s.continuations[id] = continuation
            return (true, s.task == nil)
        }
        guard registered else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.continuations.removeValue(forKey: id) }
        }
        if shouldStart {
            let interval = pollInterval
            let task = Task.detached { [weak self] in
                while !Task.isCancelled {
                    self?.poll()
                    try? await Task.sleep(for: .seconds(interval))
                }
            }
            let stoppedMeanwhile = state.withLock { s -> Bool in
                if !s.stopped { s.task = task }
                return s.stopped
            }
            if stoppedMeanwhile { task.cancel() }
        }
        return stream
    }

    public func stop() {
        let (task, continuations) = state.withLock { s in
            s.stopped = true
            defer {
                s.task = nil
                s.continuations = [:]
            }
            return (s.task, Array(s.continuations.values))
        }
        task?.cancel()
        for c in continuations { c.finish() }
    }

    private func poll() {
        let observations = MeetingDetectionStateMachine.observations(from: Self.processesUsingMicrophone())
        let elapsed = ContinuousClock.now - origin
        let time = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let (events, continuations) = state.withLock { s in
            (s.machine.update(observations, at: time), Array(s.continuations.values))
        }
        for event in events {
            for c in continuations { c.yield(event) }
        }
    }

    /// Processes (other than this one) currently capturing audio input, with their bundle IDs.
    public static func processesUsingMicrophone() -> [(bundleID: String, pid: Int32)] {
        let objects = (try? CoreAudioProperty.array(
            AudioObjectID.self, object: AudioObjectID(kAudioObjectSystemObject),
            address: CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList),
            operation: "list audio processes")) ?? []
        let own = getpid()
        return objects.compactMap { object in
            guard
                let running = try? CoreAudioProperty.scalar(
                    UInt32.self, object: object,
                    address: CoreAudioProperty.address(kAudioProcessPropertyIsRunningInput),
                    operation: "read process input state"),
                running != 0,
                let pid = try? CoreAudioProperty.scalar(
                    pid_t.self, object: object, address: CoreAudioProperty.address(kAudioProcessPropertyPID),
                    operation: "read process pid"),
                pid != own,
                let bundleID = try? CoreAudioProperty.string(
                    object: object, address: CoreAudioProperty.address(kAudioProcessPropertyBundleID),
                    operation: "read process bundle ID"),
                !bundleID.isEmpty
            else { return nil }
            return (bundleID, pid)
        }
    }
}
