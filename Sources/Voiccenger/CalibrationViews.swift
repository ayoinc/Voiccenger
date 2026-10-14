import SwiftUI
import VCPipeline

/// SwiftUI's `@State` macro needs a compiler plugin missing from the Command Line Tools; the property wrapper works.
private typealias ViewState = SwiftUI.State

// MARK: - Calibrate an enrolled person

/// Guided calibration: the person reads the passage, every downloaded voice model transcribes the recording,
/// and the results (with suggested corrections) are saved to their profile.
struct CalibrationSheet: View {
    @Environment(MeetingCoordinator.self) private var coordinator
    @Environment(EnrollmentService.self) private var enrollment
    @Environment(\.dismiss) private var dismiss
    let profile: SpeakerProfile
    @ViewState private var models = ModelStatusTracker()
    @ViewState private var accepted: Set<UUID> = []
    @ViewState private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Calibrate \(profile.name)")
                .font(.title2.bold())
            switch enrollment.state {
            case .idle: intro
            case .recording(let progress):
                CalibrationRecordingView(passage: passage, progress: progress, seconds: EnrollmentService.defaultRecordingSeconds)
            case .analyzing:
                CalibrationAnalyzingView(message: "Comparing voice models…")
            case .finished: finished
            case .failed(let message):
                CalibrationFailedView(title: "Calibration didn't work", message: message, cancel: { dismiss() }) {
                    enrollment.reset()
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .task { await models.track() }
        .onDisappear {
            if enrollment.isBusy { Task { await enrollment.stopRecording() } }
        }
        .interactiveDismissDisabled(enrollment.isBusy || saving)
    }

    private var passage: String { EnrollmentService.passage(for: profile) }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ask \(profile.name) to read the passage aloud at a normal pace, as they would speak in a meeting. Recording takes about \(Int(EnrollmentService.defaultRecordingSeconds)) seconds; you can finish early once the passage is read.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            CalibrationPassageBox(passage: passage)
            EngineComparisonNote(models: models)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Start Recording", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(coordinator.isRecording)
                    .help(coordinator.isRecording ? "Stop the meeting recording to calibrate" : "Record the reading")
            }
        }
    }

    @ViewBuilder
    private var finished: some View {
        if let outcome = enrollment.lastOutcome {
            VStack(alignment: .leading, spacing: 16) {
                CalibrationOutcomeView(outcome: outcome, accepted: $accepted)
                HStack {
                    Spacer()
                    Button(accepted.isEmpty ? "Done" : "Save Corrections") { save(outcome) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(saving)
                }
            }
            .onAppear { accepted = Set(outcome.suggestedReplacements.map(\.id)) }
        }
    }

    private func start() {
        let deviceUID = coordinator.settings.inputDeviceUID
        Task {
            // Failures are shown through `enrollment.state`.
            _ = try? await enrollment.recalibrate(
                profileID: profile.id, deviceUID: deviceUID,
                deepgramModels: coordinator.settings.calibrationDeepgramModels)
            await coordinator.reloadProfiles()
        }
    }

    private func save(_ outcome: EnrollmentService.Outcome) {
        saving = true
        Task {
            defer { saving = false }
            if await coordinator.saveAcceptedCorrections(outcome, accepted: accepted) { dismiss() }
        }
    }
}

extension MeetingCoordinator {
    /// Adds the accepted suggested corrections to the outcome's profile and saves it. False on failure
    /// (reported through `lastError`).
    func saveAcceptedCorrections(_ outcome: EnrollmentService.Outcome, accepted: Set<UUID>) async -> Bool {
        let chosen = outcome.suggestedReplacements.filter { accepted.contains($0.id) }
        guard !chosen.isEmpty else { return true }
        var profile = profiles.first { $0.id == outcome.profile.id } ?? outcome.profile
        profile.voice.merge(chosen)
        do {
            try await profileStore.upsert(profile)
            await reloadProfiles()
            return true
        } catch {
            lastError = "The corrections couldn't be saved: \(error.localizedDescription)"
            return false
        }
    }
}

// MARK: - Shared steps (enrollment and calibration)

/// The passage to read, large and scrollable.
struct CalibrationPassageBox: View {
    let passage: String

    var body: some View {
        GroupBox {
            ScrollView {
                Text(passage)
                    .font(.title3)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(height: 220)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reading passage")
        .accessibilityValue(passage)
    }
}

struct CalibrationRecordingView: View {
    @Environment(EnrollmentService.self) private var enrollment
    let passage: String
    let progress: Double
    let seconds: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CalibrationPassageBox(passage: passage)
            HStack(spacing: 12) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
                    .accessibilityHidden(true)
                LevelMeter(rms: enrollment.inputLevel)
            }
            ProgressView(value: progress) {
                Text("Listening… \(Int(((1 - progress) * seconds).rounded())) s left")
                    .monospacedDigit()
            }
            .accessibilityValue("\(Int(progress * 100)) percent")
            HStack {
                Spacer()
                Button("Finish Early") { Task { await enrollment.stopRecording() } }
                    .keyboardShortcut(.defaultAction)
                    .help("Use what has been recorded so far (at least 5 seconds of speech is needed)")
            }
        }
    }
}

struct CalibrationAnalyzingView: View {
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(message)
            }
            Text("Each downloaded voice model transcribes the reading. The first run after launch loads the models and can take about a minute.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
    }
}

struct CalibrationFailedView: View {
    let title: String
    let message: String
    let cancel: () -> Void
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Try Again", action: retry)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Which voice models a calibration will compare (with the Deepgram models), and which are missing.
struct EngineComparisonNote: View {
    @Environment(AppSettings.self) private var settings
    let models: ModelStatusTracker

    var body: some View {
        let available = SpeechEngineKind.allCases.filter { ($0 == .apple && AppleSpeech.engineAvailable) || models.isAvailable($0) }
        let missing = SpeechEngineKind.allCases.filter { $0 != .apple && !$0.info.isCloud && !models.isAvailable($0) }
        VStack(alignment: .leading, spacing: 4) {
            Label("Compares \(Format.list(available.map(\.displayName))).", systemImage: "chart.bar.xaxis")
            if !missing.isEmpty {
                Label(
                    "\(Format.list(missing.map(\.displayName))) \(missing.count == 1 ? "isn't" : "aren't") downloaded. Download in Settings › Voice Models to include \(missing.count == 1 ? "it" : "them").",
                    systemImage: "arrow.down.circle"
                )
                .foregroundStyle(.secondary)
            }
            if available.contains(.deepgram) {
                Label(
                    "The reading is also sent to Deepgram, because a Deepgram API key is set up. Deepgram models compared: \(Format.list(settings.calibrationDeepgramModels.map(Deepgram.modelDisplayName))).",
                    systemImage: "icloud.and.arrow.up"
                )
                .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Calibration scores, the engine Voiccenger will use, and suggested corrections with checkboxes.
struct CalibrationOutcomeView: View {
    @Environment(AppSettings.self) private var settings
    let outcome: EnrollmentService.Outcome
    @Binding var accepted: Set<UUID>

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let best = outcome.calibration.best {
                Label {
                    Text("\(best.displayName) understood \(outcome.profile.name) best, with \(Format.wordErrorRate(best.wordErrorRate)) word errors.")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                GroupBox {
                    CalibrationResultsView(calibration: outcome.calibration)
                        .padding(6)
                }
                Text(engineNote(best: best))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("No voice model could transcribe the recording.", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.headline)
                Text("Check the microphone and try again. Download a voice model in Settings › Voice Models if none is downloaded.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !outcome.suggestedReplacements.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Suggested corrections").font(.headline)
                    Text("Words the best model got wrong. Checked corrections are applied to \(outcome.profile.name)'s speech in future meetings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SuggestedCorrectionsView(suggestions: outcome.suggestedReplacements, accepted: $accepted)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func engineNote(best: EngineScore) -> String {
        let voice = outcome.profile.voice
        if let chosen = voice.preferredEngine, chosen != best.engine {
            return "\(outcome.profile.name) stays on \(chosen.displayName), which you chose. Switch the voice model to Automatic in Voice & Accent to use the best one."
        }
        guard best.engine == .deepgram else {
            return "Voiccenger will transcribe \(outcome.profile.name) with \(best.displayName)."
        }
        let model = voice.effectiveDeepgramModel ?? settings.deepgramModel
        return "Voiccenger will transcribe \(outcome.profile.name) with Deepgram \(Deepgram.modelDisplayName(model))."
    }
}
