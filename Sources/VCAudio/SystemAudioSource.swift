import CoreAudio
import Foundation
import VCModels
import os

/// What the system-audio channel records.
public enum SystemAudioTarget: Sendable, Hashable, CustomStringConvertible {
    /// Everything the Mac plays except Voiccenger itself.
    case global
    /// Every process of a native meeting app: helpers and companion daemons included, not only the processes
    /// holding the microphone (`AudioProcesses.family`).
    case app(MeetingApp)

    /// The family tap for a native meeting app; the global tap for a browser (its meeting tab plays through
    /// processes shared with every other tab) or when no meeting app is known.
    public init(meetingApp: MeetingApp?) {
        if let meetingApp, meetingApp.kind == .native {
            self = .app(meetingApp)
        } else {
            self = .global
        }
    }

    public var description: String {
        switch self {
        case .global: "all computer audio"
        case .app(let app): "\(app.displayName)'s audio"
        }
    }
}

/// Something the system-audio source did on its own that the session may want to log or show.
public enum SystemAudioEvent: Sendable, Hashable {
    /// A tap is running for `target` covering these pids (empty for the global tap).
    case tapping(SystemAudioTarget, pids: [Int32])
    /// The app's family tap was replaced by the global tap; `reason` says why.
    case fellBackToGlobal(app: MeetingApp, reason: String)
    /// No tap could be (re)built; the channel records silence until the next rebuild succeeds.
    case failed(String)
}

let systemAudioLog = Logger(subsystem: "com.voiccenger.app", category: "system-audio")

/// Records what the Mac plays through Core Audio process taps (`ProcessTapBackend`), independent of the output
/// device, its volume and mute.
///
/// A meeting app's tap covers its whole process family and is rebuilt, without ending the stream, when a new
/// family process starts using audio (the process list and each process's IsRunningOutput are watched). The
/// timeline is continuous across rebuilds: the gap while the new tap starts is filled with silence, so the
/// recording stays aligned with the session clock. While a family tap runs, a global probe tap measures the rest
/// of the Mac's output: if the family stays silent while other audio carries speech for over 10 s (the meeting's
/// sound is coming from a process the catalog doesn't know), the source switches to the global tap and says why.
///
/// All tap work (creation, rebuilds, draining) is serialized on one dispatch queue; the realtime IO callbacks only
/// write to their tap's `TapSink`.
public final class SystemAudioSource: AudioSource {
    public let channel: AudioChannel = .system
    /// What this source does on its own (taps built, fallbacks, failures). Finishes when the source stops.
    public let events: AsyncStream<SystemAudioEvent>
    private let eventSink: AsyncStream<SystemAudioEvent>.Continuation
    private let clock: SessionClock
    private let chunkDuration: TimeInterval
    private let backend: any ProcessTapBackend
    private let queue = DispatchQueue(label: "VCAudio.SystemAudioSource", qos: .userInitiated)
    private let state: Mutex<State>

    /// Delay that coalesces bursts of process-list changes (an app launching several helpers) into one rebuild.
    static let rebuildDebounce: TimeInterval = 0.3

    private struct Tap {
        var tap: any ProcessTap
        var sink: TapSink
    }

    private struct State {
        var target: SystemAudioTarget
        var running = false
        var session: UInt64 = 0
        var tap: Tap?
        /// Process objects the current tap covers (empty for a global tap).
        var tapped: Set<AudioObjectID> = []
        var isGlobal = false
        /// Global tap measuring the rest of the Mac's output while a family tap runs.
        var probe: Tap?
        var probeVAD = VoiceActivityDetector()
        var fallback = SilentTapFallback()
        var assembler: ChunkAssembler?
        /// End of the last emitted chunk; the next tap continues the timeline from here.
        var timelineEnd: TimeInterval?
        var continuation: AsyncStream<AudioChunk>.Continuation?
        var timer: DispatchSourceTimer?
        var watch: (any ProcessWatch)?
        var refreshScheduled = false
    }

    public convenience init(target: SystemAudioTarget, clock: SessionClock, chunkDuration: TimeInterval = 0.1) {
        self.init(target: target, clock: clock, chunkDuration: chunkDuration, backend: CoreAudioTapBackend())
    }

    init(target: SystemAudioTarget, clock: SessionClock, chunkDuration: TimeInterval, backend: any ProcessTapBackend) {
        self.clock = clock
        self.chunkDuration = max(0.01, chunkDuration)
        self.backend = backend
        self.state = Mutex(State(target: target))
        (events, eventSink) = AsyncStream.makeStream(of: SystemAudioEvent.self, bufferingPolicy: .unbounded)
    }

    deinit {
        // Nothing else holds the source any more, so no queue hop is needed (and deinit may run on `queue`).
        shutDown(session: nil)?.finish()
        eventSink.finish()
    }

    /// The target currently recorded (it changes when the source falls back to the global tap).
    public var target: SystemAudioTarget { state.withLock { $0.target } }

    public func start() async throws -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: AudioChunk.self, bufferingPolicy: .bufferingNewest(MicrophoneSource.bufferCapacity(chunkDuration)))
        let session: UInt64 = try queue.sync {
            let session = try state.withLock { s -> UInt64 in
                guard !s.running else { throw AudioCaptureError.alreadyRunning }
                s.running = true
                s.session &+= 1
                s.continuation = continuation
                s.timelineEnd = nil
                return s.session
            }
            do {
                try build(state.withLock { $0.target })
            } catch {
                shutDown(session: session)?.finish()
                throw error
            }
            startTimer()
            let watch = backend.watchProcesses { [weak self] in self?.processesChanged() }
            state.withLock { $0.watch = watch }
            return session
        }
        continuation.onTermination = { [weak self] _ in
            // Never on `queue` synchronously: termination can be triggered from inside it.
            self?.queue.async { [weak self] in
                self?.shutDown(session: session)?.finish()
            }
        }
        return stream
    }

    public func stop() async {
        let continuation = queue.sync { shutDown(session: nil) }
        continuation?.finish()
        eventSink.finish()
    }

    /// Switches what is recorded without ending the stream (a meeting app was detected mid-recording).
    public func retarget(_ target: SystemAudioTarget) {
        queue.async { [weak self] in
            guard let self, state.withLock({ $0.running && $0.target != target }) else { return }
            state.withLock {
                $0.target = target
                $0.fallback = SilentTapFallback()
            }
            rebuild()
        }
    }

    // MARK: - Taps (on `queue`)

    /// Builds the tap for `target`. A family with no process using audio falls back to the global tap.
    private func build(_ target: SystemAudioTarget) throws {
        var objects: [AudioProcessInfo]?
        if case .app(let app) = target {
            let own = getpid()
            let family = AudioProcesses.family(of: app, in: backend.processes()).filter { $0.pid != own }
            if family.isEmpty {
                fallBack(from: app, reason: "no \(app.displayName) process is using audio")
                return try build(.global)
            }
            objects = family
        }
        let reserve = chunkDuration * 4
        let sink = TapSink()
        let tap = try backend.startTap(
            processObjects: objects?.map(\.objectID), clock: clock, sink: sink, reserve: reserve)
        var probe: Tap?
        if objects != nil {
            let probeSink = TapSink()
            if let probeTap = try? backend.startTap(processObjects: nil, clock: clock, sink: probeSink, reserve: reserve) {
                probe = Tap(tap: probeTap, sink: probeSink)
            }
        }
        state.withLock { s in
            s.tap = Tap(tap: tap, sink: sink)
            s.tapped = Set(objects?.map(\.objectID) ?? [])
            s.isGlobal = objects == nil
            s.probe = probe
            s.probeVAD = VoiceActivityDetector()
            s.assembler = ChunkAssembler(
                channel: .system, sampleRate: tap.sampleRate, chunkDuration: chunkDuration, channelCount: 1,
                keepChannels: false, continuing: s.timelineEnd)
        }
        let pids = objects?.map(\.pid) ?? []
        systemAudioLog.info("Tapping \(target.description, privacy: .public) (pids \(pids, privacy: .public))")
        eventSink.yield(.tapping(objects == nil ? .global : target, pids: pids))
    }

    /// Replaces the running tap with one for the current target; the timeline continues where it stopped.
    private func rebuild() {
        guard state.withLock({ $0.running }) else { return }
        tearDownTaps()
        do {
            try build(state.withLock { $0.target })
        } catch {
            systemAudioLog.error("System audio tap failed: \(error.localizedDescription, privacy: .public)")
            eventSink.yield(.failed(error.localizedDescription))
        }
    }

    /// Stops the taps, emitting what they captured, and remembers where the timeline ended.
    private func tearDownTaps() {
        let (tap, probe) = state.withLock { s -> (Tap?, Tap?) in
            defer {
                s.tap = nil
                s.probe = nil
            }
            return (s.tap, s.probe)
        }
        tap?.tap.stop()
        probe?.tap.stop()
        drain()
        let (tail, continuation) = state.withLock { s -> (AudioChunk?, AsyncStream<AudioChunk>.Continuation?) in
            let tail = s.assembler?.flush()
            if let end = s.assembler?.emittedEnd { s.timelineEnd = end }
            s.assembler = nil
            return (tail, s.continuation)
        }
        if let tail { continuation?.yield(tail) }
    }

    /// Stops everything for `session` (nil: any) and returns the stream to finish outside `queue`.
    @discardableResult
    private func shutDown(session: UInt64?) -> AsyncStream<AudioChunk>.Continuation? {
        let taken = state.withLock { s -> (DispatchSourceTimer?, (any ProcessWatch)?)? in
            guard s.running, session == nil || session == s.session else { return nil }
            s.running = false
            defer {
                s.timer = nil
                s.watch = nil
            }
            return (s.timer, s.watch)
        }
        guard let (timer, watch) = taken else { return nil }
        timer?.cancel()
        watch?.cancel()
        tearDownTaps()
        return state.withLock { s in
            defer { s.continuation = nil }
            return s.continuation
        }
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = chunkDuration / 2
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.tick() }
        state.withLock { $0.timer = timer }
        timer.resume()
    }

    private func tick() {
        guard let family = drain() else { return }
        checkFallback(familySamples: family)
    }

    /// Moves the tap's samples into chunks and delivers them. Returns the samples drained (nil when stopped).
    @discardableResult
    private func drain() -> [Float]? {
        guard let sink = state.withLock({ $0.tap?.sink }) else { return nil }
        let (samples, arrival) = sink.take()
        guard !samples.isEmpty else { return [] }
        let (chunks, continuation) = state.withLock { s -> ([AudioChunk], AsyncStream<AudioChunk>.Continuation?) in
            let out = samples.withUnsafeBufferPointer { buffer in
                s.assembler?.append(frames: buffer.count, arrivalTime: arrival) { _ in buffer } ?? []
            }
            if let end = s.assembler?.emittedEnd { s.timelineEnd = end }
            return (out, s.continuation)
        }
        for chunk in chunks { continuation?.yield(chunk) }
        return samples
    }

    // MARK: - Family changes and fallback (on `queue`)

    private func processesChanged() {
        queue.async { [weak self] in
            guard let self else { return }
            let schedule = state.withLock { s -> Bool in
                guard s.running, !s.refreshScheduled, case .app = s.target else { return false }
                s.refreshScheduled = true
                return true
            }
            guard schedule else { return }
            queue.asyncAfter(deadline: .now() + Self.rebuildDebounce) { [weak self] in
                self?.state.withLock { $0.refreshScheduled = false }
                self?.refreshFamily()
            }
        }
    }

    /// Rebuilds the family tap when a family process it doesn't cover has appeared.
    private func refreshFamily() {
        let (target, tapped, isGlobal) = state.withLock { ($0.target, $0.tapped, $0.isGlobal) }
        guard case .app(let app) = target else { return }
        let own = getpid()
        let family = Set(
            AudioProcesses.family(of: app, in: backend.processes()).filter { $0.pid != own }.map(\.objectID))
        guard !family.isEmpty, isGlobal || !family.isSubset(of: tapped) else { return }
        systemAudioLog.info("\(app.displayName, privacy: .public) has new audio processes; rebuilding its tap")
        rebuild()
    }

    private func checkFallback(familySamples: [Float]) {
        let probe = state.withLock { s -> (TapSink, Double)? in
            guard let probe = s.probe else { return nil }
            return (probe.sink, probe.tap.sampleRate)
        }
        guard let (probeSink, probeRate) = probe else { return }
        let (global, arrival) = probeSink.take()
        let audible = SilentTapFallback.isAudible(familySamples)
        let switchNow = state.withLock { s -> Bool in
            let speech = s.probeVAD.process(global, sampleRate: probeRate).filter { $0 }.count
            let seconds = Double(speech) * s.probeVAD.frameDuration
            return s.fallback.update(familyAudible: audible, globalSpeechSeconds: seconds, at: arrival)
        }
        guard switchNow, case .app(let app) = state.withLock({ $0.target }) else { return }
        let reason = String(
            format: "%@ stayed silent while other audio on this Mac carried speech for over %.0f s",
            app.displayName, SilentTapFallback.requiredSpeechSeconds)
        fallBack(from: app, reason: reason)
        rebuild()
    }

    private func fallBack(from app: MeetingApp, reason: String) {
        systemAudioLog.notice(
            "Recording all computer audio instead of \(app.displayName, privacy: .public): \(reason, privacy: .public)")
        state.withLock { $0.target = .global }
        eventSink.yield(.fellBackToGlobal(app: app, reason: reason))
    }
}

/// Decides when a silent family tap should give way to the global tap: the family has been inaudible while the
/// rest of the Mac's output carried more than `requiredSpeechSeconds` of speech, with no pause in that speech
/// longer than `maximumPause`. Any audible family audio starts the count afresh. Pure; time is session seconds.
struct SilentTapFallback: Sendable {
    static let requiredSpeechSeconds: TimeInterval = 10
    static let maximumPause: TimeInterval = 5
    /// Below this the family tap counts as silent (−41 dBFS speech from a quiet output is far above it).
    static let audibleDB: Float = -70

    private var speechSeconds: TimeInterval = 0
    private var lastSpeech: TimeInterval?

    static func isAudible(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return 10 * log10(max(sum / Float(samples.count), 1e-12)) > audibleDB
    }

    /// Feeds one interval ending at `time`; returns true once the family should be abandoned.
    mutating func update(familyAudible: Bool, globalSpeechSeconds: TimeInterval, at time: TimeInterval) -> Bool {
        if familyAudible {
            speechSeconds = 0
            lastSpeech = nil
            return false
        }
        if let last = lastSpeech, time - last > Self.maximumPause {
            speechSeconds = 0
            lastSpeech = nil
        }
        if globalSpeechSeconds > 0 {
            speechSeconds += globalSpeechSeconds
            lastSpeech = time
        }
        return speechSeconds > Self.requiredSpeechSeconds
    }
}
