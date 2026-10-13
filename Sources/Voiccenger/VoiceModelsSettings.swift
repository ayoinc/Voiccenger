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
                        Text(info.displayName).tag(info.kind)
                    }
                }
                Toggle("Download models automatically", isOn: $settings.downloadModelsAutomatically)
            } footer: {
                Text("Apple Speech shows words instantly while someone talks; each finished sentence is then rewritten by the selected model. People you've calibrated use the model that understood them best.")
                    .settingsFootnote()
            }
            Section("Models") {
                ForEach(SpeechModelLibrary.allInfo) { info in
                    ModelRow(
                        info: info, status: models.status(info.kind), isDefault: settings.speechEngine == info.kind,
                        error: errors[info.kind],
                        download: { run(info.kind) { try await SpeechModelLibrary.shared.download(info.kind) } },
                        prewarm: { run(info.kind) { try await SpeechModelLibrary.shared.prewarm(info.kind) } },
                        delete: { pendingDelete = info })
                }
            }
            Section {
                DisclosureGroup("How we chose", isExpanded: $showBenchmark) {
                    BenchmarkTable()
                        .padding(.vertical, 6)
                }
            } footer: {
                Text("Models run on this Mac; audio never leaves it. Files are stored in Application Support › Voiccenger › Models.")
                    .settingsFootnote()
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 620)
        .task { await models.track() }
        .confirmationDialog(
            "Delete \(pendingDelete?.displayName ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { info in
            Button("Delete Model", role: .destructive) { delete(info.kind) }
        } message: { info in
            Text("Frees \(Format.bytes(info.downloadBytes)). Meetings fall back to Apple Speech for anyone using it until it's downloaded again.")
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
                if let message = error ?? failureMessage {
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
        }
    }

    private var facts: String {
        var parts: [String] = []
        if info.downloadBytes > 0 { parts.append(Format.bytes(info.downloadBytes)) } else { parts.append("Built in") }
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

/// Word error rates measured on 89 Speech Accent Archive speakers (54 African) reading the same paragraph.
private struct BenchmarkTable: View {
    private struct Row: Identifiable {
        let group: String
        let rates: [Double]  // Apple, Parakeet v3, Whisper turbo, Cohere
        var id: String { group }
    }

    private static let engines = ["Apple", "Parakeet v3", "Whisper", "Cohere"]
    private static let rows = [
        Row(group: "All speakers", rates: [0.102, 0.091, 0.051, 0.045]),
        Row(group: "African", rates: [0.101, 0.080, 0.041, 0.039]),
        Row(group: "West African", rates: [0.095, 0.065, 0.037, 0.030]),
        Row(group: "East & Southern African", rates: [0.111, 0.105, 0.046, 0.054]),
        Row(group: "Native English", rates: [0.013, 0.011, 0.007, 0.005]),
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
            Text("Apple's British, American and South African English produce identical text: one acoustic model, with the locale only changing formatting. Parakeet v3 sometimes drifts into Dutch or Greek on accented English, so it isn't offered. Cohere is the default; Whisper understands 99 languages, including Swahili, Yoruba, Hausa and Amharic.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
