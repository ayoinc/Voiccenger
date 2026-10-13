import Foundation
import Observation
import VCAudio
import VCModels
import VCSpeakers
import VCTranscription

/// Enrolls a voice: records the person reading the calibration passage, computes speaker embeddings,
/// scores every available voice model on the reading to pick the one that understands them best, and
/// saves the profile.
@MainActor @Observable
public final class EnrollmentService {
    public enum State: Sendable, Hashable {
        case idle
        /// Capturing; `progress` in 0...1.
        case recording(progress: Double)
        case analyzing
        case finished
        case failed(String)
    }

    public struct Outcome: Sendable, Hashable {
        public var profile: SpeakerProfile
        /// Engines ranked by word error rate on the reading, best first; empty when no calibration ran.
        public var calibration: VoiceCalibration
        /// Corrections proposed from what the best engine misheard (names and terms only); not yet saved.
        public var suggestedReplacements: [TextReplacement]

        public init(profile: SpeakerProfile, calibration: VoiceCalibration, suggestedReplacements: [TextReplacement]) {
            self.profile = profile
            self.calibration = calibration
            self.suggestedReplacements = suggestedReplacements
        }
    }

    public enum EnrollmentServiceError: LocalizedError {
        case noAudio
        case busy
        case unknownProfile

        public var errorDescription: String? {
            switch self {
            case .noAudio: "No audio was captured from the microphone."
            case .busy: "An enrollment is already in progress."
            case .unknownProfile: "That voice is no longer enrolled."
            }
        }
    }

    /// Long enough to read `passage(name:region:)` at a relaxed pace; `stopRecording()` ends early.
    public static let defaultRecordingSeconds: TimeInterval = 45

    public private(set) var state: State = .idle
    /// Microphone RMS level, 0...1, while recording.
    public private(set) var inputLevel: Double = 0
    public private(set) var lastOutcome: Outcome?

    public let store: SpeakerProfileStore
    @ObservationIgnored private let library: SpeechModelLibrary
    @ObservationIgnored private var source: MicrophoneSource?

    public init(store: SpeakerProfileStore, library: SpeechModelLibrary = .shared) {
        self.store = store
        self.library = library
    }

    public var isBusy: Bool {
        switch state {
        case .recording, .analyzing: true
        default: false
        }
    }

    /// Records the person reading `passage(name:region:)` and enrolls them as `name`. `voice` seeds a new
    /// profile's settings (its accent region personalises the passage). Passing `replacing` re-enrolls that
    /// profile (same identity, colour and voice settings, new voice samples and calibration).
    @discardableResult
    public func enroll(
        name: String, seconds: TimeInterval = defaultRecordingSeconds, deviceUID: String? = nil,
        replacing: SpeakerProfile? = nil, voice: VoiceSettings? = nil
    ) async throws -> Outcome {
        guard !isBusy else { throw EnrollmentServiceError.busy }
        let settings = replacing?.voice ?? voice ?? .default
        let text = Self.passage(name: name, region: Self.region(of: settings))
        let engines = loadCalibrationEngines()
        return try await run {
            let samples = try await self.record(seconds: seconds, deviceUID: deviceUID)
            self.state = .analyzing
            return try await Self.enroll(
                name: name, samples16k: samples, store: self.store, replacing: replacing, voice: voice,
                calibrationText: text, transcribers: engines.value)
        }
    }

    /// Records the person reading their passage again and re-scores the engines, keeping their voice samples.
    @discardableResult
    public func recalibrate(
        profileID: UUID, seconds: TimeInterval = defaultRecordingSeconds, deviceUID: String? = nil
    ) async throws -> Outcome {
        guard !isBusy else { throw EnrollmentServiceError.busy }
        guard let profile = await store.all().first(where: { $0.id == profileID }) else {
            throw EnrollmentServiceError.unknownProfile
        }
        let engines = loadCalibrationEngines()
        return try await run {
            let samples = try await self.record(seconds: seconds, deviceUID: deviceUID)
            self.state = .analyzing
            return try await Self.recalibrate(
                profileID: profile.id, samples16k: samples, expected: Self.passage(for: profile), store: self.store,
                transcribers: engines.value)
        }
    }

    /// Loads the engines while the person reads, so scoring can start as soon as recording ends.
    private func loadCalibrationEngines() -> Task<[any AccurateTranscriber], Never> {
        let library = self.library
        return Task.detached { await Self.calibrationTranscribers(library: library) }
    }

    /// Stops an in-progress recording early; what was captured so far is used.
    public func stopRecording() async {
        await source?.stop()
    }

    public func reset() {
        guard !isBusy else { return }
        state = .idle
        inputLevel = 0
        lastOutcome = nil
    }

    private func run(_ work: () async throws -> Outcome) async throws -> Outcome {
        do {
            let outcome = try await work()
            lastOutcome = outcome
            state = .finished
            return outcome
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    private func record(seconds: TimeInterval, deviceUID: String?) async throws -> [Float] {
        state = .recording(progress: 0)
        let clock = SessionClock()
        let mic = MicrophoneSource(deviceUID: deviceUID, clock: clock)
        source = mic
        defer { source = nil }
        let stream = try await mic.start()
        var samples: [Float] = []
        var sampleRate = 0.0
        var captured = 0.0
        for await chunk in stream {
            if sampleRate == 0 { sampleRate = chunk.sampleRate }
            guard chunk.sampleRate == sampleRate else { continue }
            samples.append(contentsOf: chunk.samples)
            captured += chunk.duration
            inputLevel = Self.rms(chunk.samples)
            state = .recording(progress: min(1, captured / seconds))
            if captured >= seconds { break }
        }
        await mic.stop()
        inputLevel = 0
        guard sampleRate > 0, !samples.isEmpty else { throw EnrollmentServiceError.noAudio }
        return sampleRate == 16_000 ? samples : AudioResampler.resample(samples, from: sampleRate, to: 16_000)
    }

    // MARK: - Passage

    /// What the person reads: the Speech Accent Archive paragraph, then a sentence with their name and a
    /// place from their region (so names and places are calibrated too).
    public nonisolated static func passage(name: String, region: AccentRegion?) -> String {
        CalibrationPassages.standard + " " + CalibrationPassages.personal(name: name, region: region)
    }

    /// The passage for an enrolled person (accent region, else where they live).
    public nonisolated static func passage(for profile: SpeakerProfile) -> String {
        passage(name: profile.name, region: region(of: profile.voice))
    }

    nonisolated static func region(of voice: VoiceSettings) -> AccentRegion? {
        (voice.accentRegionID ?? voice.residenceRegionID).flatMap(AccentRegions.region)
    }

    // MARK: - Shared enrollment (app, CLI, in-meeting)

    /// Computes embeddings for `samples16k` and upserts the profile. When `calibrationText` is what the
    /// recording says, `transcribers` are scored on it and the result saved as the profile's calibration.
    public nonisolated static func enroll(
        name: String, samples16k: [Float], store: SpeakerProfileStore, replacing: SpeakerProfile? = nil,
        voice: VoiceSettings? = nil, calibrationText: String? = nil, transcribers: [any AccurateTranscriber] = []
    ) async throws -> Outcome {
        let embeddings = try await SpeakerEnrollment.embeddings(samples16k: samples16k)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var profile: SpeakerProfile
        if var p = replacing {
            p.name = trimmedName.isEmpty ? p.name : trimmedName
            p.embeddings = embeddings
            profile = p
        } else {
            profile = SpeakerProfile(
                name: trimmedName.isEmpty ? "Unnamed" : trimmedName, embeddings: embeddings,
                colorIndex: nextColorIndex(in: await store.all()), voice: voice ?? .default)
        }
        var calibration = VoiceCalibration(scores: [])
        var suggestions: [TextReplacement] = []
        if let calibrationText, !transcribers.isEmpty {
            (calibration, suggestions) = await calibrate(
                samples16k: samples16k, expected: calibrationText, transcribers: transcribers,
                vocabulary: calibrationVocabulary(for: profile))
            profile.voice = applying(calibration, to: profile.voice, isNewProfile: replacing == nil)
        }
        try await store.upsert(profile)
        return Outcome(profile: profile, calibration: calibration, suggestedReplacements: suggestions)
    }

    /// Scores `transcribers` on a new reading of `expected` by an enrolled person and saves the calibration;
    /// voice samples and other settings are untouched.
    public nonisolated static func recalibrate(
        profileID: UUID, samples16k: [Float], expected: String, store: SpeakerProfileStore,
        transcribers: [any AccurateTranscriber]
    ) async throws -> Outcome {
        guard let profile = await store.all().first(where: { $0.id == profileID }) else {
            throw EnrollmentServiceError.unknownProfile
        }
        let (calibration, suggestions) = await calibrate(
            samples16k: samples16k, expected: expected, transcribers: transcribers,
            vocabulary: calibrationVocabulary(for: profile))
        // Re-read so settings edited while the engines were transcribing aren't lost.
        guard var latest = await store.all().first(where: { $0.id == profileID }) else {
            throw EnrollmentServiceError.unknownProfile
        }
        latest.voice = applying(calibration, to: latest.voice, isNewProfile: false)
        try await store.upsert(latest)
        return Outcome(profile: latest, calibration: calibration, suggestedReplacements: suggestions)
    }

    /// Engine scores on a reading of `expected` (best first) and corrections proposed from the best
    /// transcript's mistakes on names and terms in `vocabulary`.
    public nonisolated static func calibrate(
        samples16k: [Float], expected: String, transcribers: [any AccurateTranscriber], languageCode: String = "en",
        vocabulary: [String]
    ) async -> (calibration: VoiceCalibration, suggestedReplacements: [TextReplacement]) {
        let calibration = await VoiceCalibrator.calibrate(
            samples16k: samples16k, expected: expected, transcribers: transcribers, languageCode: languageCode)
        guard let best = calibration.best else { return (calibration, []) }
        let suggestions = VoiceCalibrator.suggestedReplacements(
            expected: expected, heard: best.transcript, vocabulary: vocabulary)
        return (calibration, suggestions)
    }

    /// The person's settings after a calibration. Their engine follows the best result when it's new, unset,
    /// or still the previous calibration's pick; a different manual choice is kept. Empty results change nothing.
    public nonisolated static func applying(
        _ calibration: VoiceCalibration, to voice: VoiceSettings, isNewProfile: Bool
    ) -> VoiceSettings {
        guard let best = calibration.best else { return voice }
        var voice = voice
        if isNewProfile || voice.preferredEngine == nil || voice.preferredEngine == voice.calibration?.best?.engine {
            voice.preferredEngine = best.engine
        }
        voice.calibration = calibration
        return voice
    }

    /// Terms whose misrecognitions are worth correcting: the person's name, vocabulary and regional names.
    public nonisolated static func calibrationVocabulary(for profile: SpeakerProfile) -> [String] {
        SessionVoices.unique(
            profile.name.split(separator: " ").map(String.init) + [profile.name] + profile.voice.vocabulary
                + AccentRegions.vocabulary(for: profile.voice))
    }

    /// Apple plus every downloaded voice model that supports `languageCode`, loaded and ready.
    /// Models that fail to load are skipped.
    public nonisolated static func calibrationTranscribers(
        languageCode: String = "en", library: SpeechModelLibrary = .shared
    ) async -> [any AccurateTranscriber] {
        var statuses: [SpeechEngineKind: ModelStatus] = [:]
        for kind in SpeechEngineKind.allCases { statuses[kind] = await library.status(kind) }
        let available = SessionVoices.availableEngines(statuses)
        var transcribers: [any AccurateTranscriber] = []
        for kind in SpeechEngineKind.allCases
        where available.contains(kind) && SpeechModelLibrary.info(kind).languageCodes.contains(languageCode) {
            if let t = try? await library.transcriber(kind) { transcribers.append(t) }
        }
        return transcribers
    }

    /// Smallest colour index not used by any profile.
    public nonisolated static func nextColorIndex(in profiles: [SpeakerProfile]) -> Int {
        let used = Set(profiles.map(\.colorIndex))
        var i = 0
        while used.contains(i) { i += 1 }
        return i
    }

    private nonisolated static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return Double((sum / Float(samples.count)).squareRoot())
    }
}
