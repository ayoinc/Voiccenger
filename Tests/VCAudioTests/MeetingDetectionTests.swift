import Foundation
import Testing
import VCModels

@testable import VCAudio

private let zoom = MeetingAppCatalog.app(forBundleID: "us.zoom.xos")!
private let chrome = MeetingAppCatalog.app(forBundleID: "com.google.Chrome")!

private func seen(_ apps: MeetingApp...) -> [MeetingDetectionStateMachine.Observation] {
    apps.map { .init(app: $0, processIDs: [100]) }
}

private func names(_ events: [MeetingDetectionEvent]) -> [String] {
    events.map {
        switch $0 {
        case .meetingStarted(let m): "start \(m.app.displayName)"
        case .meetingEnded(let m): "end \(m.app.displayName)"
        case .conversationDetected: "conversation"
        }
    }
}

@Suite("Meeting detection state machine")
struct MeetingDetectionStateMachineTests {
    @Test("A meeting starts only after 2 s of continuous microphone use")
    func startDebounce() {
        var m = MeetingDetectionStateMachine()
        #expect(m.update(seen(zoom), at: 0).isEmpty)
        #expect(m.update(seen(zoom), at: 1.5).isEmpty)
        let events = m.update(seen(zoom), at: 2.0)
        #expect(names(events) == ["start Zoom"])
        #expect(m.update(seen(zoom), at: 3.5).isEmpty, "a started meeting is reported once")
        #expect(m.activeMeetings.map(\.app.bundleID) == ["us.zoom.xos"])
    }

    @Test("A flap before the start delay restarts the count")
    func flapResetsStart() {
        var m = MeetingDetectionStateMachine()
        _ = m.update(seen(zoom), at: 0)
        _ = m.update(seen(zoom), at: 1.5)
        #expect(m.update([], at: 1.8).isEmpty)
        #expect(m.update(seen(zoom), at: 2.1).isEmpty, "only 0 s of the new run")
        #expect(m.update(seen(zoom), at: 3.6).isEmpty)
        #expect(names(m.update(seen(zoom), at: 4.2)) == ["start Zoom"])
    }

    @Test("A meeting ends only after 5 s without microphone use; shorter gaps are bridged")
    func endDebounce() {
        var m = MeetingDetectionStateMachine()
        _ = m.update(seen(zoom), at: 0)
        _ = m.update(seen(zoom), at: 2)  // started
        #expect(m.update([], at: 3).isEmpty)
        #expect(m.update([], at: 6).isEmpty, "4 s absent")
        #expect(m.update(seen(zoom), at: 6.5).isEmpty, "back before the end delay: still the same meeting")
        #expect(m.update([], at: 10).isEmpty)
        let events = m.update([], at: 11.5)
        #expect(names(events) == ["end Zoom"])
        #expect(m.activeMeetings.isEmpty)
        #expect(m.update([], at: 20).isEmpty, "ended once")
    }

    @Test("The ended event carries the same meeting that started")
    func endedMatchesStarted() throws {
        var m = MeetingDetectionStateMachine()
        _ = m.update([.init(app: zoom, processIDs: [42, 7])], at: 0)
        let start = try #require(m.update([.init(app: zoom, processIDs: [7, 42])], at: 2, date: Date(timeIntervalSince1970: 1)).first)
        let end = try #require(m.update([], at: 7).first)
        guard case .meetingStarted(let started) = start, case .meetingEnded(let ended) = end else {
            Issue.record("unexpected events \(start) \(end)")
            return
        }
        #expect(started == ended)
        #expect(started.processIDs == [7, 42])
        #expect(started.startedAt == Date(timeIntervalSince1970: 1))
    }

    @Test("Several apps are tracked independently")
    func multipleApps() {
        var m = MeetingDetectionStateMachine()
        _ = m.update(seen(zoom), at: 0)
        _ = m.update(seen(zoom, chrome), at: 1)
        #expect(names(m.update(seen(zoom, chrome), at: 2)) == ["start Zoom"])
        #expect(names(m.update(seen(chrome), at: 3)) == ["start Google Chrome"])
        #expect(m.update(seen(chrome), at: 6).isEmpty)
        #expect(names(m.update(seen(chrome), at: 7)) == ["end Zoom"])
        #expect(m.activeMeetings.map(\.app.displayName) == ["Google Chrome"])
    }

    @Test("Helper processes and companion daemons count as one meeting of their app")
    func companionsMerge() {
        let observations = MeetingDetectionStateMachine.observations(from: [
            (bundleID: "com.apple.FaceTime", pid: 10),
            (bundleID: "com.apple.avconferenced", pid: 11),
            (bundleID: "com.google.Chrome.helper", pid: 20),
            (bundleID: "com.google.Chrome.helper.renderer", pid: 21),
            (bundleID: "com.example.dictation", pid: 30),
        ])
        var m = MeetingDetectionStateMachine()
        _ = m.update(observations, at: 0)
        let events = m.update(observations, at: 2)
        #expect(names(events) == ["start FaceTime", "start Google Chrome"])
        let pids = m.activeMeetings.map(\.processIDs)
        #expect(pids == [[10, 11], [20, 21]])
    }
}

@Suite("Meeting app catalog")
struct MeetingAppCatalogTests {
    @Test("Helper bundle IDs map to their parent app; the longest catalog ID wins")
    func helperMapping() {
        #expect(MeetingAppCatalog.app(forBundleID: "com.google.Chrome.helper")?.displayName == "Google Chrome")
        #expect(MeetingAppCatalog.app(forBundleID: "com.google.Chrome.helper.Renderer")?.bundleID == "com.google.Chrome")
        #expect(MeetingAppCatalog.app(forBundleID: "com.microsoft.teams2.helper")?.bundleID == "com.microsoft.teams2")
        #expect(MeetingAppCatalog.app(forBundleID: "com.microsoft.teams")?.bundleID == "com.microsoft.teams")
        #expect(MeetingAppCatalog.app(forBundleID: "us.zoom.xos")?.kind == .native)
        #expect(MeetingAppCatalog.app(forBundleID: "com.apple.WebKit.GPU")?.displayName == "Safari")
        #expect(MeetingAppCatalog.app(forBundleID: "US.ZOOM.XOS")?.displayName == "Zoom")
    }

    @Test("Look-alike bundle IDs don't match")
    func noFalsePrefixes() {
        #expect(MeetingAppCatalog.app(forBundleID: "com.google.Chromeium") == nil)
        #expect(MeetingAppCatalog.app(forBundleID: "us.zoom") == nil)
        #expect(MeetingAppCatalog.app(forBundleID: "com.apple.Music") == nil)
    }
}
