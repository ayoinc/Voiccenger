import Foundation

public struct MeetingApp: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// Dedicated conferencing app (Zoom, Teams, FaceTime…). Mic use ⇒ meeting.
        case native
        /// Browser; mic use likely means Meet/Teams-web/etc. but is less certain.
        case browser
    }

    public let bundleID: String
    public let displayName: String
    public let kind: Kind

    public init(bundleID: String, displayName: String, kind: Kind) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.kind = kind
    }
}

public struct DetectedMeeting: Codable, Sendable, Hashable {
    public let app: MeetingApp
    /// Processes of the app currently using the microphone; used to tap their output audio.
    public let processIDs: [Int32]
    public let startedAt: Date

    public init(app: MeetingApp, processIDs: [Int32], startedAt: Date) {
        self.app = app
        self.processIDs = processIDs
        self.startedAt = startedAt
    }
}

public enum MeetingDetectionEvent: Sendable, Equatable {
    /// A conferencing app started using the microphone.
    case meetingStarted(DetectedMeeting)
    /// That app stopped using the microphone (debounced).
    case meetingEnded(DetectedMeeting)
    /// Sustained multi-turn speech on the microphone with no conferencing app: likely an in-person meeting.
    case conversationDetected(at: Date)
}
