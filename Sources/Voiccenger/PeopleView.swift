import SwiftUI
import VCPipeline

/// SwiftUI's `@State` macro needs a compiler plugin missing from the Command Line Tools; the property wrapper works.
private typealias ViewState = SwiftUI.State

struct PeopleView: View {
    @Environment(MeetingCoordinator.self) private var coordinator
    @Environment(EnrollmentService.self) private var enrollment
    /// Present for a new voice (`profile == nil`) or a re-enrollment.
    @ViewState private var enrolling: EnrollmentTarget?
    @ViewState private var pendingDelete: SpeakerProfile?
    @ViewState private var renaming: SpeakerProfile?
    @ViewState private var newName = ""

    var body: some View {
        Group {
            if coordinator.profiles.isEmpty {
                ContentUnavailableView {
                    Label("No Enrolled Voices", systemImage: "person.wave.2")
                } description: {
                    Text("Enroll the people you meet with so their names appear in transcripts instead of “Speaker 1”.")
                } actions: {
                    Button("Enroll a Voice…") { enrolling = EnrollmentTarget(profile: nil) }
                        .buttonStyle(.borderedProminent)
                        .disabled(coordinator.isRecording)
                }
            } else {
                List {
                    Section {
                        ForEach(coordinator.profiles) { profile in
                            ProfileRow(profile: profile)
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
        .sheet(item: $enrolling, onDismiss: { enrollment.reset() }) { target in
            EnrollmentSheet(replacing: target.profile)
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "")'s voice?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { profile in
            Button("Delete Voice", role: .destructive) { Task { await coordinator.deleteProfile(id: profile.id) } }
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
        Button("Rename…") {
            newName = profile.name
            renaming = profile
        }
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
            ZStack {
                Circle().fill(ParticipantPalette.color(profile.colorIndex).gradient)
                Text(initials)
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var initials: String {
        let parts = profile.name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    private var detail: String {
        var parts: [String] = []
        if let locale = profile.preferredLocaleID { parts.append("Accent: \(Format.localeName(locale))") }
        parts.append("\(profile.embeddings.count) voice sample\(profile.embeddings.count == 1 ? "" : "s")")
        parts.append("Enrolled \(profile.createdAt.formatted(date: .abbreviated, time: .omitted))")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Guided enrollment

private struct EnrollmentSheet: View {
    @Environment(MeetingCoordinator.self) private var coordinator
    @Environment(EnrollmentService.self) private var enrollment
    @Environment(\.dismiss) private var dismiss
    let replacing: SpeakerProfile?
    @ViewState private var name = ""
    @ViewState private var task: Task<Void, Never>?

    private static let seconds: TimeInterval = 20

    /// Phonetically varied passage (adapted "Rainbow Passage") so the voice model hears a wide range of sounds.
    private static let passage = """
        When the sunlight strikes raindrops in the air, they act as a prism and form a rainbow. \
        The rainbow is a division of white light into many beautiful colours. These take the shape \
        of a long round arch, with its path high above, and its two ends apparently beyond the horizon. \
        There is, according to legend, a boiling pot of gold at one end. People look, but no one ever finds it. \
        When a man looks for something beyond his reach, his friends say he is looking for the pot of gold \
        at the end of the rainbow.
        """

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(replacing.map { "Re-enroll \($0.name)" } ?? "Enroll a Voice")
                .font(.title2.bold())
            switch enrollment.state {
            case .idle: setup
            case .recording(let progress): recording(progress)
            case .analyzing: analyzing
            case .finished: finished
            case .failed(let message): failed(message)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { name = replacing?.name ?? "" }
        .onDisappear {
            if enrollment.isBusy { Task { await enrollment.stopRecording() } }
        }
        .interactiveDismissDisabled(enrollment.isBusy)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Name", text: $name, prompt: Text("Full name"))
                .textFieldStyle(.roundedBorder)
                .disabled(replacing != nil)
            Text("Ask \(name.trimmedNonEmpty ?? "the person") to read the passage below aloud at a normal pace, close to the microphone, in a quiet room. Recording takes about \(Int(Self.seconds)) seconds.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            passageBox
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Start Recording") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmedNonEmpty == nil)
            }
        }
    }

    private func recording(_ progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            passageBox
            HStack(spacing: 12) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
                    .accessibilityHidden(true)
                LevelMeter(rms: enrollment.inputLevel)
            }
            ProgressView(value: progress) {
                Text("Listening… \(Int((1 - progress) * Self.seconds)) s left")
            }
            .accessibilityValue("\(Int(progress * 100)) percent")
            HStack {
                Spacer()
                Button("Finish Early") { Task { await enrollment.stopRecording() } }
                    .help("Use what has been recorded so far (at least 5 seconds of speech is needed)")
            }
        }
    }

    private var analyzing: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Learning the voice and detecting the accent…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    @ViewBuilder
    private var finished: some View {
        if let outcome = enrollment.lastOutcome {
            VStack(alignment: .leading, spacing: 12) {
                Label("\(outcome.profile.name)'s voice is enrolled.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
                if let best = outcome.accentScores.first {
                    LabeledContent("Detected accent", value: Format.localeName(best.localeID))
                    if outcome.accentScores.count > 1 {
                        GroupBox("Recognition confidence by accent") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(outcome.accentScores.prefix(5), id: \.localeID) { score in
                                    HStack {
                                        Text(Format.localeName(score.localeID))
                                        Spacer()
                                        Gauge(value: max(0, min(1, score.meanConfidence))) { EmptyView() }
                                            .gaugeStyle(.accessoryLinearCapacity)
                                            .frame(width: 140)
                                        Text(score.meanConfidence.formatted(.percent.precision(.fractionLength(0))))
                                            .monospacedDigit()
                                            .frame(width: 44, alignment: .trailing)
                                    }
                                    .accessibilityElement(children: .combine)
                                }
                            }
                            .padding(4)
                        }
                    }
                    Text("Voiccenger will transcribe \(outcome.profile.name) with this accent's recognizer.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The accent couldn't be detected (speech recognition assets may still be downloading).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Enrollment didn't work", systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Try Again") { enrollment.reset() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var passageBox: some View {
        GroupBox {
            ScrollView {
                Text(Self.passage)
                    .font(.title3)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(height: 150)
        }
        .accessibilityLabel("Reading passage")
    }

    private func start() {
        guard let name = name.trimmedNonEmpty else { return }
        let deviceUID = coordinator.settings.inputDeviceUID
        task = Task {
            // Failures are shown through `enrollment.state`.
            _ = try? await enrollment.enroll(name: name, seconds: Self.seconds, deviceUID: deviceUID, replacing: replacing)
            await coordinator.reloadProfiles()
        }
    }
}
