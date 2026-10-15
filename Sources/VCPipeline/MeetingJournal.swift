import Foundation
import VCModels
import os

private let journalLog = Logger(subsystem: "com.voiccenger.app", category: "journal")

/// One line of a meeting's journal: exactly one field is set.
public struct JournalRecord: Codable, Sendable, Hashable {
    /// What a meeting is, written when recording starts and again when it changes (an in-person recording
    /// becoming an online meeting).
    public struct Header: Codable, Sendable, Hashable {
        public var meetingID: UUID
        public var title: String?
        public var kind: MeetingKind
        public var appName: String?
        public var startedAt: Date
        public var localeIDs: [String]

        public init(
            meetingID: UUID, title: String?, kind: MeetingKind, appName: String?, startedAt: Date, localeIDs: [String]
        ) {
            self.meetingID = meetingID
            self.title = title
            self.kind = kind
            self.appName = appName
            self.startedAt = startedAt
            self.localeIDs = localeIDs
        }
    }

    /// A participant moved to a new key (an unknown speaker enrolled mid-meeting).
    public struct Rekey: Codable, Sendable, Hashable {
        public var from: String
        public var to: String
    }

    public var header: Header?
    /// A finalized line, or a later version of one (re-transcribed): replaces the line with the same id.
    public var segment: TranscriptSegment?
    /// Lines withdrawn (they repeated the computer's audio heard through the speakers).
    public var removed: [UUID]?
    public var rekey: Rekey?
    /// The whole participant list as it stands.
    public var participants: [Participant]?

    public static func header(_ h: Header) -> Self { Self(header: h) }
    public static func segment(_ s: TranscriptSegment) -> Self { Self(segment: s) }
    public static func removed(_ ids: [UUID]) -> Self { Self(removed: ids) }
    public static func rekey(from: String, to: String) -> Self { Self(rekey: Rekey(from: from, to: to)) }
    public static func participants(_ p: [Participant]) -> Self { Self(participants: p) }
}

/// Append-only record of a meeting while it records: `<meeting dir>/journal.jsonl`, one `JournalRecord` per line.
///
/// Every finalized line and roster change is written as it happens, straight to the file (no buffering in the
/// process), so a crash or force quit leaves the transcript up to the last line. Appending costs one short write
/// per line however long the meeting is, unlike rewriting the whole meeting on a timer, and a journal is never
/// mistaken for a saved meeting. `MeetingStore.save` deletes it once `meeting.json` is written.
public final class MeetingJournal: Sendable {
    public static let fileName = "journal.jsonl"

    public let url: URL
    private let handle: Mutex<FileHandle?>

    /// Opens (creating when needed) the journal in `directory`, appending to what's there.
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appending(path: Self.fileName)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        self.handle = Mutex(handle)
    }

    /// Appends one record. A write failure is logged; the meeting itself carries on.
    public func append(_ record: JournalRecord) {
        guard var data = try? Self.encoder.encode(record) else { return }
        data.append(0x0A)
        handle.withLock { handle in
            guard let h = handle else { return }
            do {
                try h.write(contentsOf: data)
            } catch {
                journalLog.error("Journal write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func close() {
        handle.withLock { handle in
            try? handle?.close()
            handle = nil
        }
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    // MARK: - Replay

    /// The meeting as the journal recorded it.
    public struct Replay: Sendable, Hashable {
        public var header: JournalRecord.Header?
        /// In time order.
        public var segments: [TranscriptSegment]
        public var participants: [Participant]
        /// Lines that couldn't be read (a write cut short by a crash).
        public var unreadableLines: Int

        /// The meeting `id` (its folder's name), ending at `endedAt` (default: the last line's end). Untitled
        /// meetings are named as `MeetingSession` names them.
        public func meeting(id: UUID, startedAt fallbackStart: Date, endedAt: Date? = nil, audioFiles: [String]) -> Meeting {
            let start = header?.startedAt ?? fallbackStart
            let end = endedAt ?? start.addingTimeInterval(segments.map(\.range.end).max() ?? 0)
            let kind = header?.kind ?? .inPerson
            let date = start.formatted(date: .abbreviated, time: .shortened)
            let title =
                header?.title
                ?? (header?.appName.map { "\($0) meeting, \(date)" }
                    ?? (kind == .online ? "Online meeting, \(date)" : "Meeting, \(date)"))
            var locales = header?.localeIDs ?? []
            for s in segments where !locales.contains(s.localeID) { locales.append(s.localeID) }
            return Meeting(
                id: id, title: title, kind: kind, appName: header?.appName, startedAt: start,
                endedAt: end, participants: participants, segments: segments, audioFiles: audioFiles, localeIDs: locales)
        }
    }

    /// Reads a journal, applying its records in order. Unreadable lines (a truncated last write) are skipped.
    public static func replay(_ url: URL) throws -> Replay {
        let data = try Data(contentsOf: url)
        let decoder = MeetingStore.decoder
        var header: JournalRecord.Header?
        var segments: [TranscriptSegment] = []
        var index: [UUID: Int] = [:]
        var participants: [Participant] = []
        var unreadable = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let record = try? decoder.decode(JournalRecord.self, from: Data(line)) else {
                unreadable += 1
                continue
            }
            if let h = record.header {
                // Locales accumulate; the rest is the latest description of the meeting.
                var merged = h
                for l in header?.localeIDs ?? [] where !merged.localeIDs.contains(l) { merged.localeIDs.append(l) }
                header = merged
            }
            if let s = record.segment {
                if let i = index[s.id] {
                    segments[i] = s
                } else {
                    index[s.id] = segments.count
                    segments.append(s)
                }
            }
            if let ids = record.removed, !ids.isEmpty {
                let gone = Set(ids)
                segments.removeAll { gone.contains($0.id) }
                index = Dictionary(uniqueKeysWithValues: segments.enumerated().map { ($1.id, $0) })
            }
            if let r = record.rekey {
                for i in segments.indices where segments[i].speakerKey == r.from { segments[i].speakerKey = r.to }
            }
            if let p = record.participants { participants = p }
        }
        // Every line's speaker is a participant, even one heard after the last roster write.
        for s in segments where !participants.contains(where: { $0.id == s.speakerKey }) {
            let n = participants.filter { $0.channel == s.channel }.count + 1
            participants.append(
                Participant(
                    id: s.speakerKey, displayName: s.channel == .system ? "Remote \(n)" : "Speaker \(n)", channel: s.channel,
                    colorIndex: participants.count))
        }
        segments.sort { $0.range.start < $1.range.start }
        return Replay(header: header, segments: segments, participants: participants, unreadableLines: unreadable)
    }
}
