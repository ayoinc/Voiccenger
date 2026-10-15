import Foundation
import VCAudio
import VCModels

/// A meeting folder that recorded but was never saved: audio and/or a journal, no `meeting.json` (the app quit,
/// crashed or was force quit before the meeting finished saving).
public struct UnsavedRecording: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var directory: URL
    /// From the journal when there is one, else when the folder and its recordings were created.
    public var startedAt: Date
    /// The longest recording, else the journal's last line.
    public var duration: TimeInterval
    /// Recordings with audio in them (`microphone.wav` before `system.wav`).
    public var audioFiles: [String]
    /// `journal.jsonl` is there: the transcript can be restored at once.
    public var hasJournal: Bool
    /// Newest modification of anything in the folder.
    public var lastModified: Date

    /// The folder's recording of `channel`, when it has audio.
    public func audioURL(_ channel: AudioChannel) -> URL? {
        let name = Self.audioFileName(channel)
        return audioFiles.contains(name) ? directory.appending(path: name) : nil
    }

    public var journalURL: URL { directory.appending(path: MeetingJournal.fileName) }

    public static func audioFileName(_ channel: AudioChannel) -> String { "\(channel.rawValue).wav" }

    /// The unsaved recording in `directory` (a meeting folder, named by the meeting's id), or nil when it's saved
    /// (`meeting.json`), holds nothing to recover, or isn't a meeting folder.
    public static func inspect(_ directory: URL) -> UnsavedRecording? {
        let fm = FileManager.default
        guard let id = UUID(uuidString: directory.lastPathComponent),
            (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
            !fm.fileExists(atPath: directory.appending(path: MeetingStore.fileName).path)
        else { return nil }
        var audio: [String] = []
        var duration = 0.0
        var dates: [Date] = []
        var modified: [Date] = []
        if let values = try? directory.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) {
            if let c = values.creationDate { dates.append(c) }
            if let m = values.contentModificationDate { modified.append(m) }
        }
        for channel in AudioChannel.allCases {
            let url = directory.appending(path: audioFileName(channel))
            guard let info = try? WAVHeader.read(url), info.frames > 0 else { continue }
            audio.append(url.lastPathComponent)
            duration = max(duration, info.duration)
            if let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) {
                if let c = values.creationDate { dates.append(c) }
                if let m = values.contentModificationDate { modified.append(m) }
            }
        }
        let journalURL = directory.appending(path: MeetingJournal.fileName)
        var replay: MeetingJournal.Replay?
        if let size = (try? journalURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 {
            replay = try? MeetingJournal.replay(journalURL)
            if let m = (try? journalURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                modified.append(m)
            }
        }
        guard !audio.isEmpty || replay?.segments.isEmpty == false else { return nil }
        if duration == 0, let replay { duration = replay.segments.map(\.range.end).max() ?? 0 }
        return UnsavedRecording(
            id: id, directory: directory,
            startedAt: replay?.header?.startedAt ?? dates.min() ?? Date(), duration: duration, audioFiles: audio,
            hasJournal: replay?.segments.isEmpty == false, lastModified: modified.max() ?? dates.max() ?? Date())
    }
}

extension MeetingStore {
    /// Meeting folders that recorded but were never saved, newest first. `excluding` is the meeting recording now;
    /// folders written to within `quietFor` seconds may still be recording (another process) and are left out.
    public nonisolated func unsavedRecordings(
        excluding active: UUID? = nil, quietFor: TimeInterval = 0, now: Date = Date()
    ) -> [UnsavedRecording] {
        let fm = FileManager.default
        guard
            let dirs = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        return dirs.compactMap { dir -> UnsavedRecording? in
            guard UUID(uuidString: dir.lastPathComponent) != active, let recording = UnsavedRecording.inspect(dir),
                now.timeIntervalSince(recording.lastModified) >= quietFor
            else { return nil }
            return recording
        }
        .sorted { $0.startedAt > $1.startedAt }
    }
}
