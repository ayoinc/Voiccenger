import SwiftUI
import VCPipeline

struct RootView: View {
    @Environment(MeetingCoordinator.self) private var coordinator
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView {
            List(selection: $navigation.sidebar) {
                Section {
                    ForEach(SidebarItem.allCases) { item in
                        Label(item.title, systemImage: item.symbol)
                            .badge(badge(for: item))
                            .tag(item)
                    }
                }
                if !coordinator.recentMeetings.isEmpty {
                    Section("Recent") {
                        ForEach(coordinator.recentMeetings) { meeting in
                            Button {
                                navigation.showMeeting(meeting.id)
                            } label: {
                                Label(meeting.title, systemImage: meeting.kind == .online ? "video" : "person.3")
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .help(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            switch navigation.sidebar ?? .live {
            case .live: LiveView()
            case .meetings: MeetingsView()
            case .people: PeopleView()
            case .spatial: SpatialView()
            }
        }
        .sheet(
            item: Binding(get: { coordinator.pendingRecording }, set: { if $0 == nil { coordinator.cancelPendingRecording() } })
        ) { _ in
            RecordingConsentSheet()
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { coordinator.lastError != nil }, set: { if !$0 { coordinator.lastError = nil } }),
            presenting: coordinator.lastError
        ) { _ in
            Button("OK", role: .cancel) { coordinator.lastError = nil }
        } message: { message in
            Text(message)
        }
    }

    private func badge(for item: SidebarItem) -> Text? {
        switch item {
        case .live where coordinator.isRecording: Text("REC")
        case .meetings where !coordinator.meetings.isEmpty: Text("\(coordinator.meetings.count)")
        case .people where !coordinator.profiles.isEmpty: Text("\(coordinator.profiles.count)")
        default: nil
        }
    }
}

struct MenuBarLabel: View {
    let coordinator: MeetingCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let status = coordinator.status
        icon(status)
            .accessibilityLabel("Voiccenger: \(StatusSymbol.label(for: status))")
            .onChange(of: coordinator.pendingRecording) { _, request in
                // A recording asked for from the menu bar or a notification needs a window for the consent sheet.
                guard request != nil, !MainWindow.isVisible else { return }
                openWindow(id: WindowID.main)
                NSApp.activate()
            }
    }

    /// Red while recording (menu bar symbols are otherwise monochrome templates).
    @ViewBuilder
    private func icon(_ status: MeetingCoordinator.Status) -> some View {
        if status == .recording,
            let symbol = NSImage(systemSymbolName: StatusSymbol.name(for: status), accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white, .systemRed]))
        {
            Image(nsImage: symbol)
        } else {
            Image(systemName: StatusSymbol.name(for: status))
        }
    }
}

enum MainWindow {
    /// Whether a main window is on screen (SwiftUI identifies them "<WindowGroup id>-AppWindow-<n>").
    @MainActor static var isVisible: Bool {
        NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue.hasPrefix(WindowID.main) == true }
    }
}

struct MenuBarContent: View {
    @Environment(MeetingCoordinator.self) private var coordinator
    @Environment(NavigationModel.self) private var navigation
    @Environment(AppUpdater.self) private var updater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)
        Divider()
        if coordinator.session?.isActive == true {
            Button("Stop Recording") { Task { await coordinator.stopRecording() } }
                .keyboardShortcut("r")
                .disabled(coordinator.status == .finishing)
        } else {
            if let detected = coordinator.detectedMeeting {
                Button("Record \(detected.app.displayName) Meeting") {
                    Task { await coordinator.startRecording(kind: .online, detected: detected) }
                }
                .keyboardShortcut("r")
            }
            Button("Start In-Person Meeting") { Task { await coordinator.startRecording(kind: .inPerson) } }
        }
        Divider()
        Button("Open Voiccenger") { showWindow(.live) }
            .keyboardShortcut("o")
        if !coordinator.recentMeetings.isEmpty {
            Menu("Recent Meetings") {
                ForEach(coordinator.recentMeetings) { meeting in
                    Button("\(meeting.title) — \(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))") {
                        showWindow(.meetings)
                        navigation.showMeeting(meeting.id)
                    }
                }
            }
        }
        Divider()
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        if updater.isAvailable {
            CheckForUpdatesButton(updater: updater)
        }
        Button("Quit Voiccenger") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch coordinator.status {
        case .idle: return "Not recording"
        case .detected:
            if let app = coordinator.detectedMeeting?.app.displayName { return "\(app) meeting detected" }
            return "Conversation detected"
        case .recording:
            if let start = coordinator.session?.startedAt {
                return "Recording since \(start.formatted(date: .omitted, time: .shortened))"
            }
            return "Starting…"
        case .finishing: return "Writing report…"
        }
    }

    private func showWindow(_ item: SidebarItem) {
        navigation.sidebar = item
        openWindow(id: WindowID.main)
        NSApp.activate()
    }
}
