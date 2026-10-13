import Foundation
import Testing
import VCModels
import VCTranscription

@testable import VCPipeline

@Suite("Session voices: prompt, customization, routing")
struct SessionVoicesTests {
    static func profile(
        _ name: String, accent: String? = nil, lives: String? = nil, language: String = "en",
        engine: SpeechEngineKind? = nil, calibratedBest: SpeechEngineKind? = nil, vocabulary: [String] = [],
        replacements: [TextReplacement] = [], regional: Bool = true, spelling: SpellingVariant = .unchanged
    ) -> SpeakerProfile {
        SpeakerProfile(
            name: name, embeddings: [],
            voice: VoiceSettings(
                accentRegionID: accent, residenceRegionID: lives, languageCode: language, spelling: spelling,
                preferredEngine: engine, vocabulary: vocabulary, replacements: replacements,
                useRegionalVocabulary: regional,
                calibration: calibratedBest.map {
                    VoiceCalibration(scores: [EngineScore(engine: $0, wordErrorRate: 0.02, transcript: "")])
                }))
    }

    static func key(_ p: SpeakerProfile) -> String { SpeakerTurn.profileKey(p.id) }

    // MARK: Prompt

    @Test("Prompt puts session terms, names and personal vocabulary before regional names, without duplicates")
    func promptOrderAndDedup() throws {
        let ngozi = Self.profile("Ngozi", accent: "ng", vocabulary: ["Lekki", "ngozi", "  "])
        let tom = Self.profile("Tom", accent: "gb", vocabulary: ["Voiccenger"], regional: false)
        let prompt = SessionVoices.prompt(contextualStrings: ["Voiccenger", "Q3 roadmap"], profiles: [ngozi, tom])

        #expect(Array(prompt.prefix(5)) == ["Voiccenger", "Q3 roadmap", "Ngozi", "Tom", "Lekki"])
        #expect(Set(prompt.map { $0.lowercased() }).count == prompt.count, "case-insensitive duplicates removed")
        #expect(!prompt.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })

        let nigeria = try #require(AccentRegions.region("ng"))
        let lowered = Set(prompt.map { $0.lowercased() })
        #expect(nigeria.vocabulary.allSatisfy { lowered.contains($0.lowercased()) }, "Nigerian names and places included")
        let britain = try #require(AccentRegions.region("gb"))
        let britishOnly = britain.vocabulary.filter { term in !nigeria.vocabulary.contains { $0.caseInsensitiveCompare(term) == .orderedSame } }
        #expect(!britishOnly.isEmpty)
        #expect(britishOnly.allSatisfy { !lowered.contains($0.lowercased()) }, "Tom opted out of regional vocabulary")
    }

    @Test("The prompt covers where someone lives as well as their accent, unless they opted out")
    func residenceVocabulary() throws {
        let prompt = Set(SessionVoices.prompt(contextualStrings: [], profiles: [Self.profile("Kofi", accent: "gh", lives: "gb")]).map { $0.lowercased() })
        #expect(try #require(AccentRegions.region("gh")).vocabulary.allSatisfy { prompt.contains($0.lowercased()) })
        #expect(try #require(AccentRegions.region("gb")).vocabulary.allSatisfy { prompt.contains($0.lowercased()) })
        let optedOut = SessionVoices.prompt(
            contextualStrings: [], profiles: [Self.profile("Kofi", accent: "gh", lives: "gb", regional: false)])
        #expect(optedOut == ["Kofi"])
    }

    @Test("Voices enrolled mid-meeting join the prompt")
    func upsertExtendsPrompt() {
        var voices = SessionVoices(profiles: [], contextualStrings: ["Standup"], sessionSpelling: .unchanged)
        #expect(voices.prompt == ["Standup"])
        let amara = Self.profile("Amara", vocabulary: ["Enugu"], regional: false)
        voices.upsert(amara)
        #expect(voices.prompt == ["Standup", "Amara", "Enugu"])
        #expect(voices.profile(forSpeakerKey: Self.key(amara))?.name == "Amara")
    }

    // MARK: Customization

    @Test("Only the enrolled speaker's own replacements apply to their lines")
    func customizationIsPerSpeaker() {
        let ngozi = Self.profile("Ngozi", replacements: [TextReplacement(heard: "go see", meant: "Ngozi")], regional: false)
        let voices = SessionVoices(profiles: [ngozi], contextualStrings: [], sessionSpelling: .unchanged)
        #expect(voices.customize("Hi, it's go see here", speakerKey: Self.key(ngozi)) == "Hi, it's Ngozi here")
        #expect(voices.customize("I'll go see later", speakerKey: "mic:1") == "I'll go see later")
        #expect(voices.customize("I'll go see later", speakerKey: SpeakerTurn.profileKey(UUID())) == "I'll go see later")
    }

    @Test("Unenrolled speakers get the session spelling; enrolled ones their own, else the session's")
    func spelling() {
        let us = Self.profile("Sam", regional: false, spelling: .american)
        let unset = Self.profile("Ade", regional: false)
        let voices = SessionVoices(profiles: [us, unset], contextualStrings: [], sessionSpelling: .british)
        #expect(voices.customize("The color of the organization", speakerKey: "mic:2") == "The colour of the organisation")
        #expect(voices.customize("The colour of the organisation", speakerKey: Self.key(us)) == "The color of the organization")
        #expect(voices.customize("The color of the organization", speakerKey: Self.key(unset)) == "The colour of the organisation")
    }

    // MARK: Routing

    static let downloaded: Set<SpeechEngineKind> = [.apple, .cohere, .whisper]

    @Test("A speaker's own engine re-transcribes lines another engine produced, when it's downloaded")
    func routesToPreferredEngine() {
        let ama = Self.profile("Ama", engine: .whisper)
        let voices = SessionVoices(profiles: [ama], contextualStrings: [], sessionSpelling: .unchanged)
        let key = Self.key(ama)
        #expect(
            voices.route(speakerKey: key, segmentEngine: .cohere, segmentLanguage: "en", available: Self.downloaded)
                == EngineRoute(engine: .whisper, languageCode: "en"))
        #expect(voices.route(speakerKey: key, segmentEngine: .whisper, segmentLanguage: "en", available: Self.downloaded) == nil)
        #expect(voices.route(speakerKey: key, segmentEngine: .cohere, segmentLanguage: "en", available: [.apple, .cohere]) == nil)
        #expect(voices.route(speakerKey: "mic:0", segmentEngine: .apple, segmentLanguage: "en", available: Self.downloaded) == nil)
    }

    @Test("Without a manual choice the calibration's best engine is used; uncalibrated speakers keep the line")
    func routesToCalibratedEngine() {
        let calibrated = Self.profile("Juma", calibratedBest: .cohere)
        let plain = Self.profile("Lee")
        let voices = SessionVoices(profiles: [calibrated, plain], contextualStrings: [], sessionSpelling: .unchanged)
        // An Apple pass-through line (the model was still warming up) goes to the speaker's engine.
        #expect(
            voices.route(speakerKey: Self.key(calibrated), segmentEngine: .apple, segmentLanguage: "en", available: Self.downloaded)
                == EngineRoute(engine: .cohere, languageCode: "en"))
        #expect(voices.route(speakerKey: Self.key(calibrated), segmentEngine: .cohere, segmentLanguage: "en", available: Self.downloaded) == nil)
        #expect(voices.route(speakerKey: Self.key(plain), segmentEngine: .apple, segmentLanguage: "en", available: Self.downloaded) == nil)
    }

    @Test("A speaker's own language picks an engine that supports it")
    func routesByLanguage() {
        let tunde = Self.profile("Tunde", language: "yo", engine: .cohere)
        let voices = SessionVoices(profiles: [tunde], contextualStrings: [], sessionSpelling: .unchanged)
        let key = Self.key(tunde)
        #expect(!SpeechModelLibrary.info(.cohere).languageCodes.contains("yo"))
        #expect(
            voices.route(speakerKey: key, segmentEngine: .cohere, segmentLanguage: "en", available: Self.downloaded)
                == EngineRoute(engine: .whisper, languageCode: "yo"))
        #expect(voices.route(speakerKey: key, segmentEngine: .cohere, segmentLanguage: "en", available: [.apple, .cohere]) == nil)

        let marie = Self.profile("Marie", language: "fr")
        let french = SessionVoices(profiles: [marie], contextualStrings: [], sessionSpelling: .unchanged)
        #expect(
            french.route(speakerKey: Self.key(marie), segmentEngine: .cohere, segmentLanguage: "en", available: Self.downloaded)
                == EngineRoute(engine: .cohere, languageCode: "fr"), "the line's own engine first when it speaks the language")
    }

    @Test("Downloaded, loading and ready models are available; Apple always is")
    func availability() {
        let statuses: [SpeechEngineKind: ModelStatus] = [
            .cohere: .loading, .whisper: .downloading(0.4), .apple: .ready,
        ]
        #expect(SessionVoices.availableEngines(statuses) == [.apple, .cohere])
        #expect(SessionVoices.availableEngines([.cohere: .failed("x"), .whisper: .downloaded]) == [.apple, .whisper])
    }

    @Test("Audio is archived only when some enrolled speaker may be re-transcribed")
    func archiveNeed() {
        #expect(!SessionVoices(profiles: [Self.profile("Lee")], contextualStrings: [], sessionSpelling: .unchanged)
            .mayReroute(sessionLanguage: "en"))
        #expect(SessionVoices(profiles: [Self.profile("Lee")], contextualStrings: [], sessionSpelling: .unchanged)
            .mayReroute(sessionLanguage: "fr"))
        #expect(SessionVoices(profiles: [Self.profile("Juma", calibratedBest: .whisper)], contextualStrings: [], sessionSpelling: .unchanged)
            .mayReroute(sessionLanguage: "en"))
    }

    @Test("Locale identifiers map to their language")
    func languageCodes() {
        #expect(SessionVoices.languageCode(ofLocale: "en-GB") == "en")
        #expect(SessionVoices.languageCode(ofLocale: "yo_NG") == "yo")
        #expect(SessionVoices.languageCode(ofLocale: "fr") == "fr")
    }
}
