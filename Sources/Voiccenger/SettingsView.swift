import SwiftUI
import VCPipeline

/// SwiftUI's `@State` macro needs a compiler plugin missing from the Command Line Tools; the property wrapper works.
private typealias ViewState = SwiftUI.State

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Transcription", systemImage: "text.bubble") { TranscriptionSettings() }
            Tab("Intelligence", systemImage: "sparkles") { IntelligenceSettings() }
            Tab("Audio", systemImage: "mic") { AudioSettings() }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppUpdater.self) private var updater

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Detect online meetings", isOn: $settings.autoDetectMeetings)
                Picker("When a meeting starts", selection: $settings.autoRecordOnline) {
                    Text("Notify me").tag(false)
                    Text("Start recording automatically").tag(true)
                }
                .disabled(!settings.autoDetectMeetings)
            } footer: {
                Text("Voiccenger notices when an app like Zoom, Teams, FaceTime or a browser meeting starts using the microphone, and stops recording when it ends.")
                    .settingsFootnote()
            }
            Section {
                Toggle("Detect in-person meetings", isOn: $settings.inPersonDetection)
            } footer: {
                Text("Listens on the microphone for sustained conversation and suggests recording. Audio isn't stored or transcribed until you start recording.")
                    .settingsFootnote()
            }
            Section {
                Toggle("Keep audio recordings", isOn: $settings.recordAudio)
            } footer: {
                Text("Saves each meeting's audio next to its transcript.")
                    .settingsFootnote()
            }
            UpdateSettingsSection(updater: updater)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Transcription

private struct TranscriptionSettings: View {
    @Environment(AppSettings.self) private var settings
    @ViewState private var supported: [String] = []
    @ViewState private var installed: Set<String> = []
    @ViewState private var loading = true
    @ViewState private var downloadProgress: Double?
    @ViewState private var downloadError: String?
    @ViewState private var newTerm = ""

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                if loading {
                    LabeledContent("Language") { ProgressView().controlSize(.small) }
                } else {
                    Picker("Language", selection: $settings.localeID) {
                        if !supported.contains(settings.localeID) {
                            Text(Format.localeName(settings.localeID)).tag(settings.localeID)
                        }
                        ForEach(sortedLocales, id: \.self) { id in
                            Text(installed.contains(id) ? Format.localeName(id) : "\(Format.localeName(id)) (download needed)")
                                .tag(id)
                        }
                    }
                    if !installed.contains(settings.localeID) {
                        LabeledContent("Speech model") {
                            if let downloadProgress {
                                ProgressView(value: downloadProgress)
                                    .frame(width: 140)
                                    .accessibilityLabel("Downloading speech model")
                            } else {
                                Button("Download") { download(settings.localeID) }
                                    .help("Download the on-device speech model now instead of when the first meeting starts")
                            }
                        }
                    }
                    if let downloadError {
                        Text(downloadError)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
                Toggle("Switch language and accent automatically", isOn: $settings.autoLanguage)
            } footer: {
                Text("The language is used when a meeting starts. With automatic switching, Voiccenger changes the recognizer when someone speaks another language or with a different accent, and uses each enrolled person's accent.")
                    .settingsFootnote()
            }
            Section {
                ForEach(settings.customVocabulary, id: \.self) { term in
                    HStack {
                        Text(term)
                        Spacer()
                        Button {
                            settings.customVocabulary.removeAll { $0 == term }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(term)")
                        .help("Remove")
                    }
                }
                HStack {
                    TextField("Add a word or name", text: $newTerm)
                        .onSubmit(addTerm)
                    Button("Add", action: addTerm)
                        .disabled(newTerm.trimmedNonEmpty == nil)
                }
            } header: {
                Text("Custom Vocabulary")
            } footer: {
                Text("Product names, jargon and names the recognizer should expect. Enrolled people's names are added automatically.")
                    .settingsFootnote()
            }
        }
        .formStyle(.grouped)
        .task { await load() }
    }

    private var sortedLocales: [String] {
        supported.sorted { Format.localeName($0).localizedCaseInsensitiveCompare(Format.localeName($1)) == .orderedAscending }
    }

    private func load() async {
        async let s = SpeechAssets.supportedLocaleIDs()
        async let i = SpeechAssets.installedLocaleIDs()
        supported = await s
        installed = Set(await i)
        loading = false
    }

    private func addTerm() {
        guard let term = newTerm.trimmedNonEmpty else { return }
        if !settings.customVocabulary.contains(term) { settings.customVocabulary.append(term) }
        newTerm = ""
    }

    private func download(_ id: String) {
        downloadError = nil
        downloadProgress = 0
        Task {
            do {
                try await SpeechAssets.ensureInstalled(localeIDs: [id]) { value in
                    Task { @MainActor in downloadProgress = value }
                }
                installed = Set(await SpeechAssets.installedLocaleIDs())
            } catch {
                downloadError = "The speech model couldn't be downloaded: \(error.localizedDescription)"
            }
            downloadProgress = nil
        }
    }
}

// MARK: - Intelligence

private struct IntelligenceSettings: View {
    @Environment(AppSettings.self) private var settings
    @ViewState private var apiKey = ""
    @ViewState private var savedKey = false
    @ViewState private var keyFromEnvironment = false
    @ViewState private var keyError: String?

    private static let keyAccount = "anthropic-api-key"

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Engine", selection: $settings.engine) {
                    Text("Apple Intelligence (on this Mac)").tag(IntelligenceEngineKind.apple)
                    Text("Claude (Anthropic)").tag(IntelligenceEngineKind.claude)
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("Used for live corrections and suggestions during meetings and for the report afterwards. If the selected engine isn't available, the other one is used.")
                    .settingsFootnote()
            }
            Section("Apple Intelligence") {
                if AppleIntelligenceEngine.isAvailable {
                    Label("Available", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label(AppleIntelligenceEngine.unavailableReason ?? "Unavailable", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                SecureField("API key", text: $apiKey, prompt: Text(savedKey ? "Saved in Keychain" : "sk-ant-…"))
                    .onSubmit(saveKey)
                HStack {
                    status
                    Spacer()
                    if savedKey {
                        Button("Remove Key", role: .destructive, action: removeKey)
                    }
                    Button("Save Key", action: saveKey)
                        .disabled(apiKey.trimmedNonEmpty == nil)
                }
                if let keyError {
                    Text(keyError).font(.callout).foregroundStyle(.red)
                }
            } header: {
                Text("Claude")
            } footer: {
                Text("The key is stored in your Keychain. Transcript text is sent to Anthropic when Claude is used; model: \(ClaudeEngine.defaultModel).")
                    .settingsFootnote()
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }

    @ViewBuilder
    private var status: some View {
        if savedKey {
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else if keyFromEnvironment {
            Label("Using ANTHROPIC_API_KEY", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Label("No key", systemImage: "key").foregroundStyle(.secondary)
        }
    }

    private func refresh() {
        savedKey = KeychainStore.get(account: Self.keyAccount) != nil
        keyFromEnvironment = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?.trimmedNonEmpty != nil
    }

    private func saveKey() {
        guard let key = apiKey.trimmedNonEmpty else { return }
        store(key)
    }

    private func removeKey() { store(nil) }

    private func store(_ key: String?) {
        do {
            try KeychainStore.set(key, account: Self.keyAccount)
            keyError = nil
            apiKey = ""
        } catch {
            keyError = "The key couldn't be saved: \(error.localizedDescription)"
        }
        refresh()
    }
}

// MARK: - Audio

private struct AudioSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MeetingCoordinator.self) private var coordinator
    @ViewState private var devices: [AudioInputDevice] = []

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Microphone", selection: $settings.inputDeviceUID) {
                    Text(AudioDevices.defaultInputDevice().map { "System Default (\($0.name))" } ?? "System Default")
                        .tag(String?.none)
                    if let uid = settings.inputDeviceUID, !devices.contains(where: { $0.id == uid }) {
                        Text("Disconnected device").tag(String?.some(uid))
                    }
                    ForEach(devices) { device in
                        Text("\(device.name) (\(device.channelCount) ch)").tag(String?.some(device.id))
                    }
                }
                Picker("Microphone array", selection: $settings.arrayPresetName) {
                    Text("None").tag(String?.none)
                    ForEach(ArrayPresets.all) { geometry in
                        Text("\(geometry.name) — \(geometry.mics.count) mics").tag(String?.some(geometry.name))
                    }
                }
                if let warning = channelWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .font(.callout)
                }
            } footer: {
                Text("With a microphone array, Voiccenger estimates where each person sits (GCC-PHAT) and shows it in the Live and Spatial views. Changes apply to the next recording.")
                    .settingsFootnote()
            }
        }
        .formStyle(.grouped)
        .task { devices = AudioDevices.inputDevices() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            devices = AudioDevices.inputDevices()
        }
        .disabled(coordinator.isRecording)
    }

    private var channelWarning: String? {
        guard let geometry = settings.arrayGeometry else { return nil }
        let device = settings.inputDeviceUID.flatMap { uid in devices.first { $0.id == uid } } ?? AudioDevices.defaultInputDevice()
        guard let device else { return nil }
        let needed = (geometry.channelMap.max() ?? 0) + 1
        guard device.channelCount < needed else { return nil }
        return "\(device.name) has \(device.channelCount) input channel\(device.channelCount == 1 ? "" : "s"); the \(geometry.name) needs \(needed). Choose the array as the microphone."
    }
}

extension Text {
    func settingsFootnote() -> some View {
        font(.callout).foregroundStyle(.secondary)
    }
}
