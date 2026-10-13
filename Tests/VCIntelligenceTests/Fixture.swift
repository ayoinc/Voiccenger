import Foundation
import VCModels

/// The repository's ground-truth meeting transcript (`.fixtures/meeting.truth.json`).
enum Fixture {
    struct MissingFixture: Error, CustomStringConvertible {
        var description: String { "`.fixtures/meeting.truth.json` not found above \(#filePath)" }
    }

    private struct Line: Decodable {
        var speaker: String
        var start: Double
        var text: String
    }

    static var directory: URL? {
        var url = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
        while url.path != "/" {
            let candidate = url.appendingPathComponent(".fixtures")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("meeting.truth.json").path) {
                return candidate
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    static var isAvailable: Bool { directory != nil }

    /// Fixture lines as model context, with segment ids stable across calls.
    static func transcript() throws -> [ContextLine] {
        guard let directory else { throw MissingFixture() }
        let data = try Data(contentsOf: directory.appendingPathComponent("meeting.truth.json"))
        return try JSONDecoder().decode([Line].self, from: data).enumerated().map { index, line in
            ContextLine(segmentID: segmentID(index), speaker: line.speaker, time: line.start, text: line.text)
        }
    }

    static func segmentID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
    }

    static var speakers: [String] {
        get throws {
            var seen = Set<String>()
            return try transcript().map(\.speaker).filter { seen.insert($0).inserted }
        }
    }
}
