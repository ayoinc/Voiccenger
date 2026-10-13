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

    init() {
        let coordinator = MeetingCoordinator()
        _coordinator = State(initialValue: coordinator)
        _enrollment = State(initialValue: EnrollmentService(store: coordinator.profileStore))
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
        .commands { MeetingCommands(coordinator: coordinator, navigation: navigation) }

        MenuBarExtra {
            MenuBarContent()
                .environment(coordinator)
                .environment(navigation)
                .task { await coordinator.launch() }
        } label: {
            MenuBarLabel(status: coordinator.status)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(coordinator)
                .environment(coordinator.settings)
        }
    }
}

enum WindowID {
    static let main = "main"
}

/// Keeps the app running from the menu bar after its window closes, and gives an unbundled
/// `swift run` build a Dock icon and focus like the bundled app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
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
