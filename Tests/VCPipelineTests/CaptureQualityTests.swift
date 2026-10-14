import Foundation
import Testing
import VCAudio
import VCModels

@testable import VCPipeline

private func line(_ channel: AudioChannel, _ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
    TranscriptSegment(
        channel: channel, speakerKey: "\(channel.keyPrefix):S1", range: TimeRange(start: start, end: end), text: text,
        confidence: nil, localeID: "en-GB")
}

@Suite("Bleed suppression")
struct BleedSuppressionTests {
    @Test("A mic line repeating the remote party heard through the speakers is bleed")
    func duplicateIsBleed() {
        let system = [line(.system, 10, 14, "So the budget's fixed at ten thousand pounds for the quarter.")]
        // The mic hears it later and the recognizer gets a few words differently.
        let mic = line(.microphone, 10.3, 14.2, "so the budget fixed at ten thousand pound for the quarter")
        #expect(BleedSuppression.isBleed(mic, system: system))
    }

    @Test("Someone in the room talking over the remote party is kept")
    func differentSimultaneousSpeechIsKept() {
        let system = [line(.system, 10, 14, "So the budget's fixed at ten thousand pounds for the quarter.")]
        let mic = line(.microphone, 10.5, 13.5, "Sorry, can you hear me? I think my camera is frozen.")
        #expect(!BleedSuppression.isBleed(mic, system: system))
    }

    @Test("Matching words without enough time overlap are not bleed")
    func needsTimeOverlap() {
        let system = [line(.system, 10, 12, "Let's move on to the hiring plan.")]
        let mic = line(.microphone, 11.5, 15, "let's move on to the hiring plan")
        #expect(!BleedSuppression.isBleed(mic, system: system))
    }

    @Test("A mic line spanning two remote lines matches their joined words")
    func spansSeveralSystemLines() {
        let system = [
            line(.system, 20, 22, "We shipped the beta on Monday."),
            line(.system, 22, 25, "Feedback has been positive so far."),
        ]
        let mic = line(.microphone, 20.2, 25.1, "we shipped the beta on monday feedback has been positive so far")
        #expect(BleedSuppression.isBleed(mic, system: system))
    }

    @Test("Word similarity is the share of mic words found in order")
    func similarity() {
        let words = BleedSuppression.words("Don’t worry, it's FINE.")
        #expect(words == ["don't", "worry", "it's", "fine"])
        #expect(BleedSuppression.similarity(mic: ["a", "b", "c", "d"], system: ["x", "a", "c", "y", "d"]) == 0.75)
        #expect(BleedSuppression.similarity(mic: ["d", "c", "b", "a"], system: ["a", "b", "c", "d"]) == 0.25)
        #expect(BleedSuppression.similarity(mic: [], system: ["a"]) == 0)
    }
}

@Suite("Capture health")
struct CaptureHealthTests {
    @Test("A meeting app whose sound stays silent for over 20 s raises the turn-up-the-app warning")
    func silentMeetingApp() {
        var health = CaptureHealthMonitor()
        health.setMeetingApp("Microsoft Teams", at: 0)
        for t in stride(from: 0.5, through: 20, by: 0.5) {
            health.system(rmsDB: -120, at: t)
            health.microphone(peak: 0.05, at: t)
        }
        let early = health.evaluate(at: 20)
        #expect(!early)
        #expect(health.active.isEmpty)
        let raised = health.evaluate(at: 20.5)
        #expect(raised)
        let warning = try! #require(health.active.first)
        #expect(warning.kind == .meetingAppSilent)
        #expect(
            warning.message
                == "Microsoft Teams is playing no sound. Voiccenger records what the app plays, so turn up Microsoft Teams's own speaker volume (your Mac's volume can stay at 0)."
        )

        // Quiet but real audio (−41 dBFS from an HDMI monitor) clears it; the stored record stays.
        health.system(rmsDB: -41, at: 21)
        let cleared = health.evaluate(at: 21.5)
        #expect(cleared)
        #expect(health.active.isEmpty)
        #expect(health.raised.map(\.kind) == [.meetingAppSilent])
        #expect(health.raised.first?.time == 20.5)
    }

    @Test("Without a meeting app silence from the computer is fine")
    func noMeetingApp() {
        var health = CaptureHealthMonitor()
        health.microphone(peak: 0.05, at: 0.5)
        health.microphone(peak: 0.05, at: 60)
        health.evaluate(at: 60)
        #expect(health.active.isEmpty)
    }

    @Test("A digitally silent microphone or an OS-muted input raises a warning")
    func microphone() {
        var health = CaptureHealthMonitor()
        for t in stride(from: 0.5, through: 6, by: 0.5) { health.microphone(peak: 0, at: t) }
        health.evaluate(at: 6)
        #expect(health.active.map(\.kind) == [.microphoneSilent])

        health.microphone(peak: 0.001, at: 6.5)
        health.evaluate(at: 6.5)
        #expect(health.active.isEmpty)

        health.inputVolume(InputVolume(scalar: 0, isMuted: false))
        health.evaluate(at: 7)
        #expect(health.active.map(\.kind) == [.microphoneMuted])
        health.inputVolume(InputVolume(scalar: 0.7, isMuted: true))
        health.evaluate(at: 7.5)
        #expect(health.active.map(\.kind) == [.microphoneMuted])
        health.inputVolume(InputVolume(scalar: 0.7, isMuted: false))
        health.evaluate(at: 8)
        #expect(health.active.isEmpty)
        #expect(health.raised.map(\.kind) == [.microphoneSilent, .microphoneMuted])
    }

    @Test("Meetings saved before capture warnings still load")
    func legacyMeetingDecodes() throws {
        let meeting = Meeting(
            title: "Old", kind: .inPerson, captureWarnings: [
                CaptureWarning(kind: .microphoneMuted, message: "m", time: 3)
            ])
        let data = try MeetingStore.encoder.encode(meeting)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["captureWarnings"] != nil)
        json["captureWarnings"] = nil
        let legacy = try JSONSerialization.data(withJSONObject: json)
        let decoder = MeetingStore.decoder
        let decoded = try decoder.decode(Meeting.self, from: legacy)
        #expect(decoded.captureWarnings.isEmpty)
        #expect(decoded.title == "Old")
        let roundTrip = try decoder.decode(Meeting.self, from: data)
        #expect(roundTrip.captureWarnings == meeting.captureWarnings)
    }
}

@Suite("Voice clips")
struct VoiceClipExclusionTests {
    @Test("Computer-audio speech is cut out of microphone voice clips")
    func subtract() {
        let pieces = VoiceClipCollector.subtract(
            [TimeRange(start: 1, end: 2), TimeRange(start: 3, end: 3.5), TimeRange(start: 9, end: 10)],
            from: TimeRange(start: 0.5, end: 4))
        #expect(pieces == [TimeRange(start: 0.5, end: 1), TimeRange(start: 2, end: 3), TimeRange(start: 3.5, end: 4)])
    }

    @Test("A microphone speaker's clip skips what the computer was saying")
    func collectorExcludes() async {
        let collector = VoiceClipCollector()
        await collector.append(AudioChunk(channel: .microphone, startTime: 0, sampleRate: 100, samples: [Float](repeating: 1, count: 400)))
        await collector.excludeSystemSpeech([TimeRange(start: 1, end: 3)])
        await collector.collect([
            SpeakerTurn(channel: .microphone, range: TimeRange(start: 0, end: 4), speakerKey: "mic:S1", profileID: nil, confidence: 1, isAmbiguous: false)
        ])
        #expect(await collector.seconds(for: "mic:S1") == 2)
    }
}
