import Foundation
import Testing
import VCModels

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
}
