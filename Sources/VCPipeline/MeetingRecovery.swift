import Foundation
import VCAudio
import VCModels

/// How far `MeetingSession.processRecording` has got.
public enum ProcessingProgress: Sendable, Hashable {
    /// Share of the recording replayed through the pipeline, 0...1.
    case transcribing(Double)
    /// Waiting for the last lines' speakers and voice-model text.
    case finishingLines
    case writingReport
    case saving

    /// Overall share done, for a progress bar (transcription is most of the work).
    public var fraction: Double {
        switch self {
        case .transcribing(let f): 0.85 * min(1, max(0, f))
        case .finishingLines: 0.88
        case .writingReport: 0.92
        case .saving: 0.99
        }
    }

    public var label: String {
        switch self {
        case .transcribing(let f): "Transcribing… \(Int((f * 100).rounded()))%"
        case .finishingLines: "Finishing the last lines…"
        case .writingReport: "Writing the report…"
        case .saving: "Saving…"
        }
    }
}

/// Turning an `UnsavedRecording` back into a saved meeting.
public enum MeetingRecovery {
    /// The meeting its journal recorded, saved in its folder at once (the journal is then deleted). Recordings left
    /// with unfinished headers by the interrupted app are repaired so they can be played and transcribed again.
    public static func restoreFromJournal(_ recording: UnsavedRecording, store: MeetingStore) async throws -> Meeting {
        let replay = try MeetingJournal.replay(recording.journalURL)
        for name in recording.audioFiles { _ = try? WAVHeader.repair(recording.directory.appending(path: name)) }
        let start = replay.header?.startedAt ?? recording.startedAt
        let meeting = replay.meeting(
            id: recording.id, startedAt: start,
            endedAt: recording.audioFiles.isEmpty ? nil : start.addingTimeInterval(recording.duration),
            audioFiles: recording.audioFiles)
        try await store.save(meeting)
        return meeting
    }
}
