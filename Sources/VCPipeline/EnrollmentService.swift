import Foundation
import Observation
import VCAudio
import VCModels
import VCSpeakers
import VCTranscription

/// Enrolls a voice: records a few seconds from the microphone, computes speaker embeddings, picks the
/// recognizer locale that best fits the speaker's accent, and saves the profile.
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
        /// Candidate locales ranked best first; empty when accent detection was unavailable.
        public var accentScores: [LocaleScore]
    }

    public enum EnrollmentServiceError: LocalizedError {
        case noAudio
        case busy

        public var errorDescription: String? {
            switch self {
            case .noAudio: "No audio was captured from the microphone."
            case .busy: "An enrollment is already in progress."
            }
        }
    }

    public private(set) var state: State = .idle
    /// Microphone RMS level, 0...1, while recording.
    public private(set) var inputLevel: Double = 0
    public private(set) var lastOutcome: Outcome?

    public let store: SpeakerProfileStore
    @ObservationIgnored private var source: MicrophoneSource?

    public init(store: SpeakerProfileStore) {
        self.store = store
    }

    public var isBusy: Bool {
        switch state {
        case .recording, .analyzing: true
        default: false
        }
    }

    /// Records `seconds` of microphone audio and enrolls it as `name`. Passing `replacing` re-enrolls that
    /// profile (same identity and colour, new voice samples).
    @discardableResult
    public func enroll(
        name: String, seconds: TimeInterval = 20, deviceUID: String? = nil, replacing: SpeakerProfile? = nil
    ) async throws -> Outcome {
        guard !isBusy else { throw EnrollmentServiceError.busy }
        do {
            let samples = try await record(seconds: seconds, deviceUID: deviceUID)
            state = .analyzing
            let outcome = try await Self.enroll(
                name: name, samples16k: samples, store: store, replacing: replacing)
            lastOutcome = outcome
            state = .finished
            return outcome
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
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

    // MARK: - Shared enrollment (app, CLI, in-meeting)

    /// Computes embeddings for `samples16k`, detects the accent, and upserts the profile.
    public nonisolated static func enroll(
        name: String, samples16k: [Float], store: SpeakerProfileStore, replacing: SpeakerProfile? = nil,
        accentCandidates: [String]? = nil
    ) async throws -> Outcome {
        let embeddings = try await SpeakerEnrollment.embeddings(samples16k: samples16k)
        let candidates: [String]
        if let accentCandidates {
            candidates = accentCandidates
        } else {
            candidates = await defaultAccentCandidates()
        }
        let scores = await detectAccent(samples16k: samples16k, candidates: candidates)
        let existing = await store.all()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile: SpeakerProfile
        if var p = replacing {
            p.name = trimmedName.isEmpty ? p.name : trimmedName
            p.embeddings = embeddings
            p.preferredLocaleID = scores.first?.localeID ?? p.preferredLocaleID
            profile = p
        } else {
            profile = SpeakerProfile(
                name: trimmedName.isEmpty ? "Unnamed" : trimmedName, embeddings: embeddings,
                preferredLocaleID: scores.first?.localeID, colorIndex: nextColorIndex(in: existing))
        }
        try await store.upsert(profile)
        return Outcome(profile: profile, accentScores: scores)
    }

    /// Installed English locales plus the user's own locale (accents are told apart within one language;
    /// the user's locale covers non-English speakers).
    public nonisolated static func defaultAccentCandidates(
        userLocaleID: String = AppSettings.systemLocaleID
    ) async -> [String] {
        let installed = await SpeechAssets.installedLocaleIDs()
        let english = installed.filter { $0.lowercased().hasPrefix("en-") || $0.lowercased() == "en" }
        var seen: Set<String> = []
        return ([userLocaleID] + english.sorted()).filter { seen.insert($0).inserted }
    }

    /// Ranked locale scores, or empty when no candidate could be evaluated.
    public nonisolated static func detectAccent(samples16k: [Float], candidates: [String]) async -> [LocaleScore] {
        guard !candidates.isEmpty else { return [] }
        return (try? await AccentDetector().rank(
            samples: samples16k, sampleRate: 16_000, candidateLocaleIDs: candidates)) ?? []
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
