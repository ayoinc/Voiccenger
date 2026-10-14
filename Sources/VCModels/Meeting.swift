import Foundation

public enum MeetingKind: String, Codable, Sendable, Hashable {
    case online
    case inPerson
}

public struct Meeting: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var kind: MeetingKind
    /// Conferencing app display name for online meetings.
    public var appName: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var participants: [Participant]
    public var segments: [TranscriptSegment]
    public var report: MeetingReport?
    /// Recording file names relative to the meeting's storage directory.
    public var audioFiles: [String]
    /// Every recognizer locale used during the meeting.
    public var localeIDs: [String]
    /// Capture problems raised while recording (a silent meeting app, a silenced microphone).
    public var captureWarnings: [CaptureWarning]

    public init(
        id: UUID = UUID(), title: String, kind: MeetingKind, appName: String? = nil, startedAt: Date = Date(),
        endedAt: Date? = nil, participants: [Participant] = [], segments: [TranscriptSegment] = [],
        report: MeetingReport? = nil, audioFiles: [String] = [], localeIDs: [String] = [],
        captureWarnings: [CaptureWarning] = []
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.appName = appName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.participants = participants
        self.segments = segments
        self.report = report
        self.audioFiles = audioFiles
        self.localeIDs = localeIDs
        self.captureWarnings = captureWarnings
    }

    /// Meetings saved before capture warnings existed decode with none.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        kind = try c.decode(MeetingKind.self, forKey: .kind)
        appName = try c.decodeIfPresent(String.self, forKey: .appName)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        participants = try c.decode([Participant].self, forKey: .participants)
        segments = try c.decode([TranscriptSegment].self, forKey: .segments)
        report = try c.decodeIfPresent(MeetingReport.self, forKey: .report)
        audioFiles = try c.decode([String].self, forKey: .audioFiles)
        localeIDs = try c.decode([String].self, forKey: .localeIDs)
        captureWarnings = try c.decodeIfPresent([CaptureWarning].self, forKey: .captureWarnings) ?? []
    }

    public var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }

    public func participant(_ key: String) -> Participant? { participants.first { $0.id == key } }
}

/// A problem with what a meeting's recording can hear, raised live and kept with the meeting.
public struct CaptureWarning: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable {
        /// A meeting app is active but nothing it plays reaches the computer-audio channel.
        case meetingAppSilent
        /// The microphone delivers digital silence.
        case microphoneSilent
        /// macOS input volume is 0 or the input is muted.
        case microphoneMuted
    }

    public var kind: Kind
    public var message: String
    /// Session seconds at which it was first raised.
    public var time: TimeInterval

    public init(kind: Kind, message: String, time: TimeInterval) {
        self.kind = kind
        self.message = message
        self.time = time
    }

    public var id: Kind { kind }
}
