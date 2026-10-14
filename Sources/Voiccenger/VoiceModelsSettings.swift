import SwiftUI
import VCPipeline

/// SwiftUI's `@State` macro needs a compiler plugin missing from the Command Line Tools; the property wrapper works.
private typealias ViewState = SwiftUI.State

/// Settings › Voice Models: download, warm up and delete speech engines, and pick the default.
struct VoiceModelsSettings: View {
    @Environment(AppSettings.self) private var settings
    @ViewState private var models = ModelStatusTracker()
    @ViewState private var errors: [SpeechEngineKind: String] = [:]
    @ViewState private var pendingDelete: SpeechModelInfo?
    @ViewState private var showBenchmark = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Transcribe meetings with", selection: $settings.speechEngine) {
                    ForEach(SpeechModelLibrary.allInfo) { info in
                        let reason = EngineSupport.unsupportedReason(info.kind)
                        Text(reason.map { "\(info.displayName) — \($0)" } ?? info.displayName)
                            .tag(info.kind)
                            .disabled(reason != nil)
                    }
                }
                Toggle("Download models automatically", isOn: $settings.downloadModelsAutomatically)
            } footer: {
                Text(AppleSpeech.isAvailable
                    ? "Apple Speech shows words instantly while someone talks; each finished sentence is then rewritten by the selected model. Deepgram instead streams live text itself. People you've calibrated use the model that understood them best."
                    : "The selected model shows live text every couple of seconds while someone talks, then rewrites each finished passage. Deepgram instead streams live text itself. Apple Speech's instant preview needs macOS 26. People you've calibrated use the model that understood them best.")
                    .settingsFootnote()
            }
            Section("Models") {
                ForEach(SpeechModelLibrary.allInfo) { info in
                    ModelRow(
                        info: info, status: models.status(info.kind), isDefault: settings.speechEngine == info.kind,
                        unsupportedReason: EngineSupport.unsupportedReason(info.kind), error: errors[info.kind],
                        download: { run(info.kind) { try await SpeechModelLibrary.shared.download(info.kind) } },
                        prewarm: { run(info.kind) { try await SpeechModelLibrary.shared.prewarm(info.kind) } },
                        delete: { pendingDelete = info })
                }
            }
            DeepgramKeySection(status: models.status(.deepgram))
            DeepgramModelSection(status: models.status(.deepgram))
            Section {
                DisclosureGroup("How we chose", isExpanded: $showBenchmark) {
                    BenchmarkTable()
                        .padding(.vertical, 6)
                }
            } footer: {
                Text("\(AppleSpeech.isAvailable ? "Cohere, Whisper and Apple Speech run" : "Cohere and Whisper run") on this Mac; their audio never leaves it. Files are stored in Application Support › Voiccenger › Models. Deepgram is the exception: audio is sent to Deepgram.")
                    .settingsFootnote()
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 620)
        .task { await models.track() }
        .task {
            // Check a Deepgram key found at launch (free) so its row says whether it works.
            if await SpeechModelLibrary.shared.status(.deepgram) == .downloaded {
                try? await SpeechModelLibrary.shared.prewarm(.deepgram)
            }
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.displayName ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { info in
            Button("Delete Model", role: .destructive) { delete(info.kind) }
        } message: { info in
            Text("Frees \(Format.bytes(info.downloadBytes)). \(AppleSpeech.isAvailable ? "Meetings fall back to Apple Speech for anyone using it until it's downloaded again." : "Meetings use another downloaded model for anyone using it until it's downloaded again.")")
        }
    }

    private func run(_ kind: SpeechEngineKind, _ operation: @escaping @MainActor () async throws -> Void) {
        errors[kind] = nil
        Task {
            do {
                try await operation()
            } catch is CancellationError {
            } catch {
                errors[kind] = error.localizedDescription
            }
        }
    }

    private func delete(_ kind: SpeechEngineKind) {
        errors[kind] = nil
        Task {
            do {
                try await SpeechModelLibrary.shared.delete(kind)
            } catch {
                errors[kind] = "The model couldn't be deleted: \(error.localizedDescription)"
            }
        }
    }
}

private struct ModelRow: View {
    let info: SpeechModelInfo
    let status: ModelStatus?
    let isDefault: Bool
    /// Why the model can't run on this Mac ("Needs macOS 26"); nil when it can.
    let unsupportedReason: String?
    let error: String?
    let download: () -> Void
    let prewarm: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(info.displayName).font(.headline)
                    if isDefault {
                        Text("Default")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(Capsule().strokeBorder(.tertiary))
                    }
                }
                Text(info.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(facts)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = error ?? (unsupportedReason == nil ? failureMessage : nil) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
                .frame(minWidth: 96, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(info.displayName)
    }

    private var symbol: String {
        switch info.kind {
        case .apple: "apple.logo"
        case .cohere: "waveform.badge.magnifyingglass"
        case .whisper: "waveform"
        case .deepgram: "icloud"
        }
    }

    private var facts: String {
        var parts: [String] = []
        if info.isCloud {
            parts.append("Cloud · your API key")
        } else if info.downloadBytes > 0 {
            parts.append(Format.bytes(info.downloadBytes))
        } else {
            parts.append("Built in")
        }
        parts.append("\(info.languageCodes.count) language\(info.languageCodes.count == 1 ? "" : "s")")
        if let wer = info.africanWordErrorRate { parts.append("\(Format.wordErrorRate(wer)) word errors on African accents") }
        return parts.joined(separator: " · ")
    }

    private var failureMessage: String? {
        if case .failed(let message) = status { return message }
        return nil
    }

    @ViewBuilder
    private var control: some View {
        if let unsupportedReason {
            Text(unsupportedReason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        } else if info.isCloud {
            cloudControl
        } else {
            localControl
        }
    }

    /// Deepgram: nothing to download; the key is checked with Deepgram.
    @ViewBuilder
    private var cloudControl: some View {
        switch status {
        case nil:
            ProgressView().controlSize(.small)
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking key").foregroundStyle(.secondary)
            }
            .font(.callout)
        case .ready:
            Label("Key valid", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .failed:
            Button("Retry", action: prewarm)
        case .downloaded, .notDownloaded, .downloading:
            Button("Check Key", action: prewarm)
                .help("Ask Deepgram whether the API key works")
        }
    }

    @ViewBuilder
    private var localControl: some View {
        switch status {
        case nil:
            ProgressView().controlSize(.small)
        case .notDownloaded:
            Button("Download", action: download)
                .help("Download \(info.displayName) (\(Format.bytes(info.downloadBytes)))")
        case .downloading(let fraction):
            VStack(alignment: .trailing, spacing: 2) {
                ProgressView(value: fraction)
                    .frame(width: 96)
                Text(Format.percent(fraction))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Downloading")
            .accessibilityValue(Format.percent(fraction))
        case .downloaded:
            HStack(spacing: 6) {
                Button("Warm Up", action: prewarm)
                    .help("Load the model now so the next meeting doesn't wait for it")
                deleteMenu
            }
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Warming up").foregroundStyle(.secondary)
            }
            .font(.callout)
        case .ready:
            HStack(spacing: 6) {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
                if info.kind != .apple { deleteMenu }
            }
        case .failed:
            Button("Retry", action: info.kind == .apple ? prewarm : download)
        }
    }

    private var deleteMenu: some View {
        Menu {
            Button("Delete…", role: .destructive, action: delete)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More actions for \(info.displayName)")
    }
}

/// The user's Deepgram API key: saved in the Keychain, removable, with whether Deepgram accepts it.
private struct DeepgramKeySection: View {
    @Environment(AppSettings.self) private var settings
    let status: ModelStatus?
    @ViewState private var apiKey = ""
    @ViewState private var source: Deepgram.KeySource?
    @ViewState private var keyError: String?

    var body: some View {
        Section {
            Label("Audio is sent to Deepgram for transcription", systemImage: "icloud.and.arrow.up")
                .foregroundStyle(.orange)
            SecureField(
                "API key", text: $apiKey, prompt: Text(source == .keychain ? "Saved in Keychain" : "Deepgram API key"))
                .onSubmit(save)
            HStack {
                statusLabel
                Spacer()
                if source == .keychain {
                    Button("Remove Key", role: .destructive) { store(nil) }
                }
                Button("Save Key", action: save)
                    .disabled(apiKey.trimmedNonEmpty == nil)
            }
            if let keyError {
                Text(keyError).font(.callout).foregroundStyle(.red)
            }
            Link("Get a key at console.deepgram.com", destination: Deepgram.consoleURL)
        } header: {
            Text("Deepgram")
        } footer: {
            Text("Only used when Deepgram is the meeting's model or someone's voice model. The key is stored in your Keychain and sent only to Deepgram. Audio is sent with Deepgram's model-improvement opt-out, so it isn't used to train their models.")
                .settingsFootnote()
        }
        .onAppear(perform: refresh)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .ready:
            Label("Valid", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .loading:
            Label("Checking…", systemImage: "clock").foregroundStyle(.secondary)
        case .failed(let message) where message == DeepgramError.invalidKey.statusMessage:
            Label("Invalid key", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        case .failed(let message) where message == DeepgramError.unreachable("").statusMessage:
            Label("Offline", systemImage: "wifi.slash").foregroundStyle(.orange)
        case .failed(let message) where message != DeepgramError.missingKey.statusMessage:
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        default:
            switch source {
            case .environment: Label("Using DEEPGRAM_API_KEY", systemImage: "key").foregroundStyle(.secondary)
            case .file: Label("Using ~/.deepgram_secret", systemImage: "key").foregroundStyle(.secondary)
            case .keychain: Label("Not checked yet", systemImage: "key").foregroundStyle(.secondary)
            case nil: Label("No key", systemImage: "key").foregroundStyle(.secondary)
            }
        }
    }

    private func refresh() {
        source = Deepgram.resolveKey()?.source
    }

    private func save() {
        guard let key = apiKey.trimmedNonEmpty else { return }
        store(key)
    }

    /// Saves (or with nil removes) the key, then has Deepgram check whichever key now applies.
    private func store(_ key: String?) {
        do {
            try KeychainStore.set(key, account: Deepgram.keychainAccount)
            keyError = nil
            apiKey = ""
        } catch {
            keyError = "The key couldn't be saved: \(error.localizedDescription)"
        }
        refresh()
        // The models belong to the old key; they're fetched again once the new one is accepted.
        settings.deepgramModelCatalog = nil
        Task {
            await SpeechModelLibrary.shared.deepgramKeyChanged()
            guard Deepgram.resolveKey() != nil else { return }
            try? await SpeechModelLibrary.shared.prewarm(.deepgram)
        }
    }
}

/// Which Deepgram model transcribes: the models the key can use (fetched from Deepgram once the key is
/// accepted), the languages each understands, and which can't stream live.
private struct DeepgramModelSection: View {
    @Environment(AppSettings.self) private var settings
    let status: ModelStatus?
    @ViewState private var fetching = false
    @ViewState private var fetchError: String?
    @ViewState private var showLanguages = false

    var body: some View {
        if settings.deepgramModelCatalog != nil || status == .ready || fetching {
            Section {
                if let catalog = settings.deepgramModelCatalog {
                    picker(catalog)
                    if let model = catalog.model(named: settings.deepgramModel) {
                        details(model)
                    } else {
                        Label(
                            "\(Deepgram.modelDisplayName(settings.deepgramModel)) isn't available to this key, so Nova-3 is used.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .symbolRenderingMode(.multicolor)
                    }
                    calibrationMenu(catalog)
                } else {
                    LabeledContent("Model", value: "Nova-3")
                }
                HStack {
                    fetchedLabel
                    Spacer()
                    if fetching { ProgressView().controlSize(.small) }
                    Button(settings.deepgramModelCatalog == nil ? "Fetch Models" : "Refresh") { fetch(refresh: true) }
                        .disabled(fetching)
                        .help("Ask Deepgram which models your key can use")
                }
                if let fetchError {
                    Text(fetchError).font(.callout).foregroundStyle(.red)
                }
            } header: {
                Text("Deepgram Model")
            } footer: {
                Text("Used when Deepgram transcribes a meeting or file, and for people without a Deepgram model of their own (set in Voice & Accent). A model that can't stream the meeting's language live is used for recordings, calibration and re-transcribed lines; meetings then stream with Nova-3.")
                    .settingsFootnote()
            }
            .task(id: status) {
                if status == .ready, settings.deepgramModelCatalog == nil, !fetching { fetch(refresh: false) }
            }
        }
    }

    private var meetingLanguage: String { SessionVoices.languageCode(ofLocale: settings.localeID) }

    private func picker(_ catalog: DeepgramModelCatalog) -> some View {
        let selection = Binding {
            catalog.model(named: settings.deepgramModel)?.name ?? settings.deepgramModel
        } set: { name in
            settings.deepgramModel = Deepgram.isDefaultModel(name) ? Deepgram.defaultModel : name
        }
        let families = Dictionary(grouping: catalog.models, by: \.family)
        return Picker("Model", selection: selection) {
            if catalog.model(named: settings.deepgramModel) == nil {
                Text("\(Deepgram.modelDisplayName(settings.deepgramModel)) (not available)").tag(settings.deepgramModel)
            }
            ForEach(DeepgramModel.families.filter { families[$0] != nil }, id: \.self) { family in
                Section(family) {
                    ForEach(families[family] ?? []) { model in
                        Text(model.canStream ? model.displayName : "\(model.displayName) (recordings only)").tag(model.name)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func details(_ model: DeepgramModel) -> some View {
        LabeledContent("Version") {
            Text("\(model.architecture) · \(model.version)")
        }
        if !model.canStream {
            Label(
                "\(model.displayName) only transcribes recordings: meetings stream with Nova-3 and it's used for files, calibration and re-transcribed lines.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .symbolRenderingMode(.multicolor)
        } else if !model.transcribes(meetingLanguage) {
            Label(
                "\(model.displayName) doesn't transcribe \(Format.languageName(meetingLanguage)), the meeting language, so Nova-3 is used.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .symbolRenderingMode(.multicolor)
        } else if !model.transcribes(meetingLanguage, live: true) {
            Label(
                "\(model.displayName) can't stream \(Format.languageName(meetingLanguage)) live: meetings stream with Nova-3, and it transcribes recordings.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .symbolRenderingMode(.multicolor)
        }
        DisclosureGroup(languagesTitle(model), isExpanded: $showLanguages) {
            Text(languageList(model))
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func languagesTitle(_ model: DeepgramModel) -> String {
        let all = model.languageCodes.count
        let live = model.streamingLanguageCodes.count
        return live == all ? "\(all) language\(all == 1 ? "" : "s"), all live" : "\(all) language\(all == 1 ? "" : "s"), \(live) live"
    }

    /// "English, French (recordings only), …" alphabetically.
    private func languageList(_ model: DeepgramModel) -> String {
        let live = Set(model.streamingLanguageCodes)
        return model.languageCodes
            .map { (code: $0, name: Deepgram.languageDisplayName($0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { live.contains($0.code) ? $0.name : "\($0.name) (recordings only)" }
            .joined(separator: ", ")
    }

    /// Up to two more models compared when someone calibrates (English recordings).
    private func calibrationMenu(_ catalog: DeepgramModelCatalog) -> some View {
        let extras = settings.deepgramCalibrationModels
        let candidates = catalog.models(transcribing: "en", live: false)
            .filter { !Deepgram.sameModel($0.name, settings.deepgramModel) }
        let ticked = candidates.filter { model in extras.contains { Deepgram.sameModel($0, model.name) } }
        return LabeledContent("Also compare when calibrating") {
            Menu(ticked.isEmpty ? "None" : Format.list(ticked.map(\.displayName))) {
                ForEach(candidates) { model in
                    let isOn = ticked.contains(model)
                    Toggle(
                        model.displayName,
                        isOn: Binding {
                            isOn
                        } set: { on in
                            var next = ticked.map(\.name)
                            if on { next.append(model.name) } else { next.removeAll { $0 == model.name } }
                            settings.deepgramCalibrationModels = next
                        }
                    )
                    .disabled(!isOn && ticked.count >= AppSettings.maximumExtraCalibrationModels)
                }
            }
            .fixedSize()
            .help("Calibration also scores up to \(AppSettings.maximumExtraCalibrationModels) more Deepgram models, so each person gets the one that understands them best")
        }
    }

    @ViewBuilder
    private var fetchedLabel: some View {
        if let catalog = settings.deepgramModelCatalog {
            Text("\(catalog.models.count) models · \(catalog.source == .project ? "your project" : "Deepgram's public list") · fetched \(catalog.fetchedAt.formatted(.relative(presentation: .named)))")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Text(fetching ? "Fetching the models your key can use…" : "Not fetched yet")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func fetch(refresh: Bool) {
        fetching = true
        fetchError = nil
        Task {
            defer { fetching = false }
            do {
                settings.deepgramModelCatalog = try await SpeechModelLibrary.shared.deepgramModels(refresh: refresh)
            } catch is CancellationError {
            } catch {
                fetchError = "Couldn't fetch Deepgram's models: \(error.localizedDescription)"
            }
        }
    }
}

/// Word error rates on 89 Speech Accent Archive speakers (54 African) reading the same paragraph. Whisper and
/// Cohere were measured through Voiccenger's own transcription path (what users get); Apple and Parakeet raw;
/// Deepgram Nova-3 through its pre-recorded API with `language=en`, smart formatting and `mip_opt_out`.
private struct BenchmarkTable: View {
    private struct Row: Identifiable {
        let group: String
        let rates: [Double]  // Apple, Parakeet v3, Whisper turbo, Cohere, Deepgram Nova-3
        var id: String { group }
    }

    private static let engines = ["Apple", "Parakeet v3", "Whisper", "Cohere", "Deepgram"]
    private static let rows = [
        Row(group: "All speakers", rates: [0.102, 0.091, 0.057, 0.051, 0.074]),
        Row(group: "African", rates: [0.101, 0.080, 0.051, 0.043, 0.072]),
        Row(group: "West African", rates: [0.095, 0.065, 0.049, 0.034, 0.061]),
        Row(group: "East & Southern African", rates: [0.111, 0.105, 0.055, 0.057, 0.093]),
        Row(group: "Native English", rates: [0.013, 0.011, 0.005, 0.009, 0.007]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("We measured word error rates (lower is better) on 89 speakers from the Speech Accent Archive, 54 of them African, all reading the same paragraph.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Group {
                        Text("Speakers").gridColumnAlignment(.leading)
                        ForEach(Self.engines, id: \.self) { Text($0) }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
                Divider()
                ForEach(Self.rows) { row in
                    GridRow {
                        Group {
                            Text(row.group)
                            ForEach(Array(row.rates.enumerated()), id: \.offset) { index, rate in
                                Text(Format.wordErrorRate(rate))
                                    .monospacedDigit()
                                    .fontWeight(rate == row.rates.min() ? .semibold : .regular)
                                    .foregroundStyle(rate == row.rates.min() ? .green : .primary)
                                    .accessibilityLabel("\(Self.engines[index]): \(Format.wordErrorRate(rate))")
                            }
                        }
                        .font(.callout)
                    }
                }
            }
            Text("Apple's British, American and South African English produce identical text: one acoustic model, with the locale only changing formatting. Parakeet v3 sometimes drifts into Dutch or Greek on accented English, so it isn't offered. Cohere is the default; Whisper understands 100 languages, including Swahili, Yoruba, Hausa and Amharic. Deepgram streams the fastest live text but sends audio to the cloud, and is less accurate on African accents than Cohere or Whisper.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
