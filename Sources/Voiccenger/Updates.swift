import Foundation
import SwiftUI

#if Sparkle
import Combine
import Sparkle
#endif

/// How this build gets updates. Direct-download builds (the default `Sparkle` package trait) update
/// themselves with Sparkle; Mac App Store builds (`--disable-default-traits`) are updated by the App Store.
enum DistributionChannel {
    /// DMG from GitHub Releases, updated by Sparkle.
    case direct
    /// `swift run` / unbundled build: no feed URL, no updates.
    case development
    /// Mac App Store build: Sparkle is not linked.
    case appStore
}

#if Sparkle
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
    var channel: DistributionChannel { isAvailable ? .direct : .development }

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
}
#else
/// Mac App Store build: the App Store installs updates, so there is nothing to drive in-app.
@MainActor @Observable
final class AppUpdater {
    var isAvailable: Bool { false }
    var channel: DistributionChannel { .appStore }
}
#endif

extension AppUpdater {
    /// Marketing version and build number of the running app, e.g. "1.2.0 (42)".
    static var versionDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "development"
        let build = info["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}

/// "Check for Updates…" for the app menu and the menu bar extra; absent when this build can't update itself.
struct CheckForUpdatesButton: View {
    let updater: AppUpdater

    var body: some View {
        #if Sparkle
        if updater.isAvailable {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
        #endif
    }
}

/// Settings › General › Updates.
struct UpdateSettingsSection: View {
    @Bindable var updater: AppUpdater

    var body: some View {
        Section {
            LabeledContent("Version", value: AppUpdater.versionDescription)
            #if Sparkle
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
            #endif
        } header: {
            Text("Updates")
        } footer: {
            Text(footer).settingsFootnote()
        }
    }

    private var footer: String {
        switch updater.channel {
        case .direct:
            "Updates are downloaded from GitHub Releases and verified with Voiccenger's signing key before installing."
        case .development:
            "Updates are available in the installed app. Development builds don't update themselves."
        case .appStore:
            "Voiccenger is updated by the Mac App Store."
        }
    }
}
