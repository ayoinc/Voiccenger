import Foundation

/// Reads and repairs the header of a PCM WAV recording.
///
/// `AudioRecorder` finalizes the header's sizes when the file is closed. A process that crashes or is force quit
/// mid-recording leaves the audio on disk but a `data` chunk that claims 0 bytes, so every reader sees an empty
/// file; `repair` sets the sizes from the bytes actually there.
public enum WAVHeader {
    public struct Info: Sendable, Hashable {
        public var sampleRate: Double
        public var channels: Int
        /// Bytes per frame (all channels).
        public var blockAlign: Int
        /// File offset of the first audio byte.
        public var dataOffset: UInt64
        /// The `data` chunk's size as written in the header.
        public var declaredDataBytes: UInt64
        /// Whole frames' worth of audio bytes in the file (what the header should say).
        public var dataBytes: UInt64
        /// The header's sizes don't describe the audio in the file (an interrupted recording).
        public var needsRepair: Bool

        public var frames: UInt64 { blockAlign > 0 ? dataBytes / UInt64(blockAlign) : 0 }
        public var duration: TimeInterval { sampleRate > 0 ? Double(frames) / sampleRate : 0 }
    }

    public enum HeaderError: LocalizedError {
        case notWAV(String)
        case unsupported(String)

        public var errorDescription: String? {
            switch self {
            case .notWAV(let name): "\(name) isn't a WAV file."
            case .unsupported(let reason): "Unsupported WAV file: \(reason)."
            }
        }
    }

    /// The header of `url`, with the audio length counted from the file when the header's sizes are stale.
    public static func read(_ url: URL) throws -> Info {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        // The fmt and data chunk headers sit at the start; AVAudioFile reserves at most a few KB before the audio.
        let head = try handle.read(upToCount: 64 * 1024) ?? Data()
        return try parse(head, fileSize: fileSize, name: url.lastPathComponent) { offset in
            guard (try? handle.seek(toOffset: offset)) != nil else { return [] }
            return [UInt8]((try? handle.read(upToCount: 8)) ?? Data())
        }
    }

    /// Rewrites the RIFF and `data` sizes to match the audio in the file. Returns whether anything changed.
    @discardableResult
    public static func repair(_ url: URL) throws -> Bool {
        let info = try read(url)
        guard info.needsRepair else { return false }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: littleEndian(UInt32(clamping: info.dataOffset + info.dataBytes - 8)))
        try handle.seek(toOffset: info.dataOffset - 4)
        try handle.write(contentsOf: littleEndian(UInt32(clamping: info.dataBytes)))
        try handle.synchronize()
        return true
    }

    /// `bytesAt` reads up to 8 bytes at a file offset (what follows the declared audio).
    static func parse(_ head: Data, fileSize: UInt64, name: String, bytesAt: (UInt64) -> [UInt8]) throws -> Info {
        let bytes = [UInt8](head)
        guard bytes.count >= 12, ascii(bytes, 0) == "RIFF", ascii(bytes, 8) == "WAVE" else { throw HeaderError.notWAV(name) }
        var offset = 12
        var format: (channels: Int, sampleRate: Double, blockAlign: Int)?
        while offset + 8 <= bytes.count {
            let id = ascii(bytes, offset)
            let size = UInt64(uint32(bytes, offset + 4))
            let body = offset + 8
            if id == "fmt " {
                guard body + 16 <= bytes.count else { break }
                let tag = uint16(bytes, body)
                // 1 = integer PCM, 3 = float, 0xFFFE = extensible (PCM or float in the sub-format).
                guard tag == 1 || tag == 3 || tag == 0xFFFE else { throw HeaderError.unsupported("format \(tag)") }
                format = (Int(uint16(bytes, body + 2)), Double(uint32(bytes, body + 4)), Int(uint16(bytes, body + 12)))
            } else if id == "data" {
                guard let format, format.blockAlign > 0, format.sampleRate > 0 else {
                    throw HeaderError.unsupported("no format before the audio")
                }
                let dataOffset = UInt64(body)
                let block = UInt64(format.blockAlign)
                let present = fileSize > dataOffset ? (fileSize - dataOffset) / block * block : 0
                // Bytes after the declared audio that don't start another chunk are audio the header never counted.
                let end = dataOffset + size + (size & 1)
                let trailingAudio = end + block <= fileSize && !isChunkHeader(bytesAt(end))
                let needsRepair = size == 0 ? present > 0 : (size > fileSize - dataOffset || trailingAudio)
                return Info(
                    sampleRate: format.sampleRate, channels: format.channels, blockAlign: format.blockAlign,
                    dataOffset: dataOffset, declaredDataBytes: size,
                    dataBytes: needsRepair ? present : min(size / block * block, present), needsRepair: needsRepair)
            }
            offset = body + Int(size) + Int(size & 1)
        }
        throw HeaderError.unsupported("no audio chunk")
    }

    private static func ascii(_ b: [UInt8], _ at: Int) -> String {
        guard at + 4 <= b.count else { return "" }
        return String(decoding: b[at..<at + 4], as: UTF8.self)
    }

    /// Four printable ASCII characters and a size, as every RIFF chunk starts.
    private static func isChunkHeader(_ b: [UInt8]) -> Bool {
        b.count == 8 && b[0..<4].allSatisfy { $0 >= 0x20 && $0 < 0x7F }
    }

    private static func uint16(_ b: [UInt8], _ at: Int) -> UInt16 { UInt16(b[at]) | UInt16(b[at + 1]) << 8 }

    private static func uint32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }

    private static func littleEndian(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
}
