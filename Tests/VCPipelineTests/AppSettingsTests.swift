import Foundation
import Testing
import VCModels
import VCTranscription

@testable import VCPipeline

@MainActor
@Suite("App settings")
struct AppSettingsTests {
    @Test("Voice model, spelling and automatic downloads persist and reach new meetings")
    func voicePreferencesPersist() throws {
        let suite = "vc-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.speechEngine == .cohere)
        #expect(fresh.spelling == .unchanged)
        #expect(fresh.downloadModelsAutomatically)

        fresh.speechEngine = .whisper
        fresh.spelling = .british
        fresh.downloadModelsAutomatically = false

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.speechEngine == .whisper)
        #expect(reloaded.spelling == .british)
        #expect(!reloaded.downloadModelsAutomatically)

        let config = reloaded.sessionConfig(
            kind: .inPerson, detected: nil, meetingsDirectory: FileManager.default.temporaryDirectory)
        #expect(config.speechEngine == .whisper)
        #expect(config.spelling == .british)
    }

    @Test("An unknown stored engine falls back to the default")
    func unknownEngine() throws {
        let suite = "vc-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("parakeet", forKey: "speechEngine")
        #expect(AppSettings(defaults: defaults).speechEngine == .cohere)
    }

    @Test("Computer audio is recorded in person by default; turning it off persists and reaches new meetings")
    func computerAudioInPerson() throws {
        let suite = "vc-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.recordComputerAudioInPerson)
        #expect(fresh.sessionConfig(kind: .inPerson, detected: nil, meetingsDirectory: FileManager.default.temporaryDirectory).recordComputerAudio)

        fresh.recordComputerAudioInPerson = false
        let reloaded = AppSettings(defaults: defaults)
        #expect(!reloaded.recordComputerAudioInPerson)
        #expect(!reloaded.sessionConfig(kind: .inPerson, detected: nil, meetingsDirectory: FileManager.default.temporaryDirectory).recordComputerAudio)
    }

    @Test("Recording waits for consent until acknowledged, and the acknowledgement persists")
    func recordingConsentGate() async throws {
        let suite = "vc-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings(defaults: defaults)
        #expect(!settings.recordingConsentAcknowledged)
        let coordinator = MeetingCoordinator(settings: settings, paths: AppPaths(root: root))

        await coordinator.startRecording(kind: .inPerson)
        #expect(coordinator.session == nil)
        #expect(coordinator.pendingRecording?.kind == .inPerson)

        coordinator.cancelPendingRecording()
        #expect(coordinator.pendingRecording == nil)
        #expect(coordinator.session == nil)

        settings.recordingConsentAcknowledged = true
        #expect(AppSettings(defaults: defaults).recordingConsentAcknowledged)
    }

    @Test("The Deepgram model, calibration extras and fetched model list persist")
    func deepgramModelPreferencesPersist() throws {
        let suite = "vc-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.deepgramModel == "nova-3" && fresh.deepgramModelCatalog == nil)
        #expect(fresh.calibrationDeepgramModels == ["nova-3"])

        let catalog = DeepgramModelCatalog(
            models: [
                DeepgramModel(name: "nova-2-meeting", architecture: "nova-2", version: "2024-02-07.1", streamingLanguages: ["en"], batchLanguages: ["en"])
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_000), source: .project)
        fresh.deepgramModel = "nova-2-meeting"
        // Duplicates of the chosen model are dropped and at most two extras are compared.
        fresh.deepgramCalibrationModels = ["NOVA-2-MEETING", "nova-3", "whisper-large", "enhanced-meeting"]
        fresh.deepgramModelCatalog = catalog

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.deepgramModel == "nova-2-meeting")
        #expect(reloaded.calibrationDeepgramModels == ["nova-2-meeting", "nova-3", "whisper-large"])
        #expect(reloaded.deepgramModelCatalog == catalog)
        #expect(reloaded.sessionConfig(kind: .inPerson, detected: nil, meetingsDirectory: FileManager.default.temporaryDirectory).deepgramModel == "nova-2-meeting")

        reloaded.deepgramModelCatalog = nil
        #expect(AppSettings(defaults: defaults).deepgramModelCatalog == nil)
    }
}
