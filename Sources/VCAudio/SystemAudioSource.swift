import AudioToolbox
import CoreAudio
import Foundation
import Synchronization
import VCModels

/// Core Audio process tap (AudioHardwareCreateProcessTap + private aggregate device). processIDs nil/empty = all system output except this process.
///
/// The tap is a stereo mixdown of the selected processes' output; chunks carry its mono mixdown. The HAL
/// IO block only copies samples into a lock-protected accumulator; a separate task re-blocks them into
/// chunks, so no allocation-heavy work or stream delivery happens on the realtime IO thread.
public final class SystemAudioSource: AudioSource {
    public let channel: AudioChannel = .system
    public let processIDs: [Int32]?
    private let clock: SessionClock
    private let chunkDuration: TimeInterval
    private let state = Mutex(State())
    private let accumulator = SampleAccumulator()

    /// UID prefix of the private aggregate devices this type creates (hidden from `AudioDevices`).
    static let aggregateUIDPrefix = "com.voiccenger.systemtap."

    private struct State {
        var running = false
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        var ioProcID: AudioDeviceIOProcID?
        var continuation: AsyncStream<AudioChunk>.Continuation?
        var assembler: ChunkAssembler?
        var pump: Task<Void, Never>?
        var session: UInt64 = 0
    }

    /// Samples copied out of the IO block, waiting to be chunked.
    private struct Accumulator {
        var samples: [Float] = []
        /// Session time at which the newest sample was captured.
        var lastArrival: TimeInterval = 0
        /// Upper bound so a stalled pump can't grow memory without limit (oldest samples are dropped).
        var capacity = 0
    }

    /// Reference wrapper so the HAL IO block can capture the (noncopyable) lock.
    private final class SampleAccumulator: Sendable {
        private let lock = Mutex(Accumulator())

        func withLock<R>(_ body: (inout Accumulator) -> R) -> R {
            lock.withLock { body(&$0) }
        }
    }

    public init(processIDs: [Int32]?, clock: SessionClock, chunkDuration: TimeInterval = 0.1) {
        self.processIDs = processIDs
        self.clock = clock
        self.chunkDuration = max(0.01, chunkDuration)
    }

    deinit {
        let s = state.withLock { s -> State in
            let copy = s
            s = State()
            return copy
        }
        s.pump?.cancel()
        Self.teardown(tapID: s.tapID, aggregateID: s.aggregateID, ioProcID: s.ioProcID)
        s.continuation?.finish()
    }

    public func start() async throws -> AsyncStream<AudioChunk> {
        let session: UInt64 = try state.withLock { s in
            guard !s.running else { throw AudioCaptureError.alreadyRunning }
            s.running = true
            s.session &+= 1
            return s.session
        }
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        var ioProcID: AudioDeviceIOProcID?
        do {
            let description = try makeTapDescription()
            var status = AudioHardwareCreateProcessTap(description, &tapID)
            guard status == noErr else { throw Self.tapError(status) }

            let format = try CoreAudioProperty.scalar(
                AudioStreamBasicDescription.self, object: tapID,
                address: CoreAudioProperty.address(kAudioTapPropertyFormat), operation: "read the tap format")
            guard format.mFormatID == kAudioFormatLinearPCM,
                format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32,
                format.mChannelsPerFrame > 0, format.mSampleRate > 0
            else { throw AudioCaptureError.unsupportedFormat("process tap delivers \(Self.describe(format))") }

            aggregateID = try Self.createAggregateDevice(tapUID: description.uuid.uuidString)

            let channels = Int(format.mChannelsPerFrame)
            let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            let sampleRate = format.mSampleRate
            state.withLock {
                $0.assembler = ChunkAssembler(
                    channel: .system, sampleRate: sampleRate, chunkDuration: chunkDuration, channelCount: 1,
                    keepChannels: false)
            }
            accumulator.withLock {
                $0 = Accumulator()
                $0.capacity = Int(sampleRate * 30)
                $0.samples.reserveCapacity(Int(sampleRate * chunkDuration * 4))
            }

            let block = Self.makeIOBlock(
                accumulator: accumulator, clock: clock, channels: channels, interleaved: interleaved)
            status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil, block)
            guard status == noErr, let ioProcID else {
                throw AudioCaptureError.coreAudio(operation: "create the system audio IO callback", status: status)
            }
            status = AudioDeviceStart(aggregateID, ioProcID)
            guard status == noErr else { throw Self.tapError(status) }
        } catch {
            Self.teardown(tapID: tapID, aggregateID: aggregateID, ioProcID: ioProcID)
            state.withLock { $0 = State(session: $0.session) }
            throw error
        }

        let (stream, continuation) = AsyncStream.makeStream(
            of: AudioChunk.self,
            bufferingPolicy: .bufferingNewest(MicrophoneSource.bufferCapacity(chunkDuration)))
        let pumpInterval = chunkDuration / 2
        let pump = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(pumpInterval))
                self?.drain()
            }
        }
        state.withLock {
            $0.tapID = tapID
            $0.aggregateID = aggregateID
            $0.ioProcID = ioProcID
            $0.continuation = continuation
            $0.pump = pump
        }
        continuation.onTermination = { [weak self] _ in
            self?.stop(session: session)
        }
        return stream
    }

    public func stop() async {
        stop(session: nil)
    }

    private func stop(session: UInt64?) {
        let taken = state.withLock { s -> State? in
            guard s.running, session == nil || session == s.session else { return nil }
            let copy = s
            s.running = false
            s.tapID = AudioObjectID(kAudioObjectUnknown)
            s.aggregateID = AudioObjectID(kAudioObjectUnknown)
            s.ioProcID = nil
            s.pump = nil
            return copy
        }
        guard let taken else { return }
        taken.pump?.cancel()
        Self.teardown(tapID: taken.tapID, aggregateID: taken.aggregateID, ioProcID: taken.ioProcID)
        drain()
        let (tail, continuation) = state.withLock { s -> (AudioChunk?, AsyncStream<AudioChunk>.Continuation?) in
            defer {
                s.assembler = nil
                s.continuation = nil
            }
            return (s.assembler?.flush(), s.continuation)
        }
        if let tail { continuation?.yield(tail) }
        continuation?.finish()
    }

    /// Moves accumulated samples into fixed-size chunks and delivers them (runs off the IO thread).
    private func drain() {
        let (samples, arrival) = accumulator.withLock { a -> ([Float], TimeInterval) in
            guard !a.samples.isEmpty else { return ([], a.lastArrival) }
            let taken = a.samples
            a.samples.removeAll(keepingCapacity: true)
            return (taken, a.lastArrival)
        }
        guard !samples.isEmpty else { return }
        let (chunks, continuation) = state.withLock { s -> ([AudioChunk], AsyncStream<AudioChunk>.Continuation?) in
            let out = samples.withUnsafeBufferPointer { buffer in
                s.assembler?.append(frames: buffer.count, arrivalTime: arrival) { _ in buffer } ?? []
            }
            return (out, s.continuation)
        }
        for chunk in chunks { continuation?.yield(chunk) }
    }

    // MARK: - Core Audio objects

    private func makeTapDescription() throws -> CATapDescription {
        let description: CATapDescription
        if let pids = processIDs, !pids.isEmpty {
            let objects = pids.compactMap(Self.processObject(pid:))
            guard !objects.isEmpty else { throw AudioCaptureError.processesNotFound(pids: pids) }
            description = CATapDescription(stereoMixdownOfProcesses: objects)
        } else {
            let own = Self.processObject(pid: getpid()).map { [$0] } ?? []
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: own)
        }
        description.uuid = UUID()
        description.name = "Voiccenger system audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        return description
    }

    /// Core Audio process object for a pid (nil when the process has never touched audio).
    static func processObject(pid: Int32) -> AudioObjectID? {
        var qualifierPID = pid
        let object = withUnsafeBytes(of: &qualifierPID) { qualifier in
            try? CoreAudioProperty.scalar(
                AudioObjectID.self, object: AudioObjectID(kAudioObjectSystemObject),
                address: CoreAudioProperty.address(kAudioHardwarePropertyTranslatePIDToProcessObject),
                qualifier: qualifier, operation: "translate pid \(pid)")
        }
        guard let object, object != kAudioObjectUnknown else { return nil }
        return object
    }

    /// Private aggregate device whose only input is the tap. The default output device is its clock source.
    private static func createAggregateDevice(tapUID: String) throws -> AudioObjectID {
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Voiccenger System Audio",
            kAudioAggregateDeviceUIDKey: aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]
            ],
        ]
        if let outputUID = defaultOutputDeviceUID() {
            description[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            description[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard status == noErr else {
            throw AudioCaptureError.coreAudio(operation: "create the system audio capture device", status: status)
        }
        return aggregateID
    }

    private static func defaultOutputDeviceUID() -> String? {
        guard let device = try? CoreAudioProperty.scalar(
            AudioObjectID.self, object: AudioObjectID(kAudioObjectSystemObject),
            address: CoreAudioProperty.address(kAudioHardwarePropertyDefaultSystemOutputDevice),
            operation: "read the default output device"),
            device != kAudioObjectUnknown
        else { return nil }
        return try? CoreAudioProperty.string(
            object: device, address: CoreAudioProperty.address(kAudioDevicePropertyDeviceUID),
            operation: "read the output device UID")
    }

    private static func teardown(tapID: AudioObjectID, aggregateID: AudioObjectID, ioProcID: AudioDeviceIOProcID?) {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
    }

    /// Built outside any isolation domain: the HAL calls it on its realtime IO thread. It only averages the
    /// channels into the (pre-reserved) accumulator under a short lock.
    private static func makeIOBlock(
        accumulator: SampleAccumulator, clock: SessionClock, channels: Int, interleaved: Bool
    ) -> AudioDeviceIOBlock {
        { _, inputData, _, _, _ in
            let arrival = clock.now()
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            accumulator.withLock { a in
                if interleaved {
                    guard let buffer = buffers.first, let data = buffer.mData else { return }
                    let perFrame = max(1, Int(buffer.mNumberChannels))
                    let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * perFrame)
                    let samples = data.assumingMemoryBound(to: Float.self)
                    let scale = 1 / Float(perFrame)
                    for f in 0..<frames {
                        var sum: Float = 0
                        for c in 0..<perFrame { sum += samples[f * perFrame + c] }
                        a.samples.append(sum * scale)
                    }
                } else {
                    let planes = buffers.prefix(channels).compactMap { b -> UnsafeBufferPointer<Float>? in
                        guard let data = b.mData else { return nil }
                        return UnsafeBufferPointer(
                            start: data.assumingMemoryBound(to: Float.self),
                            count: Int(b.mDataByteSize) / MemoryLayout<Float>.size)
                    }
                    guard let frames = planes.map(\.count).min(), frames > 0 else { return }
                    let scale = 1 / Float(planes.count)
                    for f in 0..<frames {
                        var sum: Float = 0
                        for p in planes { sum += p[f] }
                        a.samples.append(sum * scale)
                    }
                }
                a.lastArrival = arrival
                if a.capacity > 0, a.samples.count > a.capacity {
                    a.samples.removeFirst(a.samples.count - a.capacity)
                }
            }
        }
    }

    private static func tapError(_ status: OSStatus) -> AudioCaptureError {
        .coreAudio(operation: "start capturing system audio", status: status)
    }

    private static func describe(_ f: AudioStreamBasicDescription) -> String {
        "\(f.mChannelsPerFrame) ch, \(f.mBitsPerChannel)-bit, \(f.mSampleRate) Hz, flags \(f.mFormatFlags)"
    }
}
