import Foundation
import VCModels

/// Persists enrolled speaker profiles as `profiles.json` in `directory`.
/// Every mutation rewrites the file atomically (temp file + rename), so a crash never leaves a
/// half-written store. An unreadable file is moved aside to `profiles.corrupt-<timestamp>.json`
/// rather than silently overwritten.
public actor SpeakerProfileStore {
    public nonisolated let directory: URL
    private var profiles: [SpeakerProfile]

    public init(directory: URL) {
        self.directory = directory
        self.profiles = Self.load(from: directory)
    }

    public nonisolated var fileURL: URL { Self.fileURL(in: directory) }

    /// Profiles in enrollment order.
    public func all() -> [SpeakerProfile] { profiles }

    /// Inserts a new profile or replaces the one with the same id.
    public func upsert(_ p: SpeakerProfile) throws {
        var next = profiles
        if let index = next.firstIndex(where: { $0.id == p.id }) {
            next[index] = p
        } else {
            next.append(p)
        }
        try persist(next)
        profiles = next
    }

    /// Removes the profile with `id`. Deleting an unknown id is a no-op.
    public func delete(id: UUID) throws {
        guard profiles.contains(where: { $0.id == id }) else { return }
        let next = profiles.filter { $0.id != id }
        try persist(next)
        profiles = next
    }

    private func persist(_ profiles: [SpeakerProfile]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(profiles).write(to: fileURL, options: .atomic)
    }

    private static func fileURL(in directory: URL) -> URL {
        directory.appending(path: "profiles.json", directoryHint: .notDirectory)
    }

    private static func load(from directory: URL) -> [SpeakerProfile] {
        let url = fileURL(in: directory)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([SpeakerProfile].self, from: data) { return decoded }
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = directory.appending(path: "profiles.corrupt-\(stamp).json", directoryHint: .notDirectory)
        try? FileManager.default.moveItem(at: url, to: backup)
        return []
    }
}
