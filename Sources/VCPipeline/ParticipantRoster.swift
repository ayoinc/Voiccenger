import Foundation
import VCModels

/// Live participant list derived from speaker turns and attributed segments.
///
/// Enrolled speakers take their profile name and colour. Unknown diarizer clusters are named in order of
/// first appearance per channel ("Speaker 1", "Speaker 2" in the room; "Remote 1" over system audio).
public struct ParticipantRoster: Sendable, Hashable {
    public private(set) var participants: [Participant] = []
    private var profiles: [UUID: SpeakerProfile] = [:]
    private var renamed: Set<String> = []

    public init(profiles: [SpeakerProfile] = []) {
        setProfiles(profiles)
    }

    public mutating func setProfiles(_ list: [SpeakerProfile]) {
        profiles = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for i in participants.indices {
            guard let id = participants[i].profileID, let p = profiles[id] else { continue }
            if !renamed.contains(participants[i].id) { participants[i].displayName = p.name }
        }
    }

    public func participant(_ key: String) -> Participant? { participants.first { $0.id == key } }

    public func displayName(for key: String) -> String { participant(key)?.displayName ?? key }

    /// Adds the turn's speaker if new and credits its speaking time.
    public mutating func observe(_ turn: SpeakerTurn) {
        let i = ensure(key: turn.speakerKey, channel: turn.channel, profileID: turn.profileID)
        participants[i].speakingTime += turn.range.duration
    }

    /// Index of the participant for `key`, creating it when needed.
    @discardableResult
    public mutating func ensure(key: String, channel: AudioChannel, profileID: UUID? = nil) -> Int {
        if let i = participants.firstIndex(where: { $0.id == key }) { return i }
        let resolvedProfileID = profileID ?? Self.profileID(fromKey: key)
        let profile = resolvedProfileID.flatMap { profiles[$0] }
        let name: String
        if let profile {
            name = profile.name
        } else if key == TranscriptAligner.unknownSpeakerKey(for: channel) {
            name = channel == .microphone ? "Unidentified speaker" : "Unidentified remote speaker"
        } else {
            let ordinal = participants.filter {
                $0.channel == channel && $0.profileID == nil
                    && $0.id != TranscriptAligner.unknownSpeakerKey(for: channel)
            }.count + 1
            name = channel == .microphone ? "Speaker \(ordinal)" : "Remote \(ordinal)"
        }
        let color = profile?.colorIndex ?? nextColorIndex()
        participants.append(
            Participant(
                id: key, displayName: name, profileID: profile?.id ?? resolvedProfileID, channel: channel,
                localeID: profile?.preferredLocaleID, colorIndex: color))
        return participants.count - 1
    }

    public mutating func rename(_ key: String, to name: String) {
        guard let i = participants.firstIndex(where: { $0.id == key }),
            let trimmed = name.nonEmpty
        else { return }
        participants[i].displayName = trimmed
        renamed.insert(key)
    }

    public mutating func setLocale(_ localeID: String, for key: String) {
        guard let i = participants.firstIndex(where: { $0.id == key }) else { return }
        participants[i].localeID = localeID
    }

    public mutating func setSeat(_ azimuth: Double?, for key: String) {
        guard let i = participants.firstIndex(where: { $0.id == key }) else { return }
        participants[i].seatAzimuthDegrees = azimuth
    }

    public mutating func addSpeakingTime(_ seconds: TimeInterval, for key: String) {
        guard let i = participants.firstIndex(where: { $0.id == key }) else { return }
        participants[i].speakingTime += seconds
    }

    /// Moves a participant to a new key (an unknown speaker who was just enrolled), merging with an
    /// existing participant under `newKey` if one appeared meanwhile.
    public mutating func rekey(_ oldKey: String, to newKey: String, profile: SpeakerProfile) {
        profiles[profile.id] = profile
        guard let i = participants.firstIndex(where: { $0.id == oldKey }) else { return }
        var moved = participants.remove(at: i)
        if let j = participants.firstIndex(where: { $0.id == newKey }) {
            participants[j].speakingTime += moved.speakingTime
            participants[j].displayName = profile.name
            if participants[j].localeID == nil { participants[j].localeID = moved.localeID }
            return
        }
        moved.id = newKey
        moved.profileID = profile.id
        moved.displayName = profile.name
        moved.colorIndex = profile.colorIndex
        participants.insert(moved, at: i)
        renamed.remove(oldKey)
    }

    static func profileID(fromKey key: String) -> UUID? {
        guard key.hasPrefix("profile:") else { return nil }
        return UUID(uuidString: String(key.dropFirst("profile:".count)))
    }

    private func nextColorIndex() -> Int {
        let used = Set(participants.map(\.colorIndex)).union(profiles.values.map(\.colorIndex))
        var i = 0
        while used.contains(i) { i += 1 }
        return i
    }
}
