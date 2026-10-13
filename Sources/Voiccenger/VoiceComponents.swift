import SwiftUI
import VCPipeline

/// SwiftUI's `@State` macro needs a compiler plugin missing from the Command Line Tools; the property wrapper works.
private typealias ViewState = SwiftUI.State

// MARK: - Engines and model status

extension SpeechEngineKind {
    var info: SpeechModelInfo { SpeechModelLibrary.info(self) }
    var displayName: String { info.displayName }

    /// Short name for chips and table cells.
    var shortName: String {
        switch self {
        case .apple: "Apple"
        case .cohere: "Cohere"
        case .whisper: "Whisper"
        }
    }
}

extension ModelStatus {
    /// Files are on disk (or built in) so the engine can be used without a download.
    var isAvailable: Bool {
        switch self {
        case .downloaded, .loading, .ready: true
        case .notDownloaded, .downloading, .failed: false
        }
    }

    var label: String {
        switch self {
        case .notDownloaded: "Not downloaded"
        case .downloading(let fraction): "Downloading \(Format.percent(fraction))"
        case .downloaded: "Downloaded"
        case .loading: "Warming up"
        case .ready: "Ready"
        case .failed: "Failed"
        }
    }
}

/// Latest status of every voice model, kept current from `SpeechModelLibrary.shared.statusUpdates` while
/// `track()` runs (call it from the view's `.task`, which cancels it when the view goes away).
@MainActor @Observable
final class ModelStatusTracker {
    private(set) var statuses: [SpeechEngineKind: ModelStatus] = [:]

    /// nil until the library has reported the engine.
    func status(_ kind: SpeechEngineKind) -> ModelStatus? { statuses[kind] }

    func isAvailable(_ kind: SpeechEngineKind) -> Bool { statuses[kind]?.isAvailable ?? false }

    func track() async {
        for await (kind, status) in SpeechModelLibrary.shared.statusUpdates {
            statuses[kind] = status
        }
    }
}

extension Format {
    static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    /// Word error rate as "3.9%".
    static func wordErrorRate(_ wer: Double) -> String {
        wer.formatted(.percent.precision(.fractionLength(1)))
    }

    static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }

    /// "Nigeria and the United Kingdom" style list of region names.
    static func list(_ items: [String]) -> String {
        items.formatted(.list(type: .and))
    }
}

extension SpellingVariant {
    var title: String {
        switch self {
        case .unchanged: "Unchanged"
        case .british: "British"
        case .american: "American"
        }
    }
}

// MARK: - Regions

extension AccentRegions {
    /// Regions matching `query`, grouped by continent in catalogue order (Africa first).
    static func grouped(matching query: String = "") -> [(continent: String, regions: [AccentRegion])] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var groups: [(continent: String, regions: [AccentRegion])] = []
        for region in all
        where q.isEmpty || [region.name, region.englishName, region.continent, region.id].contains(where: { $0.localizedStandardContains(q) }) {
            if groups.last?.continent == region.continent {
                groups[groups.count - 1].regions.append(region)
            } else {
                groups.append((region.continent, [region]))
            }
        }
        return groups
    }
}

/// Labeled button that opens a searchable list of regions grouped by continent.
struct RegionPicker: View {
    let title: String
    @Binding var selection: String?
    var help: String = ""
    @ViewState private var isPresented = false

    var body: some View {
        LabeledContent(title) {
            Button {
                isPresented = true
            } label: {
                HStack(spacing: 4) {
                    Text(selection.flatMap(AccentRegions.region)?.name ?? "Not set")
                        .foregroundStyle(selection == nil ? .secondary : .primary)
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.borderless)
            .help(help)
            .accessibilityLabel(title)
            .accessibilityValue(selection.flatMap(AccentRegions.region)?.name ?? "Not set")
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                RegionList(selection: $selection) { isPresented = false }
            }
        }
    }
}

private struct RegionList: View {
    @Binding var selection: String?
    let close: () -> Void
    @ViewState private var query = ""
    @FocusState private var searchFocused: Bool

    private var groups: [(continent: String, regions: [AccentRegion])] { AccentRegions.grouped(matching: query) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search countries", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit {
                        if let first = groups.first?.regions.first { choose(first.id) }
                    }
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                List {
                    if query.isEmpty {
                        row(id: nil, name: "Not set", detail: nil)
                    }
                    ForEach(groups, id: \.continent) { group in
                        Section(group.continent) {
                            ForEach(group.regions) { region in
                                row(id: region.id, name: region.name, detail: region.englishName)
                                    .id(region.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .overlay {
                    if groups.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
                .onAppear {
                    if let selection { proxy.scrollTo(selection, anchor: .center) }
                }
            }
        }
        .multilineTextAlignment(.leading)
        .frame(width: 300, height: 420)
        .onAppear { searchFocused = true }
    }

    private func row(id: String?, name: String, detail: String?) -> some View {
        Button {
            choose(id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if selection == id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == id ? .isSelected : [])
    }

    private func choose(_ id: String?) {
        selection = id
        close()
    }
}

// MARK: - Chips

/// Lays subviews out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// A term in a capsule, optionally removable.
struct TermChip: View {
    let term: String
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(term)
                .lineLimit(1)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove \(term)")
                .accessibilityLabel("Remove \(term)")
            }
        }
        .font(.callout)
        .padding(.leading, 8)
        .padding(.trailing, remove == nil ? 8 : 4)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
    }
}

// MARK: - Calibration results

/// Per-engine word error rates from a calibration reading (best first, highlighted), with the transcripts.
struct CalibrationResultsView: View {
    let calibration: VoiceCalibration
    @ViewState private var showTranscripts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Group {
                        Text("Voice model")
                        Text("Word errors").gridColumnAlignment(.trailing)
                        Text("Accuracy")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                }
                Divider()
                ForEach(Array(calibration.scores.enumerated()), id: \.offset) { index, score in
                    GridRow {
                        HStack(spacing: 6) {
                            Text(score.engine.displayName)
                                .fontWeight(index == 0 ? .semibold : .regular)
                            if index == 0 {
                                Text("Best")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.green, in: Capsule())
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            "\(score.engine.displayName)\(index == 0 ? ", best" : ""): \(Format.wordErrorRate(score.wordErrorRate)) word errors")
                        Text(Format.wordErrorRate(score.wordErrorRate))
                            .monospacedDigit()
                            .accessibilityHidden(true)
                        Gauge(value: max(0, min(1, 1 - score.wordErrorRate))) { EmptyView() }
                            .gaugeStyle(.accessoryLinearCapacity)
                            .tint(index == 0 ? .green : .secondary)
                            .frame(minWidth: 80)
                            .accessibilityHidden(true)
                    }
                }
            }
            Toggle("Show transcripts", isOn: $showTranscripts)
                .toggleStyle(.checkbox)
                .font(.callout)
            if showTranscripts {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(calibration.scores.enumerated()), id: \.offset) { _, score in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(score.engine.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(score.transcript.trimmedNonEmpty ?? "(nothing recognised)")
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

/// Checkbox list of corrections proposed from a calibration reading.
struct SuggestedCorrectionsView: View {
    let suggestions: [TextReplacement]
    @Binding var accepted: Set<UUID>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(suggestions) { replacement in
                Toggle(isOn: Binding(
                    get: { accepted.contains(replacement.id) },
                    set: { if $0 { accepted.insert(replacement.id) } else { accepted.remove(replacement.id) } }
                )) {
                    HStack(spacing: 6) {
                        Text("“\(replacement.heard)”").foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        Text("“\(replacement.meant)”")
                    }
                }
                .toggleStyle(.checkbox)
                .accessibilityLabel("Replace \(replacement.heard) with \(replacement.meant)")
            }
        }
    }
}

extension VoiceSettings {
    /// Adds replacements whose "heard" text isn't already corrected.
    mutating func merge(_ new: [TextReplacement]) {
        for replacement in new
        where !replacements.contains(where: { $0.heard.caseInsensitiveCompare(replacement.heard) == .orderedSame }) {
            replacements.append(replacement)
        }
    }
}
