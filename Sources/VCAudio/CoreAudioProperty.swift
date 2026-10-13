import CoreAudio
import Foundation

/// Typed wrappers over `AudioObjectGetPropertyData` for the handful of property shapes this module reads.
enum CoreAudioProperty {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// Reads a fixed-size value. `qualifier` is passed verbatim (e.g. a pid for PID→process translation).
    static func scalar<T: BitwiseCopyable>(
        _ type: T.Type,
        object: AudioObjectID,
        address: AudioObjectPropertyAddress,
        qualifier: UnsafeRawBufferPointer? = nil,
        operation: @autoclosure () -> String
    ) throws -> T {
        var address = address
        var size = UInt32(MemoryLayout<T>.size)
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { storage.deallocate() }
        let status = AudioObjectGetPropertyData(
            object, &address, UInt32(qualifier?.count ?? 0), qualifier?.baseAddress, &size, storage)
        guard status == noErr else {
            throw AudioCaptureError.coreAudio(operation: operation(), status: status)
        }
        return storage.load(as: T.self)
    }

    /// Reads a variable-length array of fixed-size elements (object lists).
    static func array<T: BitwiseCopyable>(
        _ type: T.Type,
        object: AudioObjectID,
        address: AudioObjectPropertyAddress,
        operation: @autoclosure () -> String
    ) throws -> [T] {
        var address = address
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
        guard status == noErr else {
            throw AudioCaptureError.coreAudio(operation: operation(), status: status)
        }
        let capacity = Int(size) / MemoryLayout<T>.stride
        guard capacity > 0 else { return [] }
        return try [T](unsafeUninitializedCapacity: capacity) { buffer, count in
            status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer.baseAddress!)
            guard status == noErr else {
                count = 0
                throw AudioCaptureError.coreAudio(operation: operation(), status: status)
            }
            count = min(capacity, Int(size) / MemoryLayout<T>.stride)
        }
    }

    /// Reads a CFString property (Core Audio returns +1 retained strings).
    static func string(
        object: AudioObjectID,
        address: AudioObjectPropertyAddress,
        operation: @autoclosure () -> String
    ) throws -> String {
        var address = address
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr else {
            throw AudioCaptureError.coreAudio(operation: operation(), status: status)
        }
        guard let value else { return "" }
        return value.takeRetainedValue() as String
    }

    /// Total channels described by a stream-configuration `AudioBufferList` in `scope`.
    static func channelCount(device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size)
        guard status == noErr else {
            throw AudioCaptureError.coreAudio(operation: "read the stream configuration", status: status)
        }
        guard size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage)
        guard status == noErr else {
            throw AudioCaptureError.coreAudio(operation: "read the stream configuration", status: status)
        }
        let list = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// "'!hog' (560492391)" for four-character codes, the bare number otherwise.
    static func describe(_ status: OSStatus) -> String {
        let code = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> UInt32($0)) }
        if bytes.allSatisfy({ (0x20...0x7E).contains($0) }) {
            return "'\(String(decoding: bytes, as: UTF8.self))' (\(status))"
        }
        return "OSStatus \(status)"
    }
}
