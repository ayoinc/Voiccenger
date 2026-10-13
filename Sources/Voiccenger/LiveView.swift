import SwiftUI
import VCPipeline

/// SwiftUI's `@State` macro needs a compiler plugin missing from the Command Line Tools; the property wrapper works.
private typealias ViewState = SwiftUI.State

struct LiveView: View {
    @Environment(MeetingCoordinator.self) private var coordinator
    @Environment(NavigationModel.self) private var navigation
    @ViewState private var showInspector = true

    var body: some View {
        Group {
            if let session = coordinator.session {
                switch session.state {
                case .idle, .starting:
                    ProgressView("Preparing speech and speaker models…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .recording, .finishing:
                    LiveSessionView(session: session)
                        .inspector(isPresented: $showInspector) {
                            AttentionInspector(session: session)
                                .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
                        }
                case .finished:
                    FinishedSessionView(session: session)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Recording Failed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Dismiss") { coordinator.dismissFinishedSession() }
                    }
                }
            } else {
                IdleLiveView()
            }
        }
        .navigationTitle("Live")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                RecordButton()
                if coordinator.session?.isActive == true {
                    Button {
                        showInspector.toggle()
                    } label: {
                        Label("Attention", systemImage: "sidebar.trailing")
                    }
                    .help("Show or hide corrections, suggestions and action items")
                }
            }
        }
    }

    private var subtitle: String {
        guard let session = coordinator.session, session.isActive else { return StatusSymbol.label(for: coordinator.status) }
        if let app = session.config.detectedMeeting?.app.displayName { return "Online meeting · \(app)" }
        return session.config.kind == .online ? "Online meeting" : "In-person meeting"
    }
}

struct RecordButton: View {
    @Environment(MeetingCoordinator.self) private var coordinator

    var body: some View {
        let active = coordinator.session?.isActive == true
        Button {
            Task { await coordinator.toggleRecording() }
        } label: {
            Label(active ? "Stop" : "Record", systemImage: active ? "stop.circle.fill" : "record.circle")
                .foregroundStyle(active ? .red : .primary)
        }
        .disabled(coordinator.status == .finishing || coordinator.session?.state == .starting)
        .help(active ? "Stop recording and write the report (⌘R)" : "Start recording a meeting (⌘R)")
    }
}

// MARK: - Idle

private struct IdleLiveView: View {
    @Environment(MeetingCoordinator.self) private var coordinator

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: coordinator.status == .detected ? "waveform.badge.exclamationmark" : "waveform")
        } description: {
            Text(description)
        } actions: {
            if let detected = coordinator.detectedMeeting {
                Button("Record \(detected.app.displayName) Meeting") {
                    Task { await coordinator.startRecording(kind: .online, detected: detected) }
                }
                .buttonStyle(.borderedProminent)
            }
            Button("Start In-Person Meeting") {
                Task { await coordinator.startRecording(kind: .inPerson) }
            }
            .buttonStyle(coordinator.detectedMeeting == nil ? AnyPrimitiveButtonStyle(.borderedProminent) : AnyPrimitiveButtonStyle(.bordered))
        }
    }

    private var title: String {
        if let app = coordinator.detectedMeeting?.app.displayName { return "\(app) Meeting Detected" }
        if coordinator.conversationDetectedAt != nil { return "Conversation Detected" }
        return "No Meeting in Progress"
    }

    private var description: String {
        if coordinator.detectedMeeting != nil {
            return "Record to transcribe the meeting live, identify speakers and get a report when it ends."
        }
        if coordinator.conversationDetectedAt != nil {
            return "It sounds like an in-person meeting. Start recording to transcribe it."
        }
        if coordinator.settings.autoDetectMeetings {
            return "Voiccenger is watching for meeting apps using the microphone. You can also start recording yourself."
        }
        return "Start recording to transcribe a meeting live."
    }
}

/// Type-erased primitive button style so one call site can pick a style at runtime.
private struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

// MARK: - Recording

private struct LiveSessionView: View {
    let session: MeetingSession

    var body: some View {
        VStack(spacing: 0) {
            SessionHeader(session: session)
            Divider()
            HStack(spacing: 0) {
                LiveTranscriptView(session: session)
                    .frame(maxWidth: .infinity)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        RosterPanel(session: session)
                        if session.hasMicArray {
                            GroupBox("Seats") {
                                SeatCompass(
                                    markers: session.participants.compactMap { p in
                                        p.seatAzimuthDegrees.map {
                                            SeatCompass.Marker(id: p.id, label: p.displayName, azimuth: $0, colorIndex: p.colorIndex)
                                        }
                                    },
                                    liveAzimuth: session.latestDirection?.azimuthDegrees,
                                    liveConfidence: session.latestDirection?.confidence ?? 0
                                )
                                .frame(maxWidth: 260)
                                .padding(8)
                            }
                        }
                    }
                    .padding()
                }
                .frame(width: 280)
            }
        }
    }
}

private struct SessionHeader: View {
    let session: MeetingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                if session.state == .finishing {
                    ProgressView().controlSize(.small)
                    Text("Finishing transcription and writing the report…")
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse)
                        .accessibilityHidden(true)
                    if let start = session.startedAt {
                        TimelineView(.periodic(from: start, by: 1)) { context in
                            Text(Format.timestamp(context.date.timeIntervalSince(start)))
                                .monospacedDigit()
                                .font(.headline)
                        }
                        .accessibilityLabel("Elapsed time")
                    }
                    LevelMeter(rms: session.inputLevel)
                        .frame(width: 120)
                }
                Spacer()
                EngineStatusChip(
                    engine: session.config.speechEngine,
                    reported: session.speechEngineStatuses[session.config.speechEngine])
                ForEach(session.currentLocales.sorted(by: { $0.key.rawValue < $1.key.rawValue }), id: \.key) { channel, locale in
                    Label(Format.localeName(locale), systemImage: channel == .microphone ? "mic" : "speaker.wave.2")
                        .font(.callout)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .help("\(channel == .microphone ? "Room" : "Meeting audio") is transcribed as \(Format.localeName(locale))")
                }
                if let engine = session.intelligenceEngineName {
                    Label(engine, systemImage: "sparkles")
                        .font(.callout)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .help("Live analysis engine: \(engine)")
                }
            }
            ForEach(session.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .symbolRenderingMode(.multicolor)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct LiveTranscriptView: View {
    let session: MeetingSession
    private static let bottomID = "bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if session.segments.isEmpty && session.pendingFinals.isEmpty && session.volatileText.values.allSatisfy(\.isEmpty) {
                        ContentUnavailableView("Listening…", systemImage: "ear", description: Text("Transcribed speech appears here."))
                            .padding(.top, 60)
                    }
                    ForEach(session.segments) { segment in
                        TranscriptRow(segment: segment, participant: session.roster.participant(segment.speakerKey))
                            .id(segment.id)
                    }
                    ForEach(Array(session.pendingFinals.enumerated()), id: \.offset) { _, update in
                        PendingRow(text: update.text, time: update.range.start, channel: update.channel)
                    }
                    ForEach(AudioChannel.allCases, id: \.self) { channel in
                        if let text = session.volatileText[channel]?.trimmedNonEmpty {
                            PendingRow(text: text, time: nil, channel: channel)
                                .opacity(0.7)
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding()
                .textSelection(.enabled)
            }
            .onChange(of: session.segments.count) { scrollToBottom(proxy) }
            .onChange(of: session.volatileText) { scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
    }
}

struct TranscriptRow: View {
    let segment: TranscriptSegment
    let participant: Participant?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ParticipantDot(colorIndex: participant?.colorIndex ?? 0)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(participant?.displayName ?? segment.speakerKey)
                        .font(.headline)
                    Text(Format.timestamp(segment.range.start))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(segment.localeID)
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                        .help(segmentSourceDescription)
                    if let intent = segment.insight?.intent, intent != .statement {
                        Text(intent.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(segment.text)
                    .font(.body)
                if let corrected = segment.insight?.correctedText?.trimmedNonEmpty {
                    Label {
                        let reason = Text(segment.insight?.correctionReason.map { " — \($0)" } ?? "").foregroundStyle(.secondary)
                        Text("Did you mean “\(corrected)”?\(reason)")
                    } icon: {
                        Image(systemName: "pencil.and.scribble")
                    }
                    .font(.callout)
                    .foregroundStyle(.orange)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var segmentSourceDescription: String {
        let language = Format.localeName(segment.localeID)
        guard let engine = segment.engine else { return language }
        return "\(language) · transcribed by \(engine.displayName)"
    }
}

private struct PendingRow: View {
    let text: String
    let time: TimeInterval?
    let channel: AudioChannel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: channel == .microphone ? "mic" : "speaker.wave.2")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 10)
            VStack(alignment: .leading, spacing: 2) {
                if let time {
                    Text("\(Format.timestamp(time)) · identifying speaker…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(text)
                    .foregroundStyle(.secondary)
                    .italic(time == nil)
            }
        }
        .accessibilityLabel(time == nil ? "Being transcribed: \(text)" : "Awaiting speaker: \(text)")
    }
}

/// The meeting's voice model and whether it's rewriting lines yet ("Cohere · warming up"), or "Apple preview"
/// when it can't be used.
private struct EngineStatusChip: View {
    let engine: SpeechEngineKind
    /// Latest status from the session; nil until the model library has reported it.
    let reported: ModelStatus?

    var body: some View {
        HStack(spacing: 5) {
            indicator
            Text(title)
                .lineLimit(1)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
        .fixedSize()
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Voice model")
        .accessibilityValue(title)
        .accessibilityHint(help)
    }

    private var status: ModelStatus? { engine == .apple ? .ready : reported }

    private var title: String {
        guard engine != .apple else { return engine.displayName }
        switch status {
        case nil: return engine.shortName
        case .ready: return "\(engine.shortName) · ready"
        case .loading, .downloaded: return "\(engine.shortName) · warming up"
        case .downloading(let fraction): return "\(engine.shortName) · downloading \(Format.percent(fraction))"
        case .notDownloaded, .failed: return "Apple preview"
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch status {
        case .ready:
            dot(.green)
        case .loading, .downloaded, .downloading:
            dot(.orange).symbolEffect(.pulse)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .imageScale(.small)
        case .notDownloaded, nil:
            dot(.secondary)
        }
    }

    private func dot(_ color: Color) -> some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 7))
            .foregroundStyle(color)
    }

    private var help: String {
        let name = engine.displayName
        switch status {
        case _ where engine == .apple:
            return "Apple Speech transcribes this meeting."
        case .ready, nil:
            return "Apple Speech previews words as they're spoken; \(name) writes each finished line."
        case .loading, .downloaded:
            return "\(name) is loading. Until it's ready, lines are written by Apple Speech."
        case .downloading:
            return "\(name) is downloading. Until it's ready, lines are written by Apple Speech."
        case .notDownloaded:
            return "\(name) isn't downloaded, so Apple Speech writes the transcript. Download it in Settings › Voice Models."
        case .failed(let message):
            return "\(name) couldn't start (\(message)), so Apple Speech writes the transcript."
        }
    }
}

// MARK: - Roster

private struct RosterPanel: View {
    @Environment(MeetingCoordinator.self) private var coordinator
    let session: MeetingSession
    @ViewState private var renaming: Participant?
    @ViewState private var newName = ""
    @ViewState private var enrolling: Participant?
    @ViewState private var enrollName = ""
    @ViewState private var enrollError: String?
    @ViewState private var busyKey: String?

    var body: some View {
        GroupBox("Participants") {
            if session.participants.isEmpty {
                Text("Speakers appear here once they've been heard for a few seconds.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(session.participants) { participant in
                        row(participant)
                    }
                }
                .padding(6)
            }
        }
        .alert("Rename Participant", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let key = renaming?.id { session.rename(participantKey: key, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("The new name is used for the rest of the transcript and the report.")
        }
        .alert("Save Voice to People", isPresented: Binding(get: { enrolling != nil }, set: { if !$0 { enrolling = nil } })) {
            TextField("Name", text: $enrollName)
            Button("Save") {
                if let participant = enrolling { enroll(participant, name: enrollName) }
                enrolling = nil
            }
            Button("Cancel", role: .cancel) { enrolling = nil }
        } message: {
            Text("Voiccenger will recognise this voice in future meetings.")
        }
        .alert("Couldn't Save Voice", isPresented: Binding(get: { enrollError != nil }, set: { if !$0 { enrollError = nil } }), presenting: enrollError) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text($0) }
    }

    private func row(_ participant: Participant) -> some View {
        HStack(spacing: 8) {
            ParticipantDot(colorIndex: participant.colorIndex)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(participant.displayName).lineLimit(1)
                    if participant.isEnrolled {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Enrolled voice")
                            .accessibilityLabel("Enrolled")
                    }
                }
                Text(detail(participant))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if busyKey == participant.id { ProgressView().controlSize(.small) }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Rename…") {
                newName = participant.displayName
                renaming = participant
            }
            if !participant.isEnrolled {
                Button("Save Voice to People…") {
                    enrollName = participant.displayName
                    enrolling = participant
                }
            }
        }
        .help("Right-click to rename\(participant.isEnrolled ? "" : " or save this voice")")
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            Button("Rename") {
                newName = participant.displayName
                renaming = participant
            }
        }
    }

    private func detail(_ p: Participant) -> String {
        var parts = [p.channel == .microphone ? "In room" : "Remote", Format.duration(p.speakingTime)]
        if let locale = p.localeID { parts.append(locale) }
        if let seat = p.seatAzimuthDegrees { parts.append(Format.degrees(seat)) }
        return parts.joined(separator: " · ")
    }

    private func enroll(_ participant: Participant, name: String) {
        busyKey = participant.id
        Task {
            defer { busyKey = nil }
            do {
                try await session.enrollParticipant(key: participant.id, name: name, into: coordinator.profileStore)
                await coordinator.reloadProfiles()
            } catch {
                enrollError = error.localizedDescription
            }
        }
    }
}

// MARK: - Inspector

private struct AttentionInspector: View {
    let session: MeetingSession
    @ViewState private var filter: AttentionItem.Kind?

    private var items: [AttentionItem] {
        session.attentionItems.filter { filter == nil || $0.kind == filter }.reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $filter) {
                Text("All").tag(AttentionItem.Kind?.none)
                Text("Corrections").tag(AttentionItem.Kind?.some(.correction))
                Text("Suggestions").tag(AttentionItem.Kind?.some(.suggestion))
                Text("Actions").tag(AttentionItem.Kind?.some(.actionItem))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            if items.isEmpty {
                ContentUnavailableView(
                    "Nothing to Flag Yet", systemImage: "checkmark.bubble",
                    description: Text("Corrections, suggestions and action items appear here as the meeting goes on."))
            } else {
                List(items) { item in
                    AttentionRow(item: item, speaker: session.roster.displayName(for: item.speakerKey))
                }
                .listStyle(.inset)
            }
        }
    }
}

struct AttentionRow: View {
    let item: AttentionItem
    let speaker: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(heading, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            Text(item.text)
            Text("\(speaker), \(Format.timestamp(item.time)): “\(item.utterance)”")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            if let detail = item.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }

    private var heading: String {
        switch item.kind {
        case .correction: "Did you mean…"
        case .suggestion: "Suggestion"
        case .actionItem: "Action item"
        }
    }

    private var symbol: String {
        switch item.kind {
        case .correction: "pencil.and.scribble"
        case .suggestion: "lightbulb"
        case .actionItem: "checklist"
        }
    }

    private var tint: Color {
        switch item.kind {
        case .correction: .orange
        case .suggestion: .yellow
        case .actionItem: .blue
        }
    }
}

// MARK: - Finished

private struct FinishedSessionView: View {
    @Environment(MeetingCoordinator.self) private var coordinator
    @Environment(NavigationModel.self) private var navigation
    let session: MeetingSession

    var body: some View {
        ContentUnavailableView {
            Label("Meeting Saved", systemImage: "checkmark.circle")
        } description: {
            if let meeting = session.meeting {
                Text("\(meeting.title) · \(Format.duration(meeting.duration)) · \(meeting.segments.count) lines")
            }
            if let error = session.reportError {
                Text("The report couldn't be generated: \(error)")
                    .foregroundStyle(.orange)
            }
        } actions: {
            if let meeting = session.meeting {
                Button("Open Report") {
                    coordinator.dismissFinishedSession()
                    navigation.showMeeting(meeting.id)
                }
                .buttonStyle(.borderedProminent)
            }
            Button("Done") { coordinator.dismissFinishedSession() }
        }
    }
}
