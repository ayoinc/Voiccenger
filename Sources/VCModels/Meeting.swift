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

    public init(
        id: UUID = UUID(), title: String, kind: MeetingKind, appName: String? = nil, startedAt: Date = Date(),
        endedAt: Date? = nil, participants: [Participant] = [], segments: [TranscriptSegment] = [],
        report: MeetingReport? = nil, audioFiles: [String] = [], localeIDs: [String] = []
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
    }

    public var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }

    public func participant(_ key: String) -> Participant? { participants.first { $0.id == key } }
}
