import Foundation
import VCModels

/// Conferencing apps and browsers whose microphone use signals a meeting.
public enum MeetingAppCatalog {
    public static let all: [MeetingApp] = [
        MeetingApp(bundleID: "us.zoom.xos", displayName: "Zoom", kind: .native),
        MeetingApp(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams", kind: .native),
        MeetingApp(bundleID: "com.microsoft.teams", displayName: "Microsoft Teams", kind: .native),
        MeetingApp(bundleID: "com.cisco.webexmeetingsapp", displayName: "Webex", kind: .native),
        MeetingApp(bundleID: "Cisco-Systems.Spark", displayName: "Webex", kind: .native),
        MeetingApp(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack", kind: .native),
        MeetingApp(bundleID: "com.apple.FaceTime", displayName: "FaceTime", kind: .native),
        // FaceTime's audio runs in this daemon rather than the app process.
        MeetingApp(bundleID: "com.apple.avconferenced", displayName: "FaceTime", kind: .native),
        MeetingApp(bundleID: "com.hnc.Discord", displayName: "Discord", kind: .native),
        MeetingApp(bundleID: "com.skype.skype", displayName: "Skype", kind: .native),
        MeetingApp(bundleID: "com.logmein.GoToMeeting", displayName: "GoTo Meeting", kind: .native),
        MeetingApp(bundleID: "com.google.Chrome", displayName: "Google Chrome", kind: .browser),
        MeetingApp(bundleID: "com.apple.Safari", displayName: "Safari", kind: .browser),
        // Safari captures the microphone from its WebKit GPU process.
        MeetingApp(bundleID: "com.apple.WebKit.GPU", displayName: "Safari", kind: .browser),
        MeetingApp(bundleID: "com.microsoft.edgemac", displayName: "Microsoft Edge", kind: .browser),
        MeetingApp(bundleID: "company.thebrowser.Browser", displayName: "Arc", kind: .browser),
        MeetingApp(bundleID: "org.mozilla.firefox", displayName: "Firefox", kind: .browser),
        MeetingApp(bundleID: "com.brave.Browser", displayName: "Brave", kind: .browser),
    ]

    /// The app for a bundle ID, including helper processes (`com.google.Chrome.helper` → Chrome).
    /// The longest matching catalog ID wins (`com.microsoft.teams2.x` → `com.microsoft.teams2`).
    public static func app(forBundleID bundleID: String) -> MeetingApp? {
        let id = bundleID.lowercased()
        var best: MeetingApp?
        for app in all {
            let candidate = app.bundleID.lowercased()
            guard id == candidate || id.hasPrefix(candidate + ".") else { continue }
            if app.bundleID.count > (best?.bundleID.count ?? -1) { best = app }
        }
        return best
    }
}
