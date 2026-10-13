import Foundation
import VCModels

/// On-disk locations used by the app and CLI.
public struct AppPaths: Sendable, Hashable {
    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/Library/Application Support/Voiccenger`.
    public static var `default`: AppPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return AppPaths(root: base.appending(path: "Voiccenger", directoryHint: .isDirectory))
    }

    public var meetings: URL { root.appending(path: "Meetings", directoryHint: .isDirectory) }
    public var profiles: URL { root.appending(path: "Profiles", directoryHint: .isDirectory) }
}

/// One directory per meeting: `<directory>/<uuid>/meeting.json` plus its audio recordings.
public actor MeetingStore {
    public nonisolated let directory: URL
    public static let fileName = "meeting.json"

    public init(directory: URL) {
        self.directory = directory
    }

    public func save(_ m: Meeting) throws {
        let dir = directory(for: m.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(m)
        try data.write(to: dir.appending(path: Self.fileName), options: .atomic)
    }

    /// Every readable meeting, newest first. Directories without a decodable `meeting.json`
    /// (e.g. a recording interrupted before saving) are skipped.
    public func all() throws -> [Meeting] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        let dirs = try fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var meetings: [Meeting] = []
        for dir in dirs {
            let file = dir.appending(path: Self.fileName)
            guard let data = try? Data(contentsOf: file),
                let meeting = try? Self.decoder.decode(Meeting.self, from: data)
            else { continue }
            meetings.append(meeting)
        }
        return meetings.sorted { $0.startedAt > $1.startedAt }
    }

    public func meeting(id: UUID) throws -> Meeting {
        let data = try Data(contentsOf: directory(for: id).appending(path: Self.fileName))
        return try Self.decoder.decode(Meeting.self, from: data)
    }

    public func delete(id: UUID) throws {
        let dir = directory(for: id)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try FileManager.default.removeItem(at: dir)
    }

    public nonisolated func directory(for id: UUID) -> URL {
        directory.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    /// Default date strategy (reference-date seconds) so dates round-trip exactly.
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    public static var decoder: JSONDecoder {
        JSONDecoder()
    }
}
