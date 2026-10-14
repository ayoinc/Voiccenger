import Foundation
import VCAudio
import VCModels

/// Live rules for "the recording can't hear someone", shown while recording and kept with the meeting.
///
/// - A meeting app is active but the computer-audio channel has been silent (below `audibleDB`) for more than
///   `systemSilenceLimit`: the app is playing nothing, so there is nothing to record. Process taps capture what
///   the app plays before the Mac's volume and mute, so the fix is the app's own speaker volume.
/// - The microphone has delivered digital silence for more than `microphoneSilenceLimit`, or macOS reports the
///   input muted or at volume 0. Muting yourself inside the meeting app changes neither: Voiccenger reads the
///   input device directly, so it still records your voice.
///
/// Pure: measurements and time (session seconds) are passed in.
public struct CaptureHealthMonitor: Sendable {
    public static let systemSilenceLimit: TimeInterval = 20
    public static let microphoneSilenceLimit: TimeInterval = 5
    /// Quieter computer audio counts as silence (the quietest measured output, an HDMI monitor, carried speech
    /// at −41 dBFS RMS).
    public static let audibleDB = -70.0
    /// A microphone whose samples all stay below this (−120 dBFS) is digitally silent; real inputs always
    /// carry some noise.
    public static let digitalSilencePeak: Float = 1e-6

    /// Warnings in effect now.
    public private(set) var active: [CaptureWarning] = []
    /// Every warning raised so far, at its first occurrence (stored on the meeting).
    public private(set) var raised: [CaptureWarning] = []

    private var meetingApp: String?
    private var meetingAppSince: TimeInterval = 0
    private var systemAudibleAt: TimeInterval?
    private var microphoneSince: TimeInterval?
    private var microphoneSoundAt: TimeInterval?
    private var inputSilenced = false

    public init() {}

    /// The meeting app whose sound the computer-audio channel should carry (nil: none, rule off).
    public mutating func setMeetingApp(_ name: String?, at time: TimeInterval) {
        guard name != meetingApp else { return }
        meetingApp = name
        meetingAppSince = time
    }

    /// Computer-audio level over an interval ending at `time`.
    public mutating func system(rmsDB: Double, at time: TimeInterval) {
        if rmsDB > Self.audibleDB { systemAudibleAt = time }
    }

    /// Microphone peak magnitude over an interval ending at `time`.
    public mutating func microphone(peak: Float, at time: TimeInterval) {
        if microphoneSince == nil { microphoneSince = time }
        if peak > Self.digitalSilencePeak { microphoneSoundAt = time }
    }

    /// The input device's OS volume and mute (nil when unknown).
    public mutating func inputVolume(_ volume: InputVolume?) {
        inputSilenced = volume?.isSilenced ?? false
    }

    /// Re-evaluates the rules at `time`; returns whether `active` changed.
    @discardableResult
    public mutating func evaluate(at time: TimeInterval) -> Bool {
        var now: [CaptureWarning] = []
        if let app = meetingApp, time - max(meetingAppSince, systemAudibleAt ?? -.infinity) > Self.systemSilenceLimit {
            now.append(warning(.meetingAppSilent, app: app, at: time))
        }
        if inputSilenced {
            now.append(warning(.microphoneMuted, app: nil, at: time))
        } else if let since = microphoneSince, time - max(since, microphoneSoundAt ?? -.infinity) > Self.microphoneSilenceLimit {
            now.append(warning(.microphoneSilent, app: nil, at: time))
        }
        for w in now where !raised.contains(where: { $0.kind == w.kind }) { raised.append(w) }
        let changed = now.map(\.kind) != active.map(\.kind)
        if changed { active = now.map { w in active.first { $0.kind == w.kind } ?? w } }
        return changed
    }

    private func warning(_ kind: CaptureWarning.Kind, app: String?, at time: TimeInterval) -> CaptureWarning {
        CaptureWarning(kind: kind, message: Self.message(kind, app: app), time: time)
    }

    public static func message(_ kind: CaptureWarning.Kind, app: String?) -> String {
        switch kind {
        case .meetingAppSilent:
            let app = app ?? "The meeting app"
            return "\(app) is playing no sound. Voiccenger records what the app plays, so turn up \(app)'s own speaker volume (your Mac's volume can stay at 0)."
        case .microphoneSilent:
            return "The microphone is sending only silence, so nobody in the room is being recorded. Check the microphone's mute switch and the input chosen in Settings › Audio."
        case .microphoneMuted:
            return "macOS has muted the microphone input (or set its volume to 0), so nobody in the room is being recorded. Raise it in System Settings › Sound › Input."
        }
    }
}
