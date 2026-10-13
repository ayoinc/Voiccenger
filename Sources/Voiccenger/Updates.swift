import Combine
import Foundation
import Sparkle
import SwiftUI

/// SwiftUI's `@State` macro needs a compiler plugin missing from the Command Line Tools; the property wrapper works.
private typealias ViewState = SwiftUI.State

/// Sparkle updater for the bundled app. Updates come from the appcast attached to the latest
/// GitHub Release (`SUFeedURL`) and must carry an EdDSA signature matching `SUPublicEDKey`.
///
/// An unbundled `swift run` build has no feed URL in its Info.plist, so the updater stays off
/// there instead of failing on launch.
@MainActor @Observable
final class AppUpdater {
    private let controller: SPUStandardUpdaterController?
    private var observation: AnyCancellable?

    /// Whether "Check for Updates…" can run now (false while a check is already in progress).
    private(set) var canCheckForUpdates = false

    var isAvailable: Bool { controller != nil }

    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                controller?.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get {
            access(keyPath: \.automaticallyDownloadsUpdates)
            return controller?.updater.automaticallyDownloadsUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyDownloadsUpdates) {
                controller?.updater.automaticallyDownloadsUpdates = newValue
            }
        }
    }

    var lastUpdateCheckDate: Date? { controller?.updater.lastUpdateCheckDate }

    init(bundle: Bundle = .main) {
        let info = bundle.infoDictionary ?? [:]
        guard info["SUFeedURL"] is String, info["SUPublicEDKey"] is String else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.canCheckForUpdates = value }
            }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Marketing version and build number of the running app, e.g. "1.2.0 (42)".
    static var versionDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "development"
        let build = info["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}

/// "Check for Updates…" for the app menu and the menu bar extra.
struct CheckForUpdatesButton: View {
    let updater: AppUpdater

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}

/// Settings › General › Updates.
struct UpdateSettingsSection: View {
    @Bindable var updater: AppUpdater

    var body: some View {
        Section {
            LabeledContent("Version", value: AppUpdater.versionDescription)
            if updater.isAvailable {
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
                Toggle("Automatically download and install updates", isOn: $updater.automaticallyDownloadsUpdates)
                    .disabled(!updater.automaticallyChecksForUpdates)
                HStack {
                    if let last = updater.lastUpdateCheckDate {
                        Text("Last checked \(last, format: .relative(presentation: .named))")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    CheckForUpdatesButton(updater: updater)
                }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text(
                updater.isAvailable
                    ? "Updates are downloaded from GitHub Releases and verified with Voiccenger's signing key before installing."
                    : "Updates are available in the installed app. Development builds don't update themselves."
            )
            .settingsFootnote()
        }
    }
}
