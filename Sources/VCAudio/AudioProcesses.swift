import CoreAudio
import Foundation
import VCModels

/// A process Core Audio knows about (one that has used audio since it launched).
public struct AudioProcessInfo: Sendable, Hashable {
    /// Core Audio process object, the unit a process tap is built from.
    public let objectID: AudioObjectID
    public let pid: Int32
    /// Empty for processes without a bundle.
    public let bundleID: String
    public let isRunningInput: Bool
    public let isRunningOutput: Bool

    public init(objectID: AudioObjectID, pid: Int32, bundleID: String, isRunningInput: Bool, isRunningOutput: Bool) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
    }
}

/// Core Audio's process list (kAudioHardwarePropertyProcessObjectList) and the meeting-app families in it.
public enum AudioProcesses {
    /// Every process object with its pid, bundle ID and whether it is capturing or playing audio right now.
    public static func current() -> [AudioProcessInfo] {
        let objects = (try? CoreAudioProperty.array(
            AudioObjectID.self, object: AudioObjectID(kAudioObjectSystemObject),
            address: CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList),
            operation: "list audio processes")) ?? []
        return objects.compactMap { object in
            guard let pid = try? CoreAudioProperty.scalar(
                pid_t.self, object: object, address: CoreAudioProperty.address(kAudioProcessPropertyPID),
                operation: "read process pid")
            else { return nil }
            let bundleID = (try? CoreAudioProperty.string(
                object: object, address: CoreAudioProperty.address(kAudioProcessPropertyBundleID),
                operation: "read process bundle ID")) ?? ""
            return AudioProcessInfo(
                objectID: object, pid: pid, bundleID: bundleID,
                isRunningInput: flag(kAudioProcessPropertyIsRunningInput, of: object),
                isRunningOutput: flag(kAudioProcessPropertyIsRunningOutput, of: object))
        }
    }

    /// The app's whole process family: every process whose bundle ID the catalog maps to the same app (by
    /// display name, so Teams' two bundle IDs, FaceTime + avconferenced and every helper process count),
    /// whether or not it is using the microphone. Sorted by pid.
    public static func family(of app: MeetingApp, in processes: [AudioProcessInfo]) -> [AudioProcessInfo] {
        processes.filter { process in
            !process.bundleID.isEmpty
                && MeetingAppCatalog.app(forBundleID: process.bundleID)?.displayName == app.displayName
        }
        .sorted { $0.pid < $1.pid }
    }

    private static func flag(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> Bool {
        ((try? CoreAudioProperty.scalar(
            UInt32.self, object: object, address: CoreAudioProperty.address(selector),
            operation: "read process state")) ?? 0) != 0
    }
}

/// Calls `onChange` (on a private queue) whenever a process starts or stops using audio
/// (kAudioHardwarePropertyProcessObjectList) or starts or stops playing (kAudioProcessPropertyIsRunningOutput
/// on every process object). Listening stops on `cancel()` or deinit.
final class AudioProcessWatcher: Sendable {
    private let queue = DispatchQueue(label: "VCAudio.AudioProcessWatcher")
    private let state = Mutex(State())
    private let onChange: @Sendable () -> Void

    private struct State {
        var listener: AudioObjectPropertyListenerBlock?
        /// Process objects with an IsRunningOutput listener.
        var watched: Set<AudioObjectID> = []
        var cancelled = false
    }

    private static let listAddress = CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList)
    private static let outputAddress = CoreAudioProperty.address(kAudioProcessPropertyIsRunningOutput)

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, addresses in
            guard let self else { return }
            let first = addresses.pointee
            if first.mSelector == kAudioHardwarePropertyProcessObjectList { self.watchProcesses() }
            self.onChange()
        }
        state.withLock { $0.listener = listener }
        var address = Self.listAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        watchProcesses()
    }

    deinit {
        cancel()
    }

    func cancel() {
        let taken = state.withLock { s -> (AudioObjectPropertyListenerBlock, Set<AudioObjectID>)? in
            guard !s.cancelled, let listener = s.listener else { return nil }
            s.cancelled = true
            defer {
                s.listener = nil
                s.watched = []
            }
            return (listener, s.watched)
        }
        guard let (listener, watched) = taken else { return }
        var list = Self.listAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &list, queue, listener)
        for object in watched {
            var output = Self.outputAddress
            AudioObjectRemovePropertyListenerBlock(object, &output, queue, listener)
        }
    }

    /// Adds output-state listeners for process objects that appeared since the last call.
    private func watchProcesses() {
        let objects = Set((try? CoreAudioProperty.array(
            AudioObjectID.self, object: AudioObjectID(kAudioObjectSystemObject), address: Self.listAddress,
            operation: "list audio processes")) ?? [])
        let (listener, added) = state.withLock { s -> (AudioObjectPropertyListenerBlock?, Set<AudioObjectID>) in
            guard !s.cancelled else { return (nil, []) }
            let added = objects.subtracting(s.watched)
            // Objects of exited processes are gone; their listeners went with them.
            s.watched = s.watched.intersection(objects).union(added)
            return (s.listener, added)
        }
        guard let listener else { return }
        for object in added {
            var output = Self.outputAddress
            AudioObjectAddPropertyListenerBlock(object, &output, queue, listener)
        }
    }
}
