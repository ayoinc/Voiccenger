import SwiftUI
import VCPipeline

/// SwiftUI's `@State` macro needs a compiler plugin missing from the Command Line Tools; the property wrapper works.
private typealias ViewState = SwiftUI.State

/// An enrolled person: name, voice samples and how Voiccenger transcribes them (Voice & Accent).
/// Edits save automatically shortly after they're made.
struct PersonDetailView: View {
    @Environment(MeetingCoordinator.self) private var coordinator
    let profileID: UUID
    /// What the editor shows, including edits not yet saved.
    @ViewState private var draft: SpeakerProfile?
    /// What was last written to (or read from) the store.
    @ViewState private var saved: SpeakerProfile?

    private var stored: SpeakerProfile? { coordinator.profiles.first { $0.id == profileID } }

    var body: some View {
        Group {
            if let profile = Binding($draft) {
                VoiceAccentForm(profile: profile)
            } else {
                ContentUnavailableView("Person Not Found", systemImage: "person.crop.circle.badge.questionmark",
                                       description: Text("This voice may have been deleted."))
            }
        }
        .navigationTitle(draft?.name ?? "Person")
        .onAppear { adopt(stored) }
        .onChange(of: stored) { _, new in adopt(new) }
        .task(id: draft) {
            guard let draft, draft != saved else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await save(draft)
        }
    }

    /// Takes the stored profile after it changed elsewhere (re-enrollment, calibration), keeping unsaved
    /// voice edits.
    private func adopt(_ new: SpeakerProfile?) {
        guard let new else {
            draft = nil
            saved = nil
            return
        }
        guard new != saved else { return }
        if let draft, let saved, draft != saved {
            var merged = new
            merged.voice = draft.voice
            merged.voice.calibration = new.voice.calibration
            if draft.voice.preferredEngine == saved.voice.preferredEngine {
                merged.voice.preferredEngine = new.voice.preferredEngine
            }
            self.draft = merged
        } else {
            draft = new
        }
        saved = new
    }

    private func save(_ profile: SpeakerProfile) async {
        var clean = profile
        clean.voice.replacements.removeAll { $0.heard.trimmedNonEmpty == nil || $0.meant.trimmedNonEmpty == nil }
        guard clean != saved else { return }
        do {
            try await coordinator.profileStore.upsert(clean)
            saved = clean
            await coordinator.reloadProfiles()
        } catch {
            coordinator.lastError = "\(clean.name)'s settings couldn't be saved: \(error.localizedDescription)"
        }
    }
}

private struct VoiceAccentForm: View {
    @Environment(MeetingCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var settings
    @Environment(EnrollmentService.self) private var enrollment
    @Binding var profile: SpeakerProfile
    @ViewState private var models = ModelStatusTracker()
    @ViewState private var calibrating = false
    @ViewState private var reenrolling = false
    @ViewState private var newTerm = ""
    @ViewState private var showRegionalTerms = false
    @FocusState private var focusedReplacement: UUID?

    var body: some View {
        Form {
            header
            accentSection
            calibrationSection
            transcriptionSection
            vocabularySection
            replacementsSection
        }
        .formStyle(.grouped)
        .task { await models.track() }
        .sheet(isPresented: $calibrating, onDismiss: { enrollment.reset() }) {
            CalibrationSheet(profile: profile)
        }
        .sheet(isPresented: $reenrolling, onDismiss: { enrollment.reset() }) {
            EnrollmentSheet(replacing: profile)
        }
    }

    // MARK: Sections

    private var header: some View {
        Section {
            HStack(spacing: 14) {
                ProfileAvatar(profile: profile, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.title2.bold())
                        .lineLimit(1)
                    Text(samplesDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Re-enroll Voice…") { reenrolling = true }
                    .disabled(coordinator.isRecording || enrollment.isBusy)
                    .help(coordinator.isRecording ? "Stop the recording to re-enroll" : "Record new voice samples for \(profile.name)")
            }
            .padding(.vertical, 4)
        }
    }

    private var accentSection: some View {
        Section {
            RegionPicker(
                title: "Accent background", selection: $profile.voice.accentRegionID,
                help: "Where \(profile.name)'s English (or other language) comes from")
            RegionPicker(
                title: "Lives in", selection: residenceBinding,
                help: "Where \(profile.name) lives now; sets the default spelling")
        } header: {
            Text("Voice & Accent")
        } footer: {
            Text("Voiccenger expects names and places from these regions and uses the voice model that understands this accent best.")
                .settingsFootnote()
        }
    }

    @ViewBuilder
    private var calibrationSection: some View {
        Section {
            if let calibration = profile.voice.calibration {
                LabeledContent("Last calibrated") {
                    Text(calibration.date.formatted(date: .abbreviated, time: .shortened))
                }
                CalibrationResultsView(calibration: calibration)
            } else {
                Label("Not calibrated yet", systemImage: "gauge.with.needle")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(profile.voice.calibration == nil ? "Calibrate…" : "Calibrate Again…") { calibrating = true }
                    .disabled(coordinator.isRecording || enrollment.isBusy)
                    .help(coordinator.isRecording ? "Stop the recording to calibrate" : "Measure which voice model understands \(profile.name) best")
            }
        } header: {
            Text("Calibration")
        } footer: {
            Text("\(profile.name) reads a short passage and every downloaded voice model transcribes it. The model with the fewest word errors is used automatically.")
                .settingsFootnote()
        }
    }

    private var transcriptionSection: some View {
        Section {
            Picker("Voice model", selection: engineBinding) {
                Text(automaticTitle).tag(SpeechEngineKind?.none)
                Divider()
                ForEach(SpeechEngineKind.allCases) { kind in
                    Text(engineTitle(kind)).tag(SpeechEngineKind?.some(kind))
                }
            }
            Picker("Language", selection: $profile.voice.languageCode) {
                if !supportedLanguages.contains(profile.voice.languageCode) {
                    Text("\(Format.languageName(profile.voice.languageCode)) (not supported)")
                        .tag(profile.voice.languageCode)
                }
                if suggestedLanguages.isEmpty {
                    ForEach(otherLanguages, id: \.self) { code in
                        Text(Format.languageName(code)).tag(code)
                    }
                } else {
                    Section("Suggested") {
                        ForEach(suggestedLanguages, id: \.self) { code in
                            Text(Format.languageName(code)).tag(code)
                        }
                    }
                    Section("All Languages") {
                        ForEach(otherLanguages, id: \.self) { code in
                            Text(Format.languageName(code)).tag(code)
                        }
                    }
                }
            }
            Picker("Spelling", selection: $profile.voice.spelling) {
                ForEach(SpellingVariant.allCases, id: \.self) { variant in
                    Text(variant.title).tag(variant)
                }
            }
            if let warning = engineWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.callout)
            }
        } header: {
            Text("Transcription")
        } footer: {
            Text("Languages are those \(effectiveEngine.displayName) understands. Spelling converts between British and American English in \(profile.name)'s lines.")
                .settingsFootnote()
        }
    }

    private var vocabularySection: some View {
        Section {
            if profile.voice.vocabulary.isEmpty {
                Text("No terms yet")
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout {
                    ForEach(profile.voice.vocabulary, id: \.self) { term in
                        TermChip(term: term) { profile.voice.vocabulary.removeAll { $0 == term } }
                    }
                }
                .padding(.vertical, 2)
            }
            HStack {
                TextField("Add terms", text: $newTerm, prompt: Text("Names, places or jargon, separated by commas"))
                    .labelsHidden()
                    .onSubmit(addTerms)
                Button("Add", action: addTerms)
                    .disabled(newTerm.trimmedNonEmpty == nil)
            }
            Toggle(isOn: $profile.voice.useRegionalVocabulary) {
                Text(regionalToggleTitle)
                if !regionalTerms.isEmpty {
                    Text("\(regionalTerms.count) names, cities, institutions and currency terms")
                }
            }
            .disabled(regionNames.isEmpty)
            if profile.voice.useRegionalVocabulary, !regionalTerms.isEmpty {
                DisclosureGroup("Preview", isExpanded: $showRegionalTerms) {
                    FlowLayout(spacing: 4) {
                        ForEach(regionalTerms, id: \.self) { TermChip(term: $0) }
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text("Vocabulary")
        } footer: {
            Text("Terms are written exactly as spelled here, and the voice model is told to expect them.")
                .settingsFootnote()
        }
    }

    private var replacementsSection: some View {
        Section {
            if profile.voice.replacements.isEmpty {
                Text("No replacements")
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("When Voiccenger hears")
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        Text("Write")
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach($profile.voice.replacements) { $replacement in
                        GridRow {
                            TextField("Heard", text: $replacement.heard, prompt: Text("heard"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity)
                                .focused($focusedReplacement, equals: replacement.id)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                            TextField("Write", text: $replacement.meant, prompt: Text("meant"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity)
                            Button {
                                profile.voice.replacements.removeAll { $0.id == replacement.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Remove")
                            .accessibilityLabel("Remove replacement for \(replacement.heard)")
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Add Replacement", systemImage: "plus") {
                    let replacement = TextReplacement(heard: "", meant: "")
                    profile.voice.replacements.append(replacement)
                    focusedReplacement = replacement.id
                }
            }
        } header: {
            Text("Replacements")
        } footer: {
            Text("Fixes words the voice model keeps getting wrong for \(profile.name). Matches whole words, ignoring case; incomplete rows aren't saved.")
                .settingsFootnote()
        }
    }

    // MARK: Engine

    /// nil = Automatic: the calibration's best engine (stored as `preferredEngine`), else the session default.
    private var engineBinding: Binding<SpeechEngineKind?> {
        Binding {
            let preferred = profile.voice.preferredEngine
            return preferred == profile.voice.calibration?.best?.engine ? nil : preferred
        } set: { choice in
            profile.voice.preferredEngine = choice ?? profile.voice.calibration?.best?.engine
        }
    }

    private var effectiveEngine: SpeechEngineKind {
        profile.voice.preferredEngine ?? profile.voice.calibration?.best?.engine ?? settings.speechEngine
    }

    private var automaticTitle: String {
        if let best = profile.voice.calibration?.best?.engine { return "Automatic (\(best.displayName))" }
        return "Automatic (meeting default: \(settings.speechEngine.displayName))"
    }

    private func engineTitle(_ kind: SpeechEngineKind) -> String {
        guard kind != .apple, let status = models.status(kind), !status.isAvailable else { return kind.displayName }
        return "\(kind.displayName) (\(status.label.lowercased()))"
    }

    private var engineWarning: String? {
        let engine = effectiveEngine
        if engine != .apple, let status = models.status(engine), !status.isAvailable {
            return "\(engine.displayName) isn't downloaded, so \(profile.name) is transcribed with the meeting's voice model. Download it in Settings › Voice Models."
        }
        if !supportedLanguages.contains(profile.voice.languageCode) {
            return "\(engine.displayName) doesn't support \(Format.languageName(profile.voice.languageCode)). Choose another language or voice model."
        }
        return nil
    }

    // MARK: Language

    private var supportedLanguages: [String] { effectiveEngine.info.languageCodes }

    /// English plus the local languages of the person's regions that the engine supports.
    private var suggestedLanguages: [String] {
        let regional = [profile.voice.accentRegionID, profile.voice.residenceRegionID]
            .compactMap { $0.flatMap(AccentRegions.region) }
            .flatMap(\.languageCodes)
        var seen = Set<String>()
        let supported = Set(supportedLanguages)
        let suggested = (["en"] + regional).filter { supported.contains($0) && seen.insert($0).inserted }
        return suggested.count > 1 ? suggested : []
    }

    private var otherLanguages: [String] {
        let suggested = Set(suggestedLanguages)
        return supportedLanguages
            .filter { !suggested.contains($0) }
            .sorted { Format.languageName($0).localizedStandardCompare(Format.languageName($1)) == .orderedAscending }
    }

    // MARK: Regions and vocabulary

    /// Setting where the person lives also sets the spelling when it was left unchanged.
    private var residenceBinding: Binding<String?> {
        Binding {
            profile.voice.residenceRegionID
        } set: { id in
            profile.voice.residenceRegionID = id
            if profile.voice.spelling == .unchanged, let region = id.flatMap(AccentRegions.region) {
                profile.voice.spelling = region.defaultSpelling
            }
        }
    }

    private var regionNames: [String] {
        var seen = Set<String>()
        return [profile.voice.accentRegionID, profile.voice.residenceRegionID]
            .compactMap { $0.flatMap(AccentRegions.region) }
            .filter { seen.insert($0.id).inserted }
            .map(\.name)
    }

    /// The regional terms the toggle adds (computed as if it were on, for the preview count).
    private var regionalTerms: [String] {
        var voice = profile.voice
        voice.useRegionalVocabulary = true
        return AccentRegions.vocabulary(for: voice)
    }

    private var regionalToggleTitle: String {
        regionNames.isEmpty
            ? "Include common names and places (set an accent background first)"
            : "Include common names and places from \(Format.list(regionNames))"
    }

    private func addTerms() {
        let terms = newTerm.split(separator: ",").compactMap { String($0).trimmedNonEmpty }
        for term in terms where !profile.voice.vocabulary.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
            profile.voice.vocabulary.append(term)
        }
        newTerm = ""
    }

    private var samplesDescription: String {
        let count = profile.embeddings.count
        return "\(count) voice sample\(count == 1 ? "" : "s") · Enrolled \(profile.createdAt.formatted(date: .abbreviated, time: .omitted))"
    }
}

/// Initials on the person's colour.
struct ProfileAvatar: View {
    let profile: SpeakerProfile
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            Circle().fill(ParticipantPalette.color(profile.colorIndex).gradient)
            Text(initials)
                .font(size > 36 ? .title3.weight(.semibold) : .headline)
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var initials: String {
        let parts = profile.name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}
