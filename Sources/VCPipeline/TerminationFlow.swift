import Foundation

/// What happens when the app is asked to quit (by the user, at logout, or by Sparkle relaunching into an update)
/// while a meeting is recording or being saved: quitting waits until the meeting is stopped and saved, for at
/// most `cap` seconds, after which whatever has been transcribed is saved and the app quits.
///
/// Pure state; `MeetingCoordinator` performs the actions and AppKit's `applicationShouldTerminate` gets the reply.
public struct TerminationFlow: Sendable, Hashable {
    /// The answer to `applicationShouldTerminate`.
    public enum Reply: Sendable, Hashable {
        case terminateNow
        /// Reply later, once `Action.quit` comes.
        case terminateLater
    }

    public enum Action: Sendable, Hashable {
        /// Stop the recording and save the meeting (the report can be written later).
        case stopAndSave
        /// The meeting is already stopping: wait for it to be saved.
        case awaitSave
        /// Waiting is over: save what has been transcribed so far.
        case saveSnapshot
        /// The meeting is saved (or couldn't be): let the app quit.
        case quit
    }

    public enum Phase: Sendable, Hashable {
        case running
        /// Stopping and saving the meeting, until `deadline`.
        case saving(deadline: Date)
        /// Saving the transcript as it stands.
        case savingSnapshot
        /// Nothing more to save; the app may quit.
        case done
    }

    /// Seconds quitting waits for the meeting before saving what's there.
    public let cap: TimeInterval
    public private(set) var phase: Phase = .running

    public init(cap: TimeInterval = 120) {
        self.cap = cap
    }

    /// The app was asked to quit with the session in `state` (nil: no session).
    public mutating func requestQuit(session state: MeetingSession.State?, now: Date) -> (reply: Reply, action: Action?) {
        switch phase {
        case .done: return (.terminateNow, nil)
        case .saving, .savingSnapshot: return (.terminateLater, nil)
        case .running: break
        }
        switch state {
        case .starting?, .recording?:
            phase = .saving(deadline: now.addingTimeInterval(cap))
            return (.terminateLater, .stopAndSave)
        case .finishing?:
            phase = .saving(deadline: now.addingTimeInterval(cap))
            return (.terminateLater, .awaitSave)
        case .idle?, .finished?, .failed?, nil:
            phase = .done
            return (.terminateNow, nil)
        }
    }

    /// The meeting was saved, or saving it failed (its journal stays for recovery): nothing more to wait for.
    public mutating func saveEnded() -> Action? {
        switch phase {
        case .saving, .savingSnapshot:
            phase = .done
            return .quit
        case .running, .done:
            return nil
        }
    }

    /// Time passed: at the deadline, save what's there.
    public mutating func tick(now: Date) -> Action? {
        guard case .saving(let deadline) = phase, now >= deadline else { return nil }
        phase = .savingSnapshot
        return .saveSnapshot
    }

    /// The user chose not to wait any longer.
    public mutating func quitNow() -> Action? {
        guard case .saving = phase else { return nil }
        phase = .savingSnapshot
        return .saveSnapshot
    }

    /// Seconds left before the snapshot is saved, while waiting.
    public func remaining(now: Date) -> TimeInterval? {
        guard case .saving(let deadline) = phase else { return nil }
        return max(0, deadline.timeIntervalSince(now))
    }
}
