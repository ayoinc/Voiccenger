import Foundation
import Testing
@testable import VCModels

@Suite struct VoiceCodingTests {
    /// A profile's voice settings as saved before Deepgram models could be chosen or compared.
    static let savedBeforeModels = Data(
        """
        {"accentRegionID":"ng","residenceRegionID":"gb","languageCode":"en","spelling":"british",
         "preferredEngine":"deepgram","vocabulary":["Lekki"],"replacements":[],"useRegionalVocabulary":true,
         "calibration":{"date":780000000,"scores":[
           {"engine":"cohere","wordErrorRate":0.04,"transcript":"please call stella"},
           {"engine":"deepgram","wordErrorRate":0.06,"transcript":"please call stellar"}]}}
        """.utf8)

    @Test func decodesSettingsSavedBeforeDeepgramModels() throws {
        let voice = try JSONDecoder().decode(VoiceSettings.self, from: Self.savedBeforeModels)
        #expect(voice.deepgramModel == nil && voice.preferredEngine == .deepgram && voice.vocabulary == ["Lekki"])
        #expect(voice.calibration?.scores.map(\.model) == [nil, nil])
        #expect(voice.calibration?.bestDeepgramModel == nil && voice.effectiveDeepgramModel == nil)
    }

    @Test func roundTripsDeepgramModels() throws {
        let calibration = VoiceCalibration(
            date: Date(timeIntervalSinceReferenceDate: 780_000_000),
            scores: [
                EngineScore(engine: .deepgram, wordErrorRate: 0.02, transcript: "a", model: "nova-2-meeting"),
                EngineScore(engine: .cohere, wordErrorRate: 0.03, transcript: "b"),
                EngineScore(engine: .deepgram, wordErrorRate: 0.05, transcript: "c", model: "nova-3"),
            ])
        let voice = VoiceSettings(preferredEngine: .deepgram, deepgramModel: "whisper-large", calibration: calibration)
        let decoded = try JSONDecoder().decode(VoiceSettings.self, from: JSONEncoder().encode(voice))
        #expect(decoded == voice)
        #expect(decoded.calibration?.bestDeepgramModel == "nova-2-meeting")
        // The person's own choice wins over the calibration's.
        #expect(decoded.effectiveDeepgramModel == "whisper-large")
        var automatic = decoded
        automatic.deepgramModel = nil
        #expect(automatic.effectiveDeepgramModel == "nova-2-meeting")
    }

    @Test func oneDeepgramScoreDoesNotPickAModel() {
        let calibration = VoiceCalibration(scores: [
            EngineScore(engine: .deepgram, wordErrorRate: 0.02, transcript: "a", model: "nova-3"),
            EngineScore(engine: .whisper, wordErrorRate: 0.03, transcript: "b"),
        ])
        #expect(calibration.bestDeepgramModel == nil)
    }
}
