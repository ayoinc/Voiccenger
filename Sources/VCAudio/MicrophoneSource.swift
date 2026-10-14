import AVFAudio
import AudioToolbox
import CoreAudio
import Foundation
import VCModels

/// AVAudioEngine input. When `arrayGeometry` is set, chunks carry `channelSamples` (raw de-interleaved, device channel order) for DOA.
///
/// Audio is tapped in the device's native format. `samples` is the mean of all device channels, or of the
/// geometry's mapped microphones when an array is configured (arrays often expose extra processed channels).
/// When the hardware configuration changes (device unplugged, default device switched, sample rate changed)
/// the engine is rebuilt on the new format and the timeline continues; if the selected device is gone the
/// stream finishes.
public final class MicrophoneSource: AudioSource {
    public let channel: AudioChannel = .microphone
    public let deviceUID: String?
    public let arrayGeometry: MicArrayGeometry?
    private let clock: SessionClock
    private let chunkDuration: TimeInterval
    private let state = Mutex(State())

    /// `AVAudioEngine` isn't `Sendable`, but this source already hands one engine between the caller,
    /// the configuration-change task and the tap. Every start/stop/restart is serialized through the
    /// mutex-guarded `generation`/`session` counters, which is what makes sharing it sound.
    private struct EngineHandle: @unchecked Sendable {
        let engine: AVAudioEngine
    }

    private struct State {
        var engine: EngineHandle?
        var continuation: AsyncStream<AudioChunk>.Continuation?
        var assembler: ChunkAssembler?
        var configurationTask: Task<Void, Never>?
        /// Bumped on every start/restart/stop so late tap callbacks from a previous configuration are ignored.
        var generation: UInt64 = 0
        /// Identifies one start…stop cycle so a stale stream termination cannot stop a newer session.
        var session: UInt64 = 0
        /// End of the last emitted chunk; a restarted engine never rewinds before it.
        var timelineEnd: TimeInterval = -.infinity
    }

    public init(
        deviceUID: String? = nil, arrayGeometry: MicArrayGeometry? = nil, clock: SessionClock,
        chunkDuration: TimeInterval = 0.1
    ) {
        self.deviceUID = deviceUID
        self.arrayGeometry = arrayGeometry
        self.clock = clock
        self.chunkDuration = max(0.01, chunkDuration)
    }

    deinit {
        let engine = state.withLock { $0.engine?.engine }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
    }

    public func start() async throws -> AsyncStream<AudioChunk> {
        try await Self.ensureMicrophonePermission()
        let engine = AVAudioEngine()
        let (stream, continuation) = AsyncStream.makeStream(
            of: AudioChunk.self, bufferingPolicy: .bufferingNewest(Self.bufferCapacity(chunkDuration)))
        let handle = EngineHandle(engine: engine)
        let session: UInt64 = try state.withLock { s in
            guard s.engine == nil else { throw AudioCaptureError.alreadyRunning }
            s.engine = handle
            s.continuation = continuation
            s.session &+= 1
            s.timelineEnd = -.infinity
            return s.session
        }
        do {
            try startEngine(engine)
        } catch {
            state.withLock { s in
                s.engine = nil
                s.continuation = nil
                s.assembler = nil
                s.generation &+= 1
            }
            continuation.finish()
            throw error
        }
        continuation.onTermination = { [weak self] _ in
            self?.stop(session: session)
        }
        let observer = Task.detached { [weak self] in
            // Filter by identity: the 26.x SDK only accepts a `Sendable` `object:` here.
            for await note in NotificationCenter.default.notifications(named: .AVAudioEngineConfigurationChange) {
                guard (note.object as AnyObject?) === handle.engine else { continue }
                guard let self else { return }
                self.restartAfterConfigurationChange(engine: handle.engine)
            }
        }
        state.withLock { $0.configurationTask = observer }
        return stream
    }

    public func stop() async {
        stop(session: nil)
    }

    private func stop(session: UInt64?) {
        let taken = state.withLock { s -> (EngineHandle, AsyncStream<AudioChunk>.Continuation?, Task<Void, Never>?)? in
            guard let handle = s.engine, session == nil || session == s.session else { return nil }
            s.engine = nil
            let observer = s.configurationTask
            s.configurationTask = nil
            return (handle, s.continuation, observer)
        }
        guard let (handle, continuation, observer) = taken else { return }
        let engine = handle.engine
        observer?.cancel()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let tail = state.withLock { s -> AudioChunk? in
            s.generation &+= 1
            s.continuation = nil
            defer { s.assembler = nil }
            return s.assembler?.flush()
        }
        if let tail { continuation?.yield(tail) }
        continuation?.finish()
    }

    // MARK: - Engine

    /// Selects the device, validates the format, installs the tap and starts the engine.
    private func startEngine(_ engine: AVAudioEngine) throws {
        let input = engine.inputNode
        if let deviceUID {
            guard let deviceID = AudioDevices.deviceID(forUID: deviceUID) else {
                throw AudioCaptureError.deviceNotFound(uid: deviceUID)
            }
            guard let unit = input.audioUnit else {
                throw AudioCaptureError.engineFailure("the input node has no audio unit")
            }
            var device = deviceID
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device,
                UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else {
                throw AudioCaptureError.coreAudio(operation: "select input device \(deviceUID)", status: status)
            }
        }
        let format = input.outputFormat(forBus: 0)
        let channels = Int(format.channelCount)
        guard channels > 0, format.sampleRate > 0 else { throw AudioCaptureError.noInputDevice }
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            throw AudioCaptureError.unsupportedFormat("input node delivers \(format)")
        }
        var mix: [Int]?
        if let geometry = arrayGeometry {
            let map = geometry.channelMap
            guard !map.isEmpty, map.allSatisfy({ (0..<channels).contains($0) }) else {
                throw AudioCaptureError.invalidChannelMap(channelMap: map, deviceChannelCount: channels)
            }
            mix = map
        }
        let generation = state.withLock { s -> UInt64 in
            s.generation &+= 1
            s.assembler = ChunkAssembler(
                channel: .microphone, sampleRate: format.sampleRate, chunkDuration: chunkDuration,
                channelCount: channels, mixIndices: mix, keepChannels: arrayGeometry != nil,
                minimumOrigin: s.timelineEnd)
            return s.generation
        }
        let bufferSize = AVAudioFrameCount(max(256, (format.sampleRate * chunkDuration).rounded()))
        input.installTap(
            onBus: 0, bufferSize: bufferSize, format: format,
            block: Self.makeTapBlock(source: self, generation: generation))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioCaptureError.engineFailure(error.localizedDescription)
        }
    }

    /// Built outside any isolation domain: AVAudioEngine calls the tap on its own thread.
    private static func makeTapBlock(source: MicrophoneSource, generation: UInt64) -> AVAudioNodeTapBlock {
        { [weak source] buffer, _ in source?.ingest(buffer, generation: generation) }
    }

    private func ingest(_ buffer: AVAudioPCMBuffer, generation: UInt64) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData else { return }
        let available = Int(buffer.format.channelCount)
        let arrival = clock.now()
        let (chunks, continuation) = state.withLock { s -> ([AudioChunk], AsyncStream<AudioChunk>.Continuation?) in
            guard s.generation == generation, let channels = s.assembler?.channelCount, channels <= available
            else { return ([], nil) }
            let out = s.assembler?.append(frames: frames, arrivalTime: arrival) { c in
                UnsafeBufferPointer(start: data[c], count: frames)
            } ?? []
            if let end = s.assembler?.emittedEnd { s.timelineEnd = end }
            return (out, s.continuation)
        }
        for chunk in chunks { continuation?.yield(chunk) }
    }

    /// The engine stops itself on a configuration change; rebuild it on the new hardware format.
    private func restartAfterConfigurationChange(engine: AVAudioEngine) {
        let engineID = ObjectIdentifier(engine)
        let (isCurrent, tail, continuation) = state.withLock {
            s -> (Bool, AudioChunk?, AsyncStream<AudioChunk>.Continuation?) in
            guard let current = s.engine, ObjectIdentifier(current.engine) == engineID else { return (false, nil, nil) }
            s.generation &+= 1
            let tail = s.assembler?.flush()
            if let end = s.assembler?.emittedEnd { s.timelineEnd = end }
            s.assembler = nil
            return (true, tail, s.continuation)
        }
        guard isCurrent else { return }
        if let tail { continuation?.yield(tail) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try startEngine(engine)
        } catch {
            let session = state.withLock { $0.session }
            stop(session: session)
        }
    }

    private static func ensureMicrophonePermission() async throws {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return
        case .denied:
            throw AudioCaptureError.microphonePermissionDenied
        default:
            guard await AVAudioApplication.requestRecordPermission() else {
                throw AudioCaptureError.microphonePermissionDenied
            }
        }
    }

    /// ~10 s of chunks: enough to ride out a stalled consumer without unbounded growth.
    static func bufferCapacity(_ chunkDuration: TimeInterval) -> Int {
        max(8, Int((10 / chunkDuration).rounded(.up)))
    }
}
