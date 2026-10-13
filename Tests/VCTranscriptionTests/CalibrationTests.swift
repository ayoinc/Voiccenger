import Foundation
import Testing
import VCModels
@testable import VCTranscription

@Suite struct AccentRegionTests {
    static let required = """
        ng gh ke ug tz za zw zm cm sl lr et so rw mw bw na gm sn ci cd er sd ss ls sz mu eg ma dz tn jm tt bb gb us \
        ca ie au nz in pk bd lk ph sg my cn hk jp kr vn de fr nl es it pt br mx pl ae sa
        """.split(separator: " ").map(String.init)

    @Test func everyRequiredRegionExistsOnce() {
        let ids = AccentRegions.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(Set(Self.required).isSubset(of: Set(ids)))
        #expect(AccentRegions.region("NG")?.name == "Nigeria")
        #expect(AccentRegions.region("zz") == nil)
    }

    @Test func africaComesFirst() {
        let firstNonAfrican = AccentRegions.all.firstIndex { $0.continent != "Africa" } ?? AccentRegions.all.count
        #expect(AccentRegions.all[..<firstNonAfrican].count >= 31)
        #expect(AccentRegions.all[firstNonAfrican...].allSatisfy { $0.continent != "Africa" })
        #expect(Set(AccentRegions.all.map(\.continent)).isSubset(of: Set(AccentRegions.continentOrder)))
    }

    @Test func africanRegionsHaveSubstantialDistinctVocabulary() {
        for region in AccentRegions.all where region.continent == "Africa" {
            #expect((30...80).contains(region.vocabulary.count), "\(region.id): \(region.vocabulary.count)")
        }
        for region in AccentRegions.all {
            let keys = region.vocabulary.map { $0.lowercased() }
            #expect(Set(keys).count == keys.count, "\(region.id) has duplicates")
            #expect(!region.places.isEmpty, "\(region.id) has no places")
            #expect(Set(region.places).isSubset(of: Set(region.vocabulary)), "\(region.id) places outside vocabulary")
            #expect(region.vocabulary.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        }
    }

    @Test func languagesAreOnesWhisperTranscribes() {
        let whisper = Set(SpeechModelLibrary.info(.whisper).languageCodes)
        for region in AccentRegions.all {
            #expect(!region.languageCodes.isEmpty, "\(region.id)")
            #expect(Set(region.languageCodes).isSubset(of: whisper), "\(region.id): \(region.languageCodes)")
        }
        // Igbo, Zulu and Twi are not Whisper languages.
        #expect(!AccentRegions.all.flatMap(\.languageCodes).contains { ["ig", "zu", "tw", "xh", "wo"].contains($0) })
    }

    @Test func regionalVocabularyCombinesAccentAndResidence() throws {
        let ng = try #require(AccentRegions.region("ng"))
        let gb = try #require(AccentRegions.region("gb"))
        let settings = VoiceSettings(accentRegionID: "ng", residenceRegionID: "gb")
        let terms = AccentRegions.vocabulary(for: settings)
        #expect(Array(terms.prefix(ng.vocabulary.count)) == ng.vocabulary)
        #expect(Set(gb.vocabulary).isSubset(of: Set(terms)))
        #expect(Set(terms.map { $0.lowercased() }).count == terms.count)
        var off = settings
        off.useRegionalVocabulary = false
        #expect(AccentRegions.vocabulary(for: off).isEmpty)
    }
}

/// Transcriber returning fixed text, or failing.
private struct ScriptedTranscriber: AccurateTranscriber {
    let kind: SpeechEngineKind
    let text: String?

    func transcribe(samples16k: [Float], languageCode: String, prompt: [String]) async throws -> EngineTranscript {
        guard let text else { throw TranscriptionError.modelNotDownloaded(kind) }
        return EngineTranscript(text: text, words: nil, engine: kind, languageCode: languageCode)
    }
}

@Suite struct CalibrationTests {
    @Test func standardPassageIsTheAccentArchiveParagraph() {
        #expect(CalibrationPassages.standard.hasPrefix("Please call Stella."))
        #expect(CalibrationPassages.standard.hasSuffix("Wednesday at the train station."))
        #expect(WordErrorRate.normalize(CalibrationPassages.standard).count == 69)
    }

    @Test func personalSentenceNamesThePersonAndRegionalPlaces() throws {
        let ng = try #require(AccentRegions.region("ng"))
        let sentence = CalibrationPassages.personal(name: "  Ayodele  Ajayi ", region: ng)
        #expect(sentence.contains("Ayodele Ajayi"))
        #expect(sentence.contains(ng.places[0]) && sentence.contains(ng.places[1]))
        let plain = CalibrationPassages.personal(name: "", region: nil)
        #expect(!plain.contains("My name is"))
        #expect(plain.hasSuffix("."))
    }

    @Test func ranksBestFirstAndSkipsFailingEngines() async {
        let expected = "Please call Stella. Ask her to bring these things with her from the store."
        let calibration = await VoiceCalibrator.calibrate(
            samples16k: [0], expected: expected,
            transcribers: [
                ScriptedTranscriber(kind: .apple, text: "Please call Stellar ask her to bring these thing with her from the stall"),
                ScriptedTranscriber(kind: .whisper, text: nil),
                ScriptedTranscriber(kind: .cohere, text: "Please call Stella. Ask her to bring these things with her from the store."),
            ],
            languageCode: "en")
        #expect(calibration.scores.map(\.engine) == [.cohere, .apple])
        #expect(calibration.best?.wordErrorRate == 0)
        #expect(calibration.scores[1].wordErrorRate > 0.1)
    }

    @Test func tiesKeepTheGivenOrder() async {
        let calibration = await VoiceCalibrator.calibrate(
            samples16k: [0], expected: "hello there",
            transcribers: [
                ScriptedTranscriber(kind: .whisper, text: "hello their"),
                ScriptedTranscriber(kind: .cohere, text: "hello there"),
                ScriptedTranscriber(kind: .apple, text: "yellow there"),
            ],
            languageCode: "en")
        #expect(calibration.scores.map(\.engine) == [.cohere, .whisper, .apple])
    }

    @Test func libraryCalibrationSkipsEnginesThatAreNotDownloaded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let calibration = await VoiceCalibrator.calibrate(
            samples16k: [Float](repeating: 0, count: 1_600), expected: "anything", engines: [.cohere, .whisper],
            languageCode: "en", library: SpeechModelLibrary(root: root))
        #expect(calibration.scores.isEmpty)
    }

    @Test func suggestsCorrectionsForMisheardNamesOnly() {
        let suggestions = VoiceCalibrator.suggestedReplacements(
            expected: "Please call Stella. My name is Ngozi Okafor, and I know Lagos well. Five thick slabs.",
            heard: "Please call Stellar. My name is and goes he Okafor, and I know Lagos well. Five thick slaps.",
            vocabulary: ["Lagos"])
        let pairs = Set(suggestions.map { "\($0.heard)→\($0.meant)" })
        #expect(pairs == ["Stellar→Stella", "and goes he→Ngozi"])
    }

    @Test func noSuggestionsWhenTranscriptIsRight() {
        let text = "My name is Kwame and I live in Kumasi."
        #expect(VoiceCalibrator.suggestedReplacements(expected: text, heard: text.lowercased(), vocabulary: []).isEmpty)
    }
}
