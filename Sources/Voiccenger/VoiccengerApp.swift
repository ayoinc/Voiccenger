import AppKit
import SwiftUI
import VCPipeline

/// SwiftUI's `@State` macro needs a compiler plugin missing from the Command Line Tools; the property wrapper works.
private typealias ViewState = SwiftUI.State

@main
struct VoiccengerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ViewState private var coordinator: MeetingCoordinator
    @ViewState private var enrollment: EnrollmentService
    @ViewState private var navigation = NavigationModel()
    @ViewState private var updater = AppUpdater()

    init() {
        let coordinator = MeetingCoordinator()
        _coordinator = State(initialValue: coordinator)
        _enrollment = State(initialValue: EnrollmentService(store: coordinator.profileStore))
        AppDelegate.coordinator = coordinator
    }

    var body: some Scene {
        WindowGroup("Voiccenger", id: WindowID.main) {
            RootView()
                .environment(coordinator)
                .environment(enrollment)
                .environment(navigation)
                .environment(coordinator.settings)
                .task { await coordinator.launch() }
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            MeetingCommands(coordinator: coordinator, navigation: navigation)
            CommandGroup(after: .appInfo) { CheckForUpdatesButton(updater: updater) }
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(coordinator)
                .environment(navigation)
                .environment(updater)
                .task { await coordinator.launch() }
        } label: {
            MenuBarLabel(coordinator: coordinator)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(coordinator)
                .environment(coordinator.settings)
                .environment(updater)
        }
    }
}

enum WindowID {
    static let main = "main"
}

/// Keeps the app running from the menu bar after its window closes, gives an unbundled `swift run` build a Dock
/// icon and focus like the bundled app, and never quits with a meeting unsaved.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `VoiccengerApp`; quitting waits for its meeting.
    static var coordinator: MeetingCoordinator?
    private var quitWindow: NSWindow?
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
        // `kill` and launchd stop processes with SIGTERM: quit through AppKit instead, so the meeting is saved.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSignal = source
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Every way of quitting (the menu, logout, Sparkle relaunching into an update, SIGTERM) comes here. While a
    /// meeting records or saves, quitting waits until it's stopped and saved (at most `TerminationFlow.cap`,
    /// then what's transcribed is saved), showing a progress window.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator = Self.coordinator else { return .terminateNow }
        // Asked again while already waiting: the pending reply covers it.
        if quitWindow != nil { return .terminateLater }
        guard coordinator.prepareToQuit() == .terminateLater else { return .terminateNow }
        showQuitWindow(coordinator)
        Task { @MainActor in
            await coordinator.finishBeforeQuitting()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func showQuitWindow(_ coordinator: MeetingCoordinator) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Saving Meeting"
        panel.contentView = NSHostingView(rootView: QuitProgressView(coordinator: coordinator))
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        quitWindow = panel
    }
}

/// Shown while quitting waits for the meeting to be saved.
private struct QuitProgressView: View {
    let coordinator: MeetingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Saving the meeting before Voiccenger quits…").font(.headline)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(detail(at: context.date))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Quit Now") { coordinator.quitNow() }
                    .help("Save what has been transcribed so far and quit")
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func detail(at date: Date) -> String {
        guard let remaining = coordinator.termination.remaining(now: date) else {
            return "Saving what has been transcribed…"
        }
        return "Transcribing the last lines. The report can be written later in Meetings. "
            + "If this takes longer than \(Format.duration(remaining.rounded(.up))), what's transcribed by then is saved."
    }
}

/// Sidebar destinations of the main window.
enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case live, meetings, people, spatial

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: "Live"
        case .meetings: "Meetings"
        case .people: "People"
        case .spatial: "Spatial"
        }
    }

    var symbol: String {
        switch self {
        case .live: "waveform"
        case .meetings: "list.bullet.rectangle"
        case .people: "person.2"
        case .spatial: "dot.radiowaves.left.and.right"
        }
    }
}

/// Window navigation shared by the main window and the menu bar extra.
@MainActor @Observable
final class NavigationModel {
    var sidebar: SidebarItem? = .live
    var meetingPath: [UUID] = []

    func showMeeting(_ id: UUID) {
        sidebar = .meetings
        meetingPath = [id]
    }
}

struct MeetingCommands: Commands {
    let coordinator: MeetingCoordinator
    let navigation: NavigationModel

    var body: some Commands {
        CommandMenu("Meeting") {
            Button(coordinator.session?.isActive == true ? "Stop Recording" : "Start Recording") {
                navigation.sidebar = .live
                Task { await coordinator.toggleRecording() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(coordinator.status == .finishing)

            Button("Start In-Person Meeting") {
                navigation.sidebar = .live
                Task { await coordinator.startRecording(kind: .inPerson) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(coordinator.session?.isActive == true)
        }
        CommandGroup(after: .sidebar) {
            ForEach(Array(SidebarItem.allCases.enumerated()), id: \.element) { index, item in
                Button(item.title) { navigation.sidebar = item }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
    }
}
