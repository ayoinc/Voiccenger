import AudioToolbox
import CoreAudio
import Foundation
import VCModels

/// Mono samples copied out of a tap's realtime IO callback, waiting to be chunked. One per tap, so a torn-down
/// tap's late callbacks can never mix into its successor's audio.
final class TapSink: Sendable {
    struct Buffer {
        var samples: [Float] = []
        /// Session time at which the newest sample was captured.
        var lastArrival: TimeInterval = 0
        /// Upper bound so a stalled pump can't grow memory without limit (oldest samples are dropped).
        var capacity = 0
    }

    private let lock = Mutex(Buffer())

    func withLock<R>(_ body: (inout Buffer) -> R) -> R {
        lock.withLock { body(&$0) }
    }

    /// Prepares for a tap delivering `sampleRate`: keeps at most 30 s, pre-reserves a few pump intervals.
    func reset(sampleRate: Double, reserve: Int) {
        withLock {
            $0 = Buffer()
            $0.capacity = Int(sampleRate * 30)
            $0.samples.reserveCapacity(reserve)
        }
    }

    /// Appends mono samples captured at session time `arrival` (the time of the last one).
    func append(_ samples: UnsafeBufferPointer<Float>, arrival: TimeInterval) {
        withLock { b in
            b.samples.append(contentsOf: samples)
            b.lastArrival = arrival
            b.trim()
        }
    }

    /// Takes everything buffered: the samples and the session time of the last one.
    func take() -> (samples: [Float], arrival: TimeInterval) {
        withLock { b in
            guard !b.samples.isEmpty else { return ([], b.lastArrival) }
            let taken = b.samples
            b.samples.removeAll(keepingCapacity: true)
            return (taken, b.lastArrival)
        }
    }
}

extension TapSink.Buffer {
    mutating func trim() {
        if capacity > 0, samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }
}

/// A running process tap. `stop()` is synchronous: once it returns, the tap no longer writes to its sink.
protocol ProcessTap: Sendable {
    var sampleRate: Double { get }
    func stop()
}

/// Creates process taps and reports process-list changes. The Core Audio implementation is the real one;
/// tests substitute a fake to drive rebuilds deterministically.
protocol ProcessTapBackend: Sendable {
    /// Processes Core Audio currently knows about.
    func processes() -> [AudioProcessInfo]
    /// Starts a tap on `processObjects` (nil: every process except this one) writing mono samples into `sink`.
    func startTap(processObjects: [AudioObjectID]?, clock: SessionClock, sink: TapSink, reserve: TimeInterval) throws
        -> any ProcessTap
    /// Calls `onChange` whenever a process starts/stops using audio or starts/stops playing. Returns a token
    /// whose `cancel()` stops the notifications.
    func watchProcesses(_ onChange: @escaping @Sendable () -> Void) -> any ProcessWatch
}

protocol ProcessWatch: Sendable {
    func cancel()
}

extension AudioProcessWatcher: ProcessWatch {}

/// Core Audio process taps (AudioHardwareCreateProcessTap + a private aggregate device per tap).
struct CoreAudioTapBackend: ProcessTapBackend {
    func processes() -> [AudioProcessInfo] { AudioProcesses.current() }

    func watchProcesses(_ onChange: @escaping @Sendable () -> Void) -> any ProcessWatch {
        AudioProcessWatcher(onChange: onChange)
    }

    func startTap(processObjects: [AudioObjectID]?, clock: SessionClock, sink: TapSink, reserve: TimeInterval) throws
        -> any ProcessTap
    {
        try CoreAudioProcessTap(processObjects: processObjects, clock: clock, sink: sink, reserve: reserve)
    }
}

/// One tap plus the private aggregate device that reads it. The HAL IO block only averages the channels into
/// the sink under a short lock; chunking happens on the source's pump.
final class CoreAudioProcessTap: ProcessTap {
    let sampleRate: Double
    private let tapID: AudioObjectID
    private let aggregateID: AudioObjectID
    private let ioProcID: AudioDeviceIOProcID
    private let stopped = Mutex(false)

    /// UID prefix of the private aggregate devices taps use (hidden from `AudioDevices`).
    static let aggregateUIDPrefix = "com.voiccenger.systemtap."

    init(processObjects: [AudioObjectID]?, clock: SessionClock, sink: TapSink, reserve: TimeInterval) throws {
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        var ioProcID: AudioDeviceIOProcID?
        do {
            let description = Self.tapDescription(processObjects: processObjects)
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
            sink.reset(sampleRate: format.mSampleRate, reserve: Int(format.mSampleRate * reserve))

            let block = Self.makeIOBlock(
                sink: sink, clock: clock, channels: Int(format.mChannelsPerFrame),
                interleaved: format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0)
            status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil, block)
            guard status == noErr, let ioProcID else {
                throw AudioCaptureError.coreAudio(operation: "create the system audio IO callback", status: status)
            }
            status = AudioDeviceStart(aggregateID, ioProcID)
            guard status == noErr else { throw Self.tapError(status) }
            self.sampleRate = format.mSampleRate
            self.tapID = tapID
            self.aggregateID = aggregateID
            self.ioProcID = ioProcID
        } catch {
            Self.teardown(tapID: tapID, aggregateID: aggregateID, ioProcID: ioProcID)
            throw error
        }
    }

    deinit {
        stop()
    }

    func stop() {
        let first = stopped.withLock { s -> Bool in
            defer { s = true }
            return !s
        }
        guard first else { return }
        Self.teardown(tapID: tapID, aggregateID: aggregateID, ioProcID: ioProcID)
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

    private static func tapDescription(processObjects: [AudioObjectID]?) -> CATapDescription {
        let description: CATapDescription
        if let processObjects {
            description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        } else {
            let own = processObject(pid: getpid()).map { [$0] } ?? []
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: own)
        }
        description.uuid = UUID()
        description.name = "Voiccenger system audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        return description
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
    /// channels into the (pre-reserved) sink under a short lock.
    private static func makeIOBlock(
        sink: TapSink, clock: SessionClock, channels: Int, interleaved: Bool
    ) -> AudioDeviceIOBlock {
        { _, inputData, _, _, _ in
            let arrival = clock.now()
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            sink.withLock { a in
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
                a.trim()
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
