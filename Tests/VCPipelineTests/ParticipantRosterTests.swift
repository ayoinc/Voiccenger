import Foundation
import Testing
import VCModels

@testable import VCPipeline

private func turn(_ key: String, _ channel: AudioChannel, _ seconds: Double, profile: UUID? = nil) -> SpeakerTurn {
    SpeakerTurn(channel: channel, range: TimeRange(start: 0, end: seconds), speakerKey: key, profileID: profile, confidence: 0.9)
}

@Suite("ParticipantRoster")
struct ParticipantRosterTests {
    @Test("Unknown speakers are numbered per channel; enrolled ones use their profile's name, colour and accent")
    func naming() {
        let karen = SpeakerProfile(name: "Karen", embeddings: [], preferredLocaleID: "en-AU", colorIndex: 5)
        var roster = ParticipantRoster(profiles: [karen])
        roster.observe(turn("mic:0", .microphone, 2))
        roster.observe(turn(SpeakerTurn.profileKey(karen.id), .microphone, 3, profile: karen.id))
        roster.observe(turn("mic:7", .microphone, 1))
        roster.observe(turn("sys:0", .system, 4))

        #expect(roster.participants.map(\.displayName) == ["Speaker 1", "Karen", "Speaker 2", "Remote 1"])
        let k = roster.participant(SpeakerTurn.profileKey(karen.id))
        #expect(k?.colorIndex == 5)
        #expect(k?.localeID == "en-AU")
        #expect(k?.isEnrolled == true)
        // Colours are unique and avoid the enrolled profile's colour.
        let colors = roster.participants.map(\.colorIndex)
        #expect(Set(colors).count == colors.count)
    }

    @Test("Speaking time accumulates over repeated turns")
    func speakingTime() {
        var roster = ParticipantRoster()
        roster.observe(turn("mic:0", .microphone, 2))
        roster.observe(turn("mic:0", .microphone, 3.5))
        #expect(roster.participant("mic:0")?.speakingTime == 5.5)
        #expect(roster.participants.count == 1)
    }

    @Test("The unknown key gets a descriptive name and doesn't consume a speaker number")
    func unknownSpeaker() {
        var roster = ParticipantRoster()
        roster.ensure(key: TranscriptAligner.unknownSpeakerKey(for: .microphone), channel: .microphone)
        roster.observe(turn("mic:0", .microphone, 1))
        #expect(roster.participants.map(\.displayName) == ["Unidentified speaker", "Speaker 1"])
    }

    @Test("Renaming ignores blank names; rekeying an enrolled voice merges into an existing participant")
    func renameAndRekey() {
        var roster = ParticipantRoster()
        roster.observe(turn("mic:0", .microphone, 4))
        roster.rename("mic:0", to: "   ")
        #expect(roster.participant("mic:0")?.displayName == "Speaker 1")
        roster.rename("mic:0", to: " Priya ")
        #expect(roster.displayName(for: "mic:0") == "Priya")

        let priya = SpeakerProfile(name: "Priya", embeddings: [[1, 0]], colorIndex: 9)
        let newKey = SpeakerTurn.profileKey(priya.id)
        roster.observe(turn(newKey, .microphone, 2, profile: priya.id))  // matched later in the meeting
        roster.rekey("mic:0", to: newKey, profile: priya)
        #expect(roster.participants.count == 1)
        #expect(roster.participant(newKey)?.speakingTime == 6)
        #expect(roster.participant("mic:0") == nil)
    }
}
