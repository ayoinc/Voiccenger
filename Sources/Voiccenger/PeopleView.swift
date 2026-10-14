import SwiftUI
import VCPipeline

/// SwiftUI's `@State` macro needs a compiler plugin missing from the Command Line Tools; the property wrapper works.
private typealias ViewState = SwiftUI.State

struct PeopleView: View {
    @Environment(MeetingCoordinator.self) private var coordinator
    @Environment(EnrollmentService.self) private var enrollment
    /// Present for a new voice (`profile == nil`) or a re-enrollment.
    @ViewState private var enrolling: EnrollmentTarget?
    @ViewState private var calibrating: SpeakerProfile?
    @ViewState private var pendingDelete: SpeakerProfile?
    @ViewState private var renaming: SpeakerProfile?
    @ViewState private var newName = ""
    @ViewState private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if coordinator.profiles.isEmpty {
                    ContentUnavailableView {
                        Label("No Enrolled Voices", systemImage: "person.wave.2")
                    } description: {
                        Text("Enroll the people you meet with so their names appear in transcripts instead of “Speaker 1”, and so Voiccenger can learn their accent.")
                    } actions: {
                        Button("Enroll a Voice…") { enrolling = EnrollmentTarget(profile: nil) }
                            .buttonStyle(.borderedProminent)
                            .disabled(coordinator.isRecording)
                    }
                } else {
                    List {
                        Section {
                            ForEach(coordinator.profiles) { profile in
                                NavigationLink(value: profile.id) {
                                    ProfileRow(profile: profile)
                                }
                                .contextMenu { menu(for: profile) }
                            }
                        } footer: {
                            Text("Voices are stored on this Mac only.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("People")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        enrolling = EnrollmentTarget(profile: nil)
                    } label: {
                        Label("Enroll Voice", systemImage: "plus")
                    }
                    .help(coordinator.isRecording ? "Stop the recording to enroll a voice" : "Enroll a new voice")
                    .disabled(coordinator.isRecording)
                }
            }
            .navigationDestination(for: UUID.self) { id in
                PersonDetailView(profileID: id)
            }
        }
        .sheet(item: $enrolling, onDismiss: { enrollment.reset() }) { target in
            EnrollmentSheet(replacing: target.profile)
        }
        .sheet(item: $calibrating, onDismiss: { enrollment.reset() }) { profile in
            CalibrationSheet(profile: profile)
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "")'s voice?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { profile in
            Button("Delete Voice", role: .destructive) {
                path.removeAll { $0 == profile.id }
                Task { await coordinator.deleteProfile(id: profile.id) }
            }
        } message: { _ in
            Text("Future meetings won't recognise this person. Past transcripts keep their name.")
        }
        .alert("Rename Person", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if var profile = renaming, let name = newName.trimmedNonEmpty {
                    profile.name = name
                    Task { await save(profile) }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    @ViewBuilder
    private func menu(for profile: SpeakerProfile) -> some View {
        Button("Voice & Accent…") { path = [profile.id] }
        Button("Rename…") {
            newName = profile.name
            renaming = profile
        }
        Divider()
        Button("Calibrate…") { calibrating = profile }
            .disabled(coordinator.isRecording)
        Button("Re-enroll Voice…") { enrolling = EnrollmentTarget(profile: profile) }
            .disabled(coordinator.isRecording)
        Divider()
        Button("Delete…", role: .destructive) { pendingDelete = profile }
    }

    private func save(_ profile: SpeakerProfile) async {
        do {
            try await coordinator.profileStore.upsert(profile)
            await coordinator.reloadProfiles()
        } catch {
            coordinator.lastError = "The change couldn't be saved: \(error.localizedDescription)"
        }
    }
}

private struct EnrollmentTarget: Identifiable {
    let id = UUID()
    let profile: SpeakerProfile?
}

private struct ProfileRow: View {
    let profile: SpeakerProfile

    var body: some View {
        HStack(spacing: 12) {
            ProfileAvatar(profile: profile)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts: [String] = []
        if let region = profile.voice.accentRegionID.flatMap(AccentRegions.region) { parts.append(region.englishName) }
        if let engine = profile.voice.preferredEngine ?? profile.voice.calibration?.best?.engine {
            parts.append(engine.displayName)
        }
        parts.append("\(profile.embeddings.count) voice sample\(profile.embeddings.count == 1 ? "" : "s")")
        parts.append("Enrolled \(profile.createdAt.formatted(date: .abbreviated, time: .omitted))")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Guided enrollment

/// Records the person reading the calibration passage, learns their voice and measures which voice model
/// understands them best.
struct EnrollmentSheet: View {
    @Environment(MeetingCoordinator.self) private var coordinator
    @Environment(EnrollmentService.self) private var enrollment
    @Environment(\.dismiss) private var dismiss
    let replacing: SpeakerProfile?
    @ViewState private var name = ""
    @ViewState private var accentRegionID: String?
    @ViewState private var models = ModelStatusTracker()
    @ViewState private var accepted: Set<UUID> = []
    @ViewState private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(replacing.map { "Re-enroll \($0.name)" } ?? "Enroll a Voice")
                .font(.title2.bold())
            switch enrollment.state {
            case .idle: setup
            case .recording(let progress):
                CalibrationRecordingView(passage: passage, progress: progress, seconds: EnrollmentService.defaultRecordingSeconds)
            case .analyzing:
                CalibrationAnalyzingView(message: "Learning the voice and comparing voice models…")
            case .finished: finished
            case .failed(let message):
                CalibrationFailedView(title: "Enrollment didn't work", message: message, cancel: { dismiss() }) {
                    enrollment.reset()
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .task { await models.track() }
        .onAppear {
            name = replacing?.name ?? ""
            accentRegionID = replacing?.voice.accentRegionID
        }
        .onDisappear {
            if enrollment.isBusy { Task { await enrollment.stopRecording() } }
        }
        .interactiveDismissDisabled(enrollment.isBusy || saving)
    }

    private var passage: String {
        if let replacing { return EnrollmentService.passage(for: replacing) }
        guard let name = name.trimmedNonEmpty else { return CalibrationPassages.standard }
        return EnrollmentService.passage(name: name, region: accentRegionID.flatMap(AccentRegions.region))
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 16) {
            if replacing == nil {
                Form {
                    TextField("Name", text: $name, prompt: Text("Full name"))
                    RegionPicker(
                        title: "Accent background", selection: $accentRegionID,
                        help: "Where the person's English comes from; adds a local place to the passage")
                }
                .formStyle(.columns)
            }
            Text("Ask \(name.trimmedNonEmpty ?? "the person") to read the passage below aloud at a normal pace, close to the microphone, in a quiet room. Recording takes about \(Int(EnrollmentService.defaultRecordingSeconds)) seconds; you can finish early once it's read.")
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
                    .disabled(name.trimmedNonEmpty == nil || coordinator.isRecording)
            }
        }
    }

    @ViewBuilder
    private var finished: some View {
        if let outcome = enrollment.lastOutcome {
            VStack(alignment: .leading, spacing: 16) {
                Label("\(outcome.profile.name)'s voice is enrolled.", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.headline)
                CalibrationOutcomeView(outcome: outcome, accepted: $accepted)
                Text("Set where \(outcome.profile.name) lives, their language, vocabulary and replacements in People › \(outcome.profile.name).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        guard let name = name.trimmedNonEmpty else { return }
        let deviceUID = coordinator.settings.inputDeviceUID
        let voice = replacing == nil ? VoiceSettings(accentRegionID: accentRegionID) : nil
        Task {
            // Failures are shown through `enrollment.state`.
            _ = try? await enrollment.enroll(
                name: name, deviceUID: deviceUID, replacing: replacing, voice: voice,
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
