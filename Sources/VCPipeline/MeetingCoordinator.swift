import Foundation
import Observation
import UserNotifications
import VCAudio
import VCModels
import VCSpeakers
import VCTranscription

/// App-level owner of meeting detection, the active `MeetingSession`, saved meetings and voice profiles.
///
/// Online meetings are detected when a conferencing app starts using the microphone; depending on settings
/// they are recorded automatically or announced with a notification offering to start. In-person meetings
/// are detected from sustained conversation on the microphone (only when the user enabled it) and are always
/// announced rather than recorded. A session started for a detected online meeting stops when the app
/// releases the microphone. Until the user acknowledges telling participants they're being recorded, every
/// start waits for confirmation (`pendingRecording`) and nothing is recorded automatically.
@MainActor @Observable
public final class MeetingCoordinator {
    public enum Status: Sendable, Hashable {
        case idle
        /// A meeting (online) or conversation (in person) was detected and isn't being recorded.
        case detected
        case recording
        case finishing
    }

    /// A recording waiting for the user to confirm they'll tell the participants.
    public struct RecordingRequest: Sendable, Hashable, Identifiable {
        public let id = UUID()
        public let kind: MeetingKind?
        public let detected: DetectedMeeting?
    }

    public let settings: AppSettings
    public let paths: AppPaths
    public let meetingStore: MeetingStore
    public let profileStore: SpeakerProfileStore

    public private(set) var session: MeetingSession?
    /// Conferencing app currently using the microphone.
    public private(set) var detectedMeeting: DetectedMeeting?
    /// When sustained in-person conversation was last detected (cleared when a recording starts).
    public private(set) var conversationDetectedAt: Date?
    /// Saved meetings, newest first.
    public private(set) var meetings: [Meeting] = []
    public private(set) var profiles: [SpeakerProfile] = []
    /// The most recent user-facing failure (start/stop/storage).
    public var lastError: String?
    /// Set when a recording was requested before `AppSettings.recordingConsentAcknowledged`; the app asks the
    /// user to confirm (`confirmPendingRecording`) or cancel (`cancelPendingRecording`).
    public private(set) var pendingRecording: RecordingRequest?

    public var status: Status {
        if let session {
            switch session.state {
            case .starting, .recording: return .recording
            case .finishing: return .finishing
            default: break
            }
        }
        return detectedMeeting != nil || conversationDetectedAt != nil ? .detected : .idle
    }

    public var isRecording: Bool { status == .recording }
    public var recentMeetings: [Meeting] { Array(meetings.prefix(5)) }

    /// Recording would send audio to Deepgram: it's the meeting's voice model, or an enrolled person's (chosen
    /// or calibrated) voice model, whose lines are re-transcribed with it.
    public var sendsAudioToDeepgram: Bool {
        settings.speechEngine == .deepgram
            || profiles.contains { ($0.voice.preferredEngine ?? $0.voice.calibration?.best?.engine) == .deepgram }
    }

    @ObservationIgnored private var detector: MeetingDetector?
    @ObservationIgnored private var detectorTask: Task<Void, Never>?
    @ObservationIgnored private var monitor: MicrophoneSource?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var notifier: MeetingNotifier?
    @ObservationIgnored private var launched = false
    @ObservationIgnored private var prewarmTask: Task<Void, Never>?

    public init(settings: AppSettings = AppSettings(), paths: AppPaths = .default) {
        self.settings = settings
        self.paths = paths
        self.meetingStore = MeetingStore(directory: paths.meetings)
        self.profileStore = SpeakerProfileStore(directory: paths.profiles)
    }

    /// Loads saved data, sets up notifications and starts detection per settings. Idempotent.
    public func launch() async {
        guard !launched else { return }
        launched = true
        notifier = MeetingNotifier.makeIfAvailable { [weak self] action in
            Task { @MainActor in self?.handleNotification(action) }
        }
        await notifier?.requestAuthorization()
        await reloadMeetings()
        await reloadProfiles()
        applySettings()
        observeSettings()
        prepareSpeechEngine()
        observeSpeechEngine()
    }

    // MARK: - Recording

    /// Starts recording. Without arguments: the detected online meeting if any, else an in-person meeting.
    /// Until the user has acknowledged telling participants, this only sets `pendingRecording`.
    public func startRecording(kind: MeetingKind? = nil, detected: DetectedMeeting? = nil) async {
        guard session?.isActive != true else { return }
        guard settings.recordingConsentAcknowledged else {
            pendingRecording = RecordingRequest(kind: kind, detected: detected)
            return
        }
        await beginRecording(kind: kind, detected: detected)
    }

    /// Starts the pending recording after the user confirmed they'll tell participants. `remember` stops
    /// future recordings from asking (and allows automatic recording of detected meetings).
    public func confirmPendingRecording(remember: Bool) async {
        guard let request = pendingRecording else { return }
        pendingRecording = nil
        if remember { settings.recordingConsentAcknowledged = true }
        guard session?.isActive != true else { return }
        await beginRecording(kind: request.kind, detected: request.detected)
    }

    public func cancelPendingRecording() {
        pendingRecording = nil
    }

    private func beginRecording(kind: MeetingKind?, detected: DetectedMeeting?) async {
        let meeting = detected ?? (kind == .inPerson ? nil : detectedMeeting)
        let resolvedKind = kind ?? (meeting != nil ? .online : .inPerson)
        stopMonitor()
        notifier?.removeAll()
        conversationDetectedAt = nil
        lastError = nil
        await reloadProfiles()
        let config = settings.sessionConfig(kind: resolvedKind, detected: meeting, meetingsDirectory: paths.meetings)
        let session = MeetingSession(config: config, profiles: profiles)
        self.session = session
        do {
            try await session.start()
        } catch {
            lastError = error.localizedDescription
            self.session = nil
            applySettings()
        }
    }

    /// Stops the active recording, saves the meeting and returns it.
    @discardableResult
    public func stopRecording() async -> Meeting? {
        guard let session, session.state == .recording else { return nil }
        defer { applySettings() }
        do {
            let meeting = try await session.stop()
            meetings.removeAll { $0.id == meeting.id }
            meetings.insert(meeting, at: 0)
            return meeting
        } catch {
            lastError = "The meeting couldn't be saved: \(error.localizedDescription)"
            return nil
        }
    }

    public func toggleRecording() async {
        if session?.isActive == true {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    /// Forgets a finished session so the Live view returns to its idle state.
    public func dismissFinishedSession() {
        guard let session, !session.isActive else { return }
        self.session = nil
    }

    // MARK: - Storage

    public func reloadMeetings() async {
        do {
            meetings = try await meetingStore.all()
        } catch {
            lastError = "Saved meetings couldn't be read: \(error.localizedDescription)"
        }
    }

    public func save(_ meeting: Meeting) async {
        do {
            try await meetingStore.save(meeting)
            if let i = meetings.firstIndex(where: { $0.id == meeting.id }) { meetings[i] = meeting }
        } catch {
            lastError = "The meeting couldn't be saved: \(error.localizedDescription)"
        }
    }

    public func deleteMeeting(id: UUID) async {
        do {
            try await meetingStore.delete(id: id)
            meetings.removeAll { $0.id == id }
        } catch {
            lastError = "The meeting couldn't be deleted: \(error.localizedDescription)"
        }
    }

    /// Meetings whose report is being written right now.
    public private(set) var generatingReports: Set<UUID> = []

    /// Writes (or rewrites) a saved meeting's report with the selected engine and saves it.
    public func generateReport(for meetingID: UUID) async {
        guard !generatingReports.contains(meetingID),
            let meeting = meetings.first(where: { $0.id == meetingID })
        else { return }
        guard let choice = ReportWriter.engine(preferring: settings.engine) else {
            lastError = ReportWriter.ReportWriterError.noEngine.localizedDescription
            return
        }
        generatingReports.insert(meetingID)
        defer { generatingReports.remove(meetingID) }
        do {
            let report = try await ReportWriter.report(for: meeting, engine: choice.engine, title: meeting.title)
            // The meeting may have been edited or deleted while the report was being written.
            guard var latest = meetings.first(where: { $0.id == meetingID }) else { return }
            latest.report = report
            await save(latest)
        } catch {
            lastError = "The report couldn't be generated: \(error.localizedDescription)"
        }
    }

    /// Renames a participant of a saved meeting; the transcript and report use the new name.
    public func renameParticipant(_ key: String, to name: String, inMeeting meetingID: UUID) async {
        guard let trimmed = name.nonEmpty, var meeting = meetings.first(where: { $0.id == meetingID }),
            let i = meeting.participants.firstIndex(where: { $0.id == key })
        else { return }
        let old = meeting.participants[i].displayName
        meeting.participants[i].displayName = trimmed
        if var report = meeting.report {
            for j in report.participantSummaries.indices where report.participantSummaries[j].name == old {
                report.participantSummaries[j].name = trimmed
            }
            for j in report.actionItems.indices where report.actionItems[j].owner == old {
                report.actionItems[j].owner = trimmed
            }
            for j in report.corrections.indices where report.corrections[j].speaker == old {
                report.corrections[j].speaker = trimmed
            }
            for j in report.topics.indices {
                report.topics[j].speakers = report.topics[j].speakers.map { $0 == old ? trimmed : $0 }
            }
            meeting.report = report
        }
        await save(meeting)
    }

    public func renameMeeting(_ meetingID: UUID, to title: String) async {
        guard let trimmed = title.nonEmpty, var meeting = meetings.first(where: { $0.id == meetingID }) else { return }
        meeting.title = trimmed
        meeting.report?.title = trimmed
        await save(meeting)
    }

    public func reloadProfiles() async {
        profiles = await profileStore.all().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func deleteProfile(id: UUID) async {
        do {
            try await profileStore.delete(id: id)
            await reloadProfiles()
        } catch {
            lastError = "The voice couldn't be deleted: \(error.localizedDescription)"
        }
    }

    // MARK: - Detection

    /// Starts or stops meeting detection and the in-person conversation monitor to match settings.
    public func applySettings() {
        if settings.autoDetectMeetings {
            startDetector()
        } else {
            stopDetector()
            detectedMeeting = nil
        }
        if settings.inPersonDetection && session?.isActive != true {
            startMonitor()
        } else {
            stopMonitor()
            if !settings.inPersonDetection { conversationDetectedAt = nil }
        }
    }

    private func observeSettings() {
        withObservationTracking {
            _ = settings.autoDetectMeetings
            _ = settings.inPersonDetection
            _ = settings.inputDeviceUID
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // A device change must restart the monitor on the new input.
                self.stopMonitor()
                self.applySettings()
                self.observeSettings()
            }
        }
    }

    // MARK: - Voice model

    /// Loads and warms the selected voice model in the background (downloading it first when missing and
    /// automatic downloads are on), so meetings get its text from the first line. Apple needs no preparation.
    private func prepareSpeechEngine() {
        prewarmTask?.cancel()
        let engine = settings.speechEngine
        guard engine != .apple else { return }
        let download = settings.downloadModelsAutomatically
        let library = SpeechModelLibrary.shared
        prewarmTask = Task { [weak self] in
            do {
                let status = await library.status(engine)
                if !SessionVoices.availableEngines([engine: status]).contains(engine) {
                    guard download else { return }
                    try await library.download(engine)
                }
                try Task.checkCancellation()
                try await library.prewarm(engine)
            } catch is CancellationError {
                return
            } catch {
                self?.lastError =
                    "\(SpeechModelLibrary.info(engine).displayName) couldn't be prepared: \(error.localizedDescription)"
            }
        }
    }

    private func observeSpeechEngine() {
        withObservationTracking {
            _ = settings.speechEngine
            _ = settings.downloadModelsAutomatically
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.prepareSpeechEngine()
                self.observeSpeechEngine()
            }
        }
    }

    private func startDetector() {
        guard detector == nil else { return }
        let detector = MeetingDetector()
        self.detector = detector
        let events = detector.events()
        detectorTask = Task { [weak self] in
            for await event in events { await self?.handle(event) }
        }
    }

    private func stopDetector() {
        detector?.stop()
        detector = nil
        detectorTask?.cancel()
        detectorTask = nil
    }

    /// Lightweight microphone listener feeding the conversation detector while nothing is recording.
    private func startMonitor() {
        guard monitor == nil else { return }
        let mic = MicrophoneSource(deviceUID: settings.inputDeviceUID, clock: SessionClock(), chunkDuration: 0.25)
        monitor = mic
        let conversation = ConversationDetector()
        monitorTask = Task { [weak self] in
            do {
                let stream = try await mic.start()
                for await chunk in stream {
                    if let event = conversation.ingest(chunk) {
                        await self?.handle(event)
                        conversation.reset()
                    }
                }
            } catch {
                self?.monitorFailed(error)
            }
        }
    }

    private func stopMonitor() {
        guard let monitor else { return }
        self.monitor = nil
        monitorTask?.cancel()
        monitorTask = nil
        Task { await monitor.stop() }
    }

    private func monitorFailed(_ error: Error) {
        monitor = nil
        monitorTask = nil
        lastError = "In-person meeting detection couldn't use the microphone: \(error.localizedDescription)"
    }

    private func handle(_ event: MeetingDetectionEvent) async {
        switch event {
        case .meetingStarted(let meeting):
            detectedMeeting = meeting
            guard session?.isActive != true else { return }
            if settings.autoRecordOnline, settings.recordingConsentAcknowledged {
                await startRecording(kind: .online, detected: meeting)
            } else {
                notifier?.postMeetingDetected(appName: meeting.app.displayName)
            }

        case .meetingEnded(let meeting):
            guard detectedMeeting?.app.bundleID == meeting.app.bundleID else { return }
            detectedMeeting = nil
            if let request = pendingRecording,
                request.detected?.app.bundleID == meeting.app.bundleID || (request.detected == nil && request.kind == .online)
            {
                // The meeting the user was asked about is over.
                pendingRecording = nil
            }
            notifier?.removeAll()
            if let session, session.state == .recording,
                session.config.detectedMeeting?.app.bundleID == meeting.app.bundleID
            {
                await stopRecording()
            }

        case .conversationDetected(let date):
            guard session?.isActive != true, detectedMeeting == nil else { return }
            conversationDetectedAt = date
            notifier?.postConversationDetected()
        }
    }

    private func handleNotification(_ action: MeetingNotifier.Action) {
        switch action {
        case .startOnline:
            Task { await startRecording(kind: .online) }
        case .startInPerson:
            Task { await startRecording(kind: .inPerson) }
        }
    }
}

/// Posts "meeting detected" notifications with a Start action and reports when the user picks it.
/// Only available inside an app bundle (UserNotifications needs a bundle identifier).
final class MeetingNotifier: NSObject, UNUserNotificationCenterDelegate, Sendable {
    enum Action: Sendable {
        case startOnline
        case startInPerson
    }

    private static let onlineCategory = "MEETING_DETECTED"
    private static let inPersonCategory = "CONVERSATION_DETECTED"
    private static let startAction = "START_RECORDING"

    private let onAction: @Sendable (Action) -> Void

    private init(onAction: @escaping @Sendable (Action) -> Void) {
        self.onAction = onAction
    }

    static func makeIfAvailable(onAction: @escaping @Sendable (Action) -> Void) -> MeetingNotifier? {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        let notifier = MeetingNotifier(onAction: onAction)
        let center = UNUserNotificationCenter.current()
        let start = UNNotificationAction(
            identifier: startAction, title: "Start Recording", options: [.foreground],
            icon: UNNotificationActionIcon(systemImageName: "record.circle"))
        center.setNotificationCategories([
            UNNotificationCategory(identifier: onlineCategory, actions: [start], intentIdentifiers: []),
            UNNotificationCategory(identifier: inPersonCategory, actions: [start], intentIdentifiers: []),
        ])
        center.delegate = notifier
        return notifier
    }

    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func postMeetingDetected(appName: String) {
        post(
            id: Self.onlineCategory, title: "Meeting detected",
            body: "\(appName) is using the microphone. Start recording to transcribe this meeting.")
    }

    func postConversationDetected() {
        post(
            id: Self.inPersonCategory, title: "Conversation detected",
            body: "It sounds like an in-person meeting. Start recording to transcribe it.")
    }

    func removeAll() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.onlineCategory, Self.inPersonCategory])
        center.removePendingNotificationRequests(withIdentifiers: [Self.onlineCategory, Self.inPersonCategory])
    }

    private func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = id
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        // Clicking the notification body just brings the app forward (options: .foreground); only the
        // explicit action starts a recording.
        if action == Self.startAction {
            onAction(category == Self.inPersonCategory ? .startInPerson : .startOnline)
        }
        completionHandler()
    }
}
