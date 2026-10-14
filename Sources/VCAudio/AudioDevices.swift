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

/// An input device's OS-level gain and mute (System Settings › Sound › Input), which apply before any app,
/// Voiccenger included, receives the microphone. Muting yourself inside a meeting app does not change them.
public struct InputVolume: Sendable, Hashable {
    /// 0...1; nil when the device has no software volume control.
    public let scalar: Float?
    public let isMuted: Bool

    public init(scalar: Float?, isMuted: Bool) {
        self.scalar = scalar
        self.isMuted = isMuted
    }

    /// The OS delivers only silence from the device.
    public var isSilenced: Bool { isMuted || scalar == 0 }
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

    /// OS input volume and mute of the device (`uid`, else the default input); nil when there is no input device.
    public static func inputVolume(deviceUID uid: String?) -> InputVolume? {
        let device: AudioObjectID? =
            if let uid { deviceID(forUID: uid) } else {
                try? CoreAudioProperty.scalar(
                    AudioObjectID.self, object: AudioObjectID(kAudioObjectSystemObject),
                    address: CoreAudioProperty.address(kAudioHardwarePropertyDefaultInputDevice),
                    operation: "read the default input device")
            }
        guard let device, device != kAudioObjectUnknown else { return nil }
        let input = kAudioObjectPropertyScopeInput
        let mute = inputProperty(UInt32.self, kAudioDevicePropertyMute, device: device, element: kAudioObjectPropertyElementMain)
        // Devices expose either a main-element volume or one per channel; the loudest channel is what gets through.
        var scalar = inputProperty(Float32.self, kAudioDevicePropertyVolumeScalar, device: device, element: kAudioObjectPropertyElementMain)
        if scalar == nil, let channels = try? CoreAudioProperty.channelCount(device: device, scope: input), channels > 0 {
            scalar = (1...channels).compactMap {
                inputProperty(Float32.self, kAudioDevicePropertyVolumeScalar, device: device, element: UInt32($0))
            }.max()
        }
        return InputVolume(scalar: scalar, isMuted: (mute ?? 0) != 0)
    }

    private static func inputProperty<T: BitwiseCopyable>(
        _ type: T.Type, _ selector: AudioObjectPropertySelector, device: AudioObjectID, element: AudioObjectPropertyElement
    ) -> T? {
        var address = CoreAudioProperty.address(selector, scope: kAudioObjectPropertyScopeInput, element: element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        return try? CoreAudioProperty.scalar(type, object: device, address: address, operation: "read input volume")
    }

    private static func inputDevice(id: AudioObjectID) -> AudioInputDevice? {
        guard
            let channels = try? CoreAudioProperty.channelCount(device: id, scope: kAudioObjectPropertyScopeInput),
            channels > 0,
            let uid = try? CoreAudioProperty.string(
                object: id, address: CoreAudioProperty.address(kAudioDevicePropertyDeviceUID),
                operation: "read a device UID"),
            !uid.hasPrefix(CoreAudioProcessTap.aggregateUIDPrefix)
        else { return nil }
        let name = (try? CoreAudioProperty.string(
            object: id, address: CoreAudioProperty.address(kAudioObjectPropertyName),
            operation: "read a device name")) ?? uid
        return AudioInputDevice(id: uid, name: name, channelCount: channels)
    }
}
