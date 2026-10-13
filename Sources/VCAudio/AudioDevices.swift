import CoreAudio
import Foundation

public struct AudioInputDevice: Sendable, Hashable, Identifiable {
    /// Core Audio device UID (stable across reboots and reconnects).
    public let id: String
    public let name: String
    /// Number of input channels the device exposes (e.g. 6 for a ReSpeaker array).
    public let channelCount: Int

    public init(id: String, name: String, channelCount: Int) {
        self.id = id
        self.name = name
        self.channelCount = channelCount
    }
}

/// Enumerates Core Audio input devices.
public enum AudioDevices {
    /// Every device with at least one input channel, in Core Audio order.
    public static func inputDevices() -> [AudioInputDevice] {
        let ids = (try? CoreAudioProperty.array(
            AudioObjectID.self,
            object: AudioObjectID(kAudioObjectSystemObject),
            address: CoreAudioProperty.address(kAudioHardwarePropertyDevices),
            operation: "list audio devices")) ?? []
        return ids.compactMap(inputDevice(id:))
    }

    /// The system default input device, if one exists and has input channels.
    public static func defaultInputDevice() -> AudioInputDevice? {
        guard let id = try? CoreAudioProperty.scalar(
            AudioObjectID.self,
            object: AudioObjectID(kAudioObjectSystemObject),
            address: CoreAudioProperty.address(kAudioHardwarePropertyDefaultInputDevice),
            operation: "read the default input device"),
            id != kAudioObjectUnknown
        else { return nil }
        return inputDevice(id: id)
    }

    /// Core Audio object for an input device UID (nil when not connected or not an input device).
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        let ids = (try? CoreAudioProperty.array(
            AudioObjectID.self,
            object: AudioObjectID(kAudioObjectSystemObject),
            address: CoreAudioProperty.address(kAudioHardwarePropertyDevices),
            operation: "list audio devices")) ?? []
        return ids.first { id in
            (try? CoreAudioProperty.string(
                object: id, address: CoreAudioProperty.address(kAudioDevicePropertyDeviceUID),
                operation: "read a device UID")) == uid
        }
    }

    private static func inputDevice(id: AudioObjectID) -> AudioInputDevice? {
        guard
            let channels = try? CoreAudioProperty.channelCount(device: id, scope: kAudioObjectPropertyScopeInput),
            channels > 0,
            let uid = try? CoreAudioProperty.string(
                object: id, address: CoreAudioProperty.address(kAudioDevicePropertyDeviceUID),
                operation: "read a device UID"),
            !uid.hasPrefix(SystemAudioSource.aggregateUIDPrefix)
        else { return nil }
        let name = (try? CoreAudioProperty.string(
            object: id, address: CoreAudioProperty.address(kAudioObjectPropertyName),
            operation: "read a device name")) ?? uid
        return AudioInputDevice(id: uid, name: name, channelCount: channels)
    }
}
