import AppKit
import SwiftUI
import VCPipeline

/// SwiftUI's `@State` macro needs a compiler plugin missing from the Command Line Tools; the property wrapper works.
private typealias ViewState = SwiftUI.State

struct MeetingsView: View {
    @Environment(MeetingCoordinator.self) private var coordinator
    @Environment(NavigationModel.self) private var navigation
    @ViewState private var search = ""
    @ViewState private var pendingDelete: Meeting?

    private var filtered: [Meeting] {
        guard let query = search.trimmedNonEmpty else { return coordinator.meetings }
        return coordinator.meetings.filter { m in
            m.title.localizedStandardContains(query)
                || m.participants.contains { $0.displayName.localizedStandardContains(query) }
                || m.segments.contains { $0.text.localizedStandardContains(query) }
        }
    }

    var body: some View {
        @Bindable var navigation = navigation
        NavigationStack(path: $navigation.meetingPath) {
            Group {
                if coordinator.meetings.isEmpty {
                    ContentUnavailableView(
                        "No Meetings Yet", systemImage: "list.bullet.rectangle",
                        description: Text("Recorded meetings and their reports appear here."))
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    List {
                        ForEach(filtered) { meeting in
                            NavigationLink(value: meeting.id) {
                                MeetingRow(meeting: meeting)
                            }
                            .contextMenu {
                                Button("Delete…", role: .destructive) { pendingDelete = meeting }
                            }
                        }
                        .onDelete { offsets in
                            if let i = offsets.first { pendingDelete = filtered[i] }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("Meetings")
            .searchable(text: $search, prompt: "Titles, people or transcript")
            .navigationDestination(for: UUID.self) { id in
                if coordinator.meetings.contains(where: { $0.id == id }) {
                    MeetingDetailView(meetingID: id)
                } else {
                    ContentUnavailableView("Meeting Not Found", systemImage: "questionmark.folder")
                }
            }
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.title ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { meeting in
            Button("Delete Meeting", role: .destructive) {
                navigation.meetingPath.removeAll { $0 == meeting.id }
                Task { await coordinator.deleteMeeting(id: meeting.id) }
            }
        } message: { _ in
            Text("The transcript, report and audio recordings are removed. This can't be undone.")
        }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: meeting.kind == .online ? "video" : "person.3")
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityLabel(meeting.kind == .online ? "Online meeting" : "In-person meeting")
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if meeting.report == nil {
                Image(systemName: "doc.badge.ellipsis")
                    .foregroundStyle(.tertiary)
                    .help("No report")
                    .accessibilityLabel("No report")
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts = [meeting.startedAt.formatted(date: .abbreviated, time: .shortened), Format.duration(meeting.duration)]
        let names = meeting.participants.map(\.displayName)
        if !names.isEmpty { parts.append(names.formatted(.list(type: .and))) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Detail

private enum DetailTab: String, CaseIterable, Identifiable {
    case report, transcript, participants
    var id: String { rawValue }
    var title: String {
        switch self {
        case .report: "Report"
        case .transcript: "Transcript"
        case .participants: "Participants"
        }
    }
}

private struct MeetingDetailView: View {
    @Environment(MeetingCoordinator.self) private var coordinator
    @Environment(NavigationModel.self) private var navigation
    let meetingID: UUID
    @ViewState private var tab: DetailTab = .report
    @ViewState private var exporting = false
    @ViewState private var exportDocument = MarkdownDocument(text: "")
    @ViewState private var renamingTitle = false
    @ViewState private var newTitle = ""
    @ViewState private var confirmingDelete = false
    /// Session time to scroll the transcript to, set by a timestamp in the report.
    @ViewState private var transcriptTarget: TimeInterval?

    private var meeting: Meeting? { coordinator.meetings.first { $0.id == meetingID } }

    var body: some View {
        if let meeting {
            content(meeting)
                .navigationTitle(meeting.title)
                .navigationSubtitle(
                    "\(meeting.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(Format.duration(meeting.duration))"
                )
                .toolbar { toolbar(meeting) }
                .fileExporter(
                    isPresented: $exporting, document: exportDocument, contentType: .markdownText,
                    defaultFilename: Self.fileName(for: meeting)
                ) { result in
                    if case .failure(let error) = result {
                        coordinator.lastError = "The report couldn't be exported: \(error.localizedDescription)"
                    }
                }
                .alert("Rename Meeting", isPresented: $renamingTitle) {
                    TextField("Title", text: $newTitle)
                    Button("Rename") { Task { await coordinator.renameMeeting(meetingID, to: newTitle) } }
                    Button("Cancel", role: .cancel) {}
                }
                .confirmationDialog("Delete “\(meeting.title)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                    Button("Delete Meeting", role: .destructive) {
                        navigation.meetingPath.removeAll { $0 == meetingID }
                        Task { await coordinator.deleteMeeting(id: meetingID) }
                    }
                } message: {
                    Text("The transcript, report and audio recordings are removed. This can't be undone.")
                }
        }
    }

    @ViewBuilder
    private func content(_ meeting: Meeting) -> some View {
        switch tab {
        case .report:
            ReportView(meeting: meeting) { time in
                transcriptTarget = time
                tab = .transcript
            }
        case .transcript: SavedTranscriptView(meeting: meeting, target: $transcriptTarget)
        case .participants: ParticipantsTable(meeting: meeting)
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ meeting: Meeting) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $tab) {
                ForEach(DetailTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if coordinator.generatingReports.contains(meetingID) {
                ProgressView()
                    .controlSize(.small)
                    .help("Writing the report…")
            } else {
                Button {
                    Task { await coordinator.generateReport(for: meetingID) }
                } label: {
                    Label(meeting.report == nil ? "Write Report" : "Rewrite Report", systemImage: "sparkles")
                }
                .help(meeting.report == nil ? "Write the report with the selected intelligence engine" : "Write the report again")
                .disabled(meeting.segments.isEmpty)
            }
            Button {
                Pasteboard.copy(ReportRenderer.markdown(meeting))
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .help("Copy the report and transcript as Markdown")
            Button {
                exportDocument = MarkdownDocument(text: ReportRenderer.markdown(meeting))
                exporting = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export the report and transcript as a Markdown file")
            Menu {
                Button("Rename…") {
                    newTitle = meeting.title
                    renamingTitle = true
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([coordinator.meetingStore.directory(for: meetingID)])
                }
                Divider()
                Button("Delete…", role: .destructive) { confirmingDelete = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("More actions")
        }
    }

    private static func fileName(for meeting: Meeting) -> String {
        let unsafe = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = meeting.title.components(separatedBy: unsafe).joined(separator: "-")
        return "\(cleaned.trimmedNonEmpty ?? "Meeting").md"
    }
}

// MARK: - Report tab

private struct ReportView: View {
    @Environment(MeetingCoordinator.self) private var coordinator
    let meeting: Meeting
    /// Shows the transcript at a session time (a timestamp in the report was clicked).
    let showInTranscript: (TimeInterval) -> Void

    var body: some View {
        if let report = meeting.report {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(report.title).font(.largeTitle.bold())
                        Text("Written by \(report.generatedBy) · \(report.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if report.kind == .transcriptOutline {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Not written by AI").font(.headline)
                                    Text(ReportRenderer.transcriptOutlineNote).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "text.quote")
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                            .padding(.vertical, 6)
                        }
                        if !report.overview.isEmpty {
                            Text(report.overview).font(.title3)
                        }
                    }
                    if report.kind == .transcriptOutline {
                        OutlineSection("Transcript Outline (no AI)", segments: report.outline, meeting: meeting, showInTranscript: showInTranscript)
                        BulletSection("Questions Asked", symbol: "questionmark.bubble", items: report.openQuestions)
                        ActionItemsSection("Possible Action Items", items: report.actionItems)
                    } else {
                        languageModelSections(report)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
                .textSelection(.enabled)
            }
        } else {
            ContentUnavailableView {
                Label("No Report", systemImage: "doc.badge.ellipsis")
            } description: {
                Text(
                    meeting.segments.isEmpty
                        ? "Nothing was transcribed in this meeting."
                        : "The report wasn't written when the meeting ended. You can write it now."
                )
            } actions: {
                if !meeting.segments.isEmpty {
                    Button("Write Report") { Task { await coordinator.generateReport(for: meeting.id) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(coordinator.generatingReports.contains(meeting.id))
                }
            }
        }
    }

    @ViewBuilder
    private func languageModelSections(_ report: MeetingReport) -> some View {
        if !report.topics.isEmpty {
            ReportSection("Topics", symbol: "text.bubble") {
                ForEach(Array(report.topics.enumerated()), id: \.offset) { _, topic in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(topic.title).font(.headline)
                        Text(topic.summary)
                        if !topic.speakers.isEmpty {
                            Text(topic.speakers.formatted(.list(type: .and)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        BulletSection("Decisions", symbol: "checkmark.seal", items: report.decisions)
        ActionItemsSection("Action Items", items: report.actionItems)
        BulletSection("Notes to Remember", symbol: "pin", items: report.notesToRemember)
        BulletSection("Could Have Been Said", symbol: "lightbulb", items: report.missedOpportunities)
        BulletSection("Open Questions", symbol: "questionmark.bubble", items: report.openQuestions)
        if !report.corrections.isEmpty {
            ReportSection("Corrections", symbol: "pencil.and.scribble") {
                ForEach(Array(report.corrections.enumerated()), id: \.offset) { _, c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(c.speaker): “\(c.original)”")
                            .foregroundStyle(.secondary)
                            .strikethrough()
                        Text("“\(c.corrected)”")
                        if !c.reason.isEmpty {
                            Text(c.reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        if !report.participantSummaries.isEmpty {
            ReportSection("Participants", symbol: "person.2") {
                ForEach(Array(report.participantSummaries.enumerated()), id: \.offset) { _, summary in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            if let p = meeting.participants.first(where: { $0.displayName == summary.name }) {
                                ParticipantDot(colorIndex: p.colorIndex)
                            }
                            Text(summary.name).font(.headline)
                        }
                        ForEach(summary.keyPoints, id: \.self) { point in
                            Text("• \(point)")
                        }
                    }
                }
            }
        }
        OutlineSection("Conversation Outline", segments: report.outline, meeting: meeting, showInTranscript: showInTranscript)
    }
}

private struct ActionItemsSection: View {
    let title: String
    let items: [ActionItem]

    init(_ title: String, items: [ActionItem]) {
        self.title = title
        self.items = items
    }

    var body: some View {
        if !items.isEmpty {
            ReportSection(title, symbol: "checklist") {
                ForEach(items) { item in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.task)
                            let meta = [item.owner, item.due].compactMap { $0?.trimmedNonEmpty }
                            if !meta.isEmpty {
                                Text(meta.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// The conversation outline: one disclosure group per segment (open at first unless the outline is long), headed by
/// its time range and heading; each point shows its speaker and when it was said. Timestamps show that moment in
/// the transcript.
private struct OutlineSection: View {
    let title: String
    let segments: [OutlineSegment]
    let meeting: Meeting
    let showInTranscript: (TimeInterval) -> Void
    @ViewState private var collapsed: Set<Int>

    /// Up to this many segments start open; a longer outline starts as a list of headings.
    private static let openSegments = 8

    init(_ title: String, segments: [OutlineSegment], meeting: Meeting, showInTranscript: @escaping (TimeInterval) -> Void) {
        self.title = title
        self.segments = segments
        self.meeting = meeting
        self.showInTranscript = showInTranscript
        _collapsed = ViewState(initialValue: segments.count > Self.openSegments ? Set(segments.indices) : [])
    }

    var body: some View {
        if !segments.isEmpty {
            ReportSection(title, symbol: "list.bullet.indent") {
                Button(collapsed.isEmpty ? "Collapse All" : "Expand All") {
                    collapsed = collapsed.isEmpty ? Set(segments.indices) : []
                }
                .buttonStyle(.link)
                .font(.callout)
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    DisclosureGroup(isExpanded: expanded(index)) {
                        VStack(alignment: .leading, spacing: 6) {
                            if segment.isExtracted, meeting.report?.kind == .languageModel {
                                Text(ReportRenderer.extractedSegmentNote)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(Array(segment.points.enumerated()), id: \.offset) { _, point in
                                pointRow(point)
                            }
                        }
                        .padding(.top, 4)
                        .padding(.leading, 4)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            timestampButton(ReportRenderer.timeRange(segment.start, segment.end), time: segment.start)
                            Text(segment.heading).font(.headline)
                        }
                    }
                }
            }
        }
    }

    private func expanded(_ index: Int) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(index) },
            set: { open in
                if open { collapsed.remove(index) } else { collapsed.insert(index) }
            })
    }

    private func pointRow(_ point: OutlinePoint) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let p = meeting.participants.first(where: { $0.displayName == point.speaker }) {
                ParticipantDot(colorIndex: p.colorIndex, size: 8)
            }
            Text("\(Text(point.speaker).bold()): \(point.isQuote ? "“\(point.text)”" : point.text)")
                .frame(maxWidth: .infinity, alignment: .leading)
            timestampButton(ReportRenderer.timestamp(point.time), time: point.time)
                .font(.caption)
        }
    }

    private func timestampButton(_ label: String, time: TimeInterval) -> some View {
        Button(label) { showInTranscript(time) }
            .buttonStyle(.link)
            .monospacedDigit()
            .help("Show in the transcript")
            .accessibilityLabel("Show \(label) in the transcript")
    }
}

private struct ReportSection<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content

    init(_ title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

private struct BulletSection: View {
    let title: String
    let symbol: String
    let items: [String]

    init(_ title: String, symbol: String, items: [String]) {
        self.title = title
        self.symbol = symbol
        self.items = items
    }

    var body: some View {
        if !items.isEmpty {
            ReportSection(title, symbol: symbol) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text("• \(item)")
                }
            }
        }
    }
}

// MARK: - Transcript tab

/// The saved transcript, searchable. `target` scrolls to the line said at that session time and highlights it.
private struct SavedTranscriptView: View {
    let meeting: Meeting
    @Binding var target: TimeInterval?
    @ViewState private var search = ""
    @ViewState private var highlighted: UUID?

    private var segments: [TranscriptSegment] {
        let sorted = meeting.segments.sorted { $0.range.start < $1.range.start }
        guard let query = search.trimmedNonEmpty else { return sorted }
        return sorted.filter {
            $0.text.localizedStandardContains(query)
                || ReportRenderer.displayName(for: $0.speakerKey, in: meeting).localizedStandardContains(query)
        }
    }

    var body: some View {
        Group {
            if meeting.segments.isEmpty {
                ContentUnavailableView("No Transcript", systemImage: "text.bubble", description: Text("Nothing was transcribed in this meeting."))
            } else if segments.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(segments) { segment in
                                TranscriptRow(segment: segment, participant: meeting.participant(segment.speakerKey))
                                    .padding(4)
                                    .background(
                                        highlighted == segment.id ? Color.accentColor.opacity(0.15) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                                    .id(segment.id)
                            }
                        }
                        .padding()
                        .textSelection(.enabled)
                    }
                    .onChange(of: target, initial: true) { _, time in
                        guard let time else { return }
                        target = nil
                        // The line being said at `time`: the last one starting by then.
                        let sorted = segments
                        guard let line = sorted.last(where: { $0.range.start <= time + 0.5 }) ?? sorted.first else { return }
                        highlighted = line.id
                        // After the rows exist: the transcript tab may have just appeared.
                        DispatchQueue.main.async {
                            withAnimation { proxy.scrollTo(line.id, anchor: .center) }
                        }
                    }
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search transcript")
    }
}

// MARK: - Participants tab

private struct ParticipantsTable: View {
    @Environment(MeetingCoordinator.self) private var coordinator
    let meeting: Meeting
    @ViewState private var selection: Participant.ID?
    @ViewState private var renaming: Participant?
    @ViewState private var newName = ""

    private var rows: [Participant] { meeting.participants.sorted { $0.speakingTime > $1.speakingTime } }

    var body: some View {
        if meeting.participants.isEmpty {
            ContentUnavailableView("No Participants", systemImage: "person.2.slash", description: Text("No speakers were identified."))
        } else {
            Table(rows, selection: $selection) {
                TableColumn("Name") { p in
                    HStack(spacing: 6) {
                        ParticipantDot(colorIndex: p.colorIndex)
                        Text(p.displayName)
                        if p.isEnrolled {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.secondary)
                                .help("Enrolled voice")
                                .accessibilityLabel("Enrolled")
                        }
                    }
                }
                TableColumn("Where") { p in Text(p.channel == .microphone ? "In room" : "Remote") }
                    .width(min: 60, ideal: 80)
                TableColumn("Language") { p in Text(p.localeID.map(Format.localeName) ?? "—") }
                TableColumn("Seat") { p in Text(p.seatAzimuthDegrees.map(Format.degrees) ?? "—").monospacedDigit() }
                    .width(min: 40, ideal: 60)
                TableColumn("Speaking") { p in Text(Format.duration(p.speakingTime)).monospacedDigit() }
                    .width(min: 60, ideal: 90)
                TableColumn("Lines") { p in
                    Text("\(meeting.segments.count { $0.speakerKey == p.id })").monospacedDigit()
                }
                .width(min: 40, ideal: 50)
            }
            .contextMenu(forSelectionType: Participant.ID.self) { ids in
                if let id = ids.first, let p = meeting.participant(id) {
                    Button("Rename…") {
                        newName = p.displayName
                        renaming = p
                    }
                }
            } primaryAction: { ids in
                if let id = ids.first, let p = meeting.participant(id) {
                    newName = p.displayName
                    renaming = p
                }
            }
            .alert("Rename Participant", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Rename") {
                    if let key = renaming?.id {
                        Task { await coordinator.renameParticipant(key, to: newName, inMeeting: meeting.id) }
                    }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            } message: {
                Text("The transcript and report use the new name.")
            }
        }
    }
}
