import Foundation
import Observation
import VCAudio
import VCIntelligence
import VCModels
import VCSpatial
import VCSpeakers
import VCTranscription
import os

private let analysisLog = Logger(subsystem: "com.voiccenger.app", category: "analysis")

/// One recorded meeting: capture → transcription + speaker identification (+ direction of arrival) →
/// speaker-attributed segments → live analysis → report → storage.
///
/// Live capture (`start()`) and offline files (`processFile`) run through the same pipeline; only the
/// sources and the `ProcessingMode` differ.
@MainActor @Observable
public final class MeetingSession {
    public enum ProcessingMode: Sendable, Hashable {
        /// Realtime capture: pending finals time out, live analysis drops the oldest work when behind.
        case live
        /// Faster-than-realtime file input: nothing times out or is dropped.
        case offline
    }

    public struct Config: Sendable {
        public var title: String?
        public var kind: MeetingKind
        public var detectedMeeting: DetectedMeeting?
        public var microphoneDeviceUID: String?
        public var arrayGeometry: MicArrayGeometry?
        /// Apple live-preview locale; its language is the meeting's language for the voice model.
        public var localeID: String
        public var autoLanguage: Bool
        /// Voice model that produces the final text of each line.
        public var speechEngine: SpeechEngineKind
        /// Deepgram model that streams the meeting when `speechEngine` is Deepgram, and re-transcribes lines of
        /// people without a Deepgram model of their own.
        public var deepgramModel: String
        /// Spelling for speakers without their own preference.
        public var spelling: SpellingVariant
        public var engineKind: IntelligenceEngineKind
        /// Names and jargon to recognize (enrolled names and vocabularies are added automatically).
        public var contextualStrings: [String]
        public var recordAudio: Bool
        /// In-person meetings also record the computer's audio (online meetings always do): with headphones on,
        /// a remote party's voice never reaches the microphone.
        public var recordComputerAudio: Bool
        /// Root of the `MeetingStore` the finished meeting is saved to.
        public var meetingsDirectory: URL
        public var speakerConfig: SpeakerIDConfig
        public var mode: ProcessingMode
        /// Live analysis runs on each new segment.
        public var liveAnalysis: Bool
        /// A final waits at most this long (session seconds) for diarization in `.live` mode.
        public var alignmentTimeout: TimeInterval
        /// Pending live analyses kept in `.live` mode before the oldest is dropped.
        public var analysisBacklog: Int
        /// Transcript lines given to the analyser as context.
        public var analysisContextLines: Int

        public init(
            title: String? = nil, kind: MeetingKind = .inPerson, detectedMeeting: DetectedMeeting? = nil,
            microphoneDeviceUID: String? = nil, arrayGeometry: MicArrayGeometry? = nil,
            localeID: String = AppSettings.systemLocaleID, autoLanguage: Bool = true,
            engineKind: IntelligenceEngineKind = .apple, speechEngine: SpeechEngineKind = .cohere,
            deepgramModel: String = Deepgram.defaultModel,
            spelling: SpellingVariant = .unchanged, contextualStrings: [String] = [], recordAudio: Bool = true,
            recordComputerAudio: Bool = true, meetingsDirectory: URL = AppPaths.default.meetings, speakerConfig: SpeakerIDConfig = .init(),
            mode: ProcessingMode = .live, liveAnalysis: Bool = true, alignmentTimeout: TimeInterval = 15,
            analysisBacklog: Int = 6, analysisContextLines: Int = 8
        ) {
            self.title = title
            self.kind = kind
            self.detectedMeeting = detectedMeeting
            self.microphoneDeviceUID = microphoneDeviceUID
            self.arrayGeometry = arrayGeometry
            self.localeID = localeID
            self.autoLanguage = autoLanguage
            self.engineKind = engineKind
            self.speechEngine = speechEngine
            self.deepgramModel = deepgramModel
            self.spelling = spelling
            self.contextualStrings = contextualStrings
            self.recordAudio = recordAudio
            self.recordComputerAudio = recordComputerAudio
            self.meetingsDirectory = meetingsDirectory
            self.speakerConfig = speakerConfig
            self.mode = mode
            self.liveAnalysis = liveAnalysis
            self.alignmentTimeout = alignmentTimeout
            self.analysisBacklog = analysisBacklog
            self.analysisContextLines = analysisContextLines
        }
    }

    public enum State: Sendable, Hashable {
        case idle
        case starting
        case recording
        case finishing
        case finished
        case failed(String)
    }

    public enum SessionError: LocalizedError {
        case notRecording
        case microphoneUnavailable(String)
        case notEnoughSpeech(seconds: Double)
        case unknownParticipant(String)

        public var errorDescription: String? {
            switch self {
            case .notRecording: "The meeting isn't recording."
            case .microphoneUnavailable(let reason): "The microphone couldn't be started: \(reason)"
            case .notEnoughSpeech(let s):
                String(format: "Only %.0f s of this voice was captured; at least 5 s are needed to enroll it.", s)
            case .unknownParticipant(let key): "No participant \(key)."
            }
        }
    }

    // MARK: Observable state

    public let id: UUID
    public let config: Config
    /// Starts as `config.kind`; an in-person recording becomes online when a meeting app starts using the mic.
    public private(set) var kind: MeetingKind
    /// The conferencing app the meeting runs in (from detection, at the start or mid-recording).
    public private(set) var detectedMeeting: DetectedMeeting?
    public private(set) var state: State = .idle
    public private(set) var startedAt: Date?
    public private(set) var endedAt: Date?
    /// Latest provisional text per channel (cleared when a final arrives).
    public private(set) var volatileText: [AudioChannel: String] = [:]
    /// Finals waiting for speaker turns, in time order.
    public private(set) var pendingFinals: [TranscriptUpdate] = []
    public private(set) var segments: [TranscriptSegment] = []
    public private(set) var roster: ParticipantRoster
    public private(set) var attentionItems: [AttentionItem] = []
    /// Recognizer locale currently used per channel.
    public private(set) var currentLocales: [AudioChannel: String] = [:]
    /// Microphone RMS level, 0...1, for metering.
    public private(set) var inputLevel: Double = 0
    public private(set) var latestDirection: DirectionEstimate?
    /// Non-fatal problems (a source or model that couldn't start, analysis failures).
    public private(set) var warnings: [String] = []
    /// Capture problems in effect now (a silent meeting app, a silenced microphone); see `CaptureHealthMonitor`.
    public private(set) var captureWarnings: [CaptureWarning] = []
    /// Microphone lines dropped because they repeated the computer's audio heard through the speakers.
    public private(set) var bleedLinesRemoved = 0
    /// Set when the report couldn't be generated; the meeting is still saved.
    public private(set) var reportError: String?
    public private(set) var intelligenceEngineName: String?
    /// Download/load state of each voice model, for the engine status shown while recording.
    public private(set) var speechEngineStatuses: [SpeechEngineKind: ModelStatus] = [:]
    /// The saved meeting, once `stop()` has finished.
    public private(set) var meeting: Meeting?

    public var participants: [Participant] { roster.participants }
    public var hasMicArray: Bool { config.arrayGeometry != nil }
    public var isActive: Bool { state == .starting || state == .recording || state == .finishing }

    // MARK: Pipeline state

    @ObservationIgnored private var profiles: [SpeakerProfile]
    @ObservationIgnored private var voices: SessionVoices
    @ObservationIgnored private let library: SpeechModelLibrary
    @ObservationIgnored private var clock: SessionClock?
    @ObservationIgnored private var sources: [any AudioSource] = []
    @ObservationIgnored private var systemSource: SystemAudioSource?
    @ObservationIgnored private var health = CaptureHealthMonitor()
    @ObservationIgnored private var transcribers: [AudioChannel: any ChannelTranscriber] = [:]
    @ObservationIgnored private var identifiers: [AudioChannel: SpeakerIdentifier] = [:]
    /// Capture loops; each returns the session time of the end of the last chunk it forwarded.
    @ObservationIgnored private var captureTasks: [Task<TimeInterval, Never>] = []
    @ObservationIgnored private var consumerTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var eventTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var recorderTasks: [Task<String?, Never>] = []
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    /// Whole-meeting 16 kHz audio, kept when an enrolled speaker may need another engine or language.
    @ObservationIgnored private var archive: MeetingAudioArchive?
    /// Lines being re-transcribed for their speaker's engine/language.
    @ObservationIgnored private var rerouteTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var rerouteFailureReported = false
    /// The Deepgram model the meeting's lines came from (Nova-3 when the chosen one couldn't stream).
    @ObservationIgnored private var liveDeepgramModel = Deepgram.defaultModel
    @ObservationIgnored private var analysisWorker: Task<Void, Never>?
    @ObservationIgnored private var analysisInput: AsyncStream<AnalysisJob>.Continuation?
    @ObservationIgnored private var engine: (any MeetingIntelligence)?
    @ObservationIgnored private let collector = VoiceClipCollector()
    @ObservationIgnored private var pending: PendingAlignmentQueue
    @ObservationIgnored private var turns: [AudioChannel: [SpeakerTurn]] = [:]
    @ObservationIgnored private var keyAliases: [String: String] = [:]
    @ObservationIgnored private var directionHistory: [DirectionEstimate] = []
    @ObservationIgnored private var seatTracker = SeatTracker()
    @ObservationIgnored private var localesUsed: [String] = []
    @ObservationIgnored private var analysisFailureReported = false
    @ObservationIgnored private var lastLevelUpdate: TimeInterval = 0
    /// Name of the processed file, the title fallback for `processFile`.
    @ObservationIgnored private var sourceName: String?
    /// When the recording being processed started (`processRecording`); live meetings start now.
    @ObservationIgnored private var recordingStartedAt: Date?
    /// The recordings `processRecording` replays (kept with the saved meeting).
    @ObservationIgnored private var replayedFiles: [String] = []
    /// The meeting becomes online when the computer's audio carried speech (a recording whose kind isn't known).
    @ObservationIgnored private var inferKind = false
    /// Every channel's transcriber and identifier has finished (`stop()`): what's left is alignment, analysis and
    /// the report.
    @ObservationIgnored private var inputTranscribed = false
    /// Keeps offline channels on one clock (`ReplayPacer`).
    @ObservationIgnored private var pacer: ReplayPacer?
    /// Live meetings write every line to `journal.jsonl` as it's finalized, so a crash leaves the transcript.
    @ObservationIgnored private var journal: MeetingJournal?
    /// Participants as last journaled: who they are, and when (session seconds) the roster was written.
    @ObservationIgnored private var journaledRoster: (identity: [String], time: TimeInterval)?
    /// Progress of offline processing, for `processRecording`.
    @ObservationIgnored private var onProgress: (@MainActor (ProcessingProgress) -> Void)?

    /// How far behind the newest audio the identifier's completed windows can be.
    private var diarizationLag: TimeInterval { config.speakerConfig.windowSeconds + 0.5 }
    private static let maxDirectionHistory = 6_000

    public init(config: Config, profiles: [SpeakerProfile], id: UUID = UUID(), library: SpeechModelLibrary = .shared) {
        self.id = id
        self.config = config
        self.kind = config.kind
        self.detectedMeeting = config.detectedMeeting
        self.profiles = profiles
        self.voices = SessionVoices(
            profiles: profiles, contextualStrings: config.contextualStrings, sessionSpelling: config.spelling)
        self.library = library
        self.roster = ParticipantRoster(profiles: profiles)
        self.pending = PendingAlignmentQueue(timeout: config.mode == .live ? config.alignmentTimeout : nil)
    }

    /// The meeting's language for the voice model ("en" for "en-GB").
    private var sessionLanguage: String { SessionVoices.languageCode(ofLocale: config.localeID) }

    // MARK: - Lifecycle

    /// Starts live capture: the microphone, plus the computer's audio for online meetings and (unless turned off)
    /// in-person ones. A native meeting app's whole process family is tapped; a browser or no app taps everything
    /// the Mac plays except Voiccenger.
    public func start() async throws {
        let config = self.config
        let computerAudio = config.kind == .online || config.recordComputerAudio
        let target = SystemAudioTarget(meetingApp: config.detectedMeeting?.app)
        try await run(channels: computerAudio ? [.microphone, .system] : [.microphone]) { clock in
            var sources: [any AudioSource] = [
                MicrophoneSource(
                    deviceUID: config.microphoneDeviceUID, arrayGeometry: config.arrayGeometry, clock: clock)
            ]
            if computerAudio { sources.append(SystemAudioSource(target: target, clock: clock)) }
            return sources
        }
    }

    /// A meeting app started using the microphone during a recording that had none: the meeting becomes online in
    /// that app, and the computer-audio channel narrows to the app's processes (starting it if it was off),
    /// without restarting the recording.
    public func upgradeToOnline(_ meeting: DetectedMeeting) async {
        guard state == .recording, config.mode == .live, detectedMeeting == nil else { return }
        kind = .online
        detectedMeeting = meeting
        journalHeader()
        health.setMeetingApp(meeting.app.displayName, at: now())
        let target = SystemAudioTarget(meetingApp: meeting.app)
        if let systemSource {
            systemSource.retarget(target)
        } else {
            await startComputerAudio(target: target)
        }
    }

    /// Adds the computer-audio channel to a running recording.
    private func startComputerAudio(target: SystemAudioTarget) async {
        guard let clock else { return }
        do {
            try await prepare(channel: .system)
            let source = SystemAudioSource(target: target, clock: clock)
            let stream = try await source.start()
            guard state == .recording else {
                await source.stop()
                await transcribers.removeValue(forKey: .system)?.finish()
                return
            }
            sources.append(source)
            launch(source: source, stream: stream)
            if let transcriber = transcribers[.system] { launchEvents(channel: .system, transcriber: transcriber) }
        } catch {
            warn("Meeting audio couldn't be captured (\(error.localizedDescription)); recording the microphone only.")
            await transcribers.removeValue(forKey: .system)?.finish()
            identifiers.removeValue(forKey: .system)
        }
    }

    /// Runs a recorded file through the live pipeline (faster than realtime) and returns the saved meeting.
    /// Each line waits for the voice model (loading it if downloaded) instead of keeping Apple's preview text.
    public static func processFile(
        url: URL, config: Config, profiles: [SpeakerProfile], library: SpeechModelLibrary = .shared
    ) async throws -> Meeting {
        var config = config
        config.mode = .offline
        let session = MeetingSession(config: config, profiles: profiles, library: library)
        // Without an explicit title the report proposes one; the file name is the fallback.
        session.sourceName = url.deletingPathExtension().lastPathComponent
        try await session.run(channels: [.microphone]) { clock in
            [AudioFileSource(url: url, channel: .microphone, clock: clock, realtime: false)]
        }
        await session.waitForCaptureToEnd()
        return try await session.stop()
    }

    public enum RecoveryError: LocalizedError {
        case notAMeetingFolder(String)
        case noRecordings(String)

        public var errorDescription: String? {
            switch self {
            case .notAMeetingFolder(let name): "“\(name)” isn't a meeting folder (its name must be the meeting's id)."
            case .noRecordings(let name): "“\(name)” has no recorded audio to transcribe."
            }
        }
    }

    /// Transcribes a meeting again from its recordings: `microphone.wav` and `system.wav` in `directory` (a meeting
    /// folder, named by the meeting's id) replay together on one session clock as the `.microphone` and `.system`
    /// channels through the live pipeline (voice model, speaker identification with `profiles`, alignment, bleed
    /// suppression, report), and the meeting is saved as `meeting.json` in that same folder.
    ///
    /// A recording whose header an interrupted app never finalized is repaired first. The meeting starts at
    /// `startedAt`, by default when the folder and its recordings were created. Its kind is `kind`, else online when
    /// the computer's audio carried speech. Without a title in `config` the report proposes one.
    public static func processRecording(
        directory: URL, config: Config, profiles: [SpeakerProfile], startedAt: Date? = nil, kind: MeetingKind? = nil,
        library: SpeechModelLibrary = .shared, progress: (@MainActor (ProcessingProgress) -> Void)? = nil
    ) async throws -> Meeting {
        let name = directory.lastPathComponent
        guard let id = UUID(uuidString: name) else { throw RecoveryError.notAMeetingFolder(name) }
        var files: [(channel: AudioChannel, url: URL)] = []
        var duration = 0.0
        for channel in AudioChannel.allCases {
            let url = directory.appending(path: UnsavedRecording.audioFileName(channel))
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try WAVHeader.repair(url)
            let info = try WAVHeader.read(url)
            guard info.frames > 0 else { continue }
            files.append((channel, url))
            duration = max(duration, info.duration)
        }
        guard !files.isEmpty else { throw RecoveryError.noRecordings(name) }

        var config = config
        config.mode = .offline
        // The recordings are the input: recording again would overwrite them.
        config.recordAudio = false
        config.meetingsDirectory = directory.deletingLastPathComponent()
        if let kind { config.kind = kind }
        let session = MeetingSession(config: config, profiles: profiles, id: id, library: library)
        session.recordingStartedAt = startedAt ?? Self.creationDate(of: [directory] + files.map(\.url))
        session.replayedFiles = files.map(\.url.lastPathComponent)
        session.inferKind = kind == nil
        session.onProgress = progress
        progress?(.transcribing(0))
        let inputs = files
        let total = duration
        try await session.run(channels: inputs.map(\.channel)) { clock in
            inputs.map { AudioFileSource(url: $0.url, channel: $0.channel, clock: clock, realtime: false) }
        }
        // Input is decoded far ahead of recognition: progress is how far the transcript has got.
        let ticker = Task { @MainActor [weak session] in
            var through = 0.0
            while !Task.isCancelled, let session, !session.inputTranscribed, total > 0 {
                through = max(through, session.segments.map(\.range.end).max() ?? 0)
                progress?(.transcribing(min(1, through / total)))
                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer { ticker.cancel() }
        await session.waitForCaptureToEnd()
        return try await session.stop()
    }

    /// When the earliest of `urls` was created.
    private static func creationDate(of urls: [URL]) -> Date? {
        urls.compactMap { try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate }.min()
    }

    /// Finishes capture and processing, generates the report (unless `writeReport` is false: the report can be
    /// written later from the saved meeting) and saves the meeting.
    @discardableResult
    public func stop(writeReport: Bool = true) async throws -> Meeting {
        if let meeting { return meeting }
        guard state == .recording else { throw SessionError.notRecording }
        state = .finishing
        let live = config.mode == .live

        for source in sources { await source.stop() }
        var audioEnd = 0.0
        for task in captureTasks {
            audioEnd = max(audioEnd, await Self.finish(task, timeout: live ? .seconds(3) : nil))
        }
        for task in consumerTasks { await Self.finish(task, timeout: live ? .seconds(30) : nil) }
        for task in eventTasks { await Self.finish(task, timeout: live ? .seconds(15) : nil) }
        inputTranscribed = true
        onProgress?(.finishingLines)
        tickTask?.cancel()
        var audioFiles: [String] = replayedFiles
        for task in recorderTasks { if let name = await task.value { audioFiles.append(name) } }

        for update in pending.drain() { attribute(update) }
        for task in rerouteTasks { await Self.finish(task, timeout: live ? .seconds(30) : nil) }
        rerouteTasks = []
        statusTask?.cancel()
        pendingFinals = []
        volatileText = [:]

        analysisInput?.finish()
        await analysisWorker?.value
        // Offline input runs faster than realtime: the meeting lasted as long as its audio, not its processing.
        endedAt = live ? Date() : (startedAt ?? Date()).addingTimeInterval(audioEnd)
        if inferKind, kind == .inPerson, segments.contains(where: { $0.channel == .system }) { kind = .online }

        var meeting = makeMeeting(audioFiles: audioFiles)
        if writeReport {
            onProgress?(.writingReport)
            meeting.report = await generateReport(for: meeting)
            if config.title == nil, let title = meeting.report?.title.nonEmpty { meeting.title = title }
        }

        onProgress?(.saving)
        journal?.close()
        try await MeetingStore(directory: config.meetingsDirectory).save(meeting)
        self.meeting = meeting
        state = .finished
        return meeting
    }

    /// Saves the meeting as it stands, without waiting for the rest of processing (the app is quitting and can't
    /// wait any longer): lines still waiting for their speaker are attributed with what's known, and there is no
    /// report. A `stop()` still under way may save a fuller version over it.
    @discardableResult
    public func saveSnapshot() async throws -> Meeting {
        if let meeting { return meeting }
        guard state == .recording || state == .finishing else { throw SessionError.notRecording }
        for update in pending.drain() { attribute(update) }
        pendingFinals = []
        let store = MeetingStore(directory: config.meetingsDirectory)
        let audioFiles =
            replayedFiles
            + (config.recordAudio
                ? AudioChannel.allCases.map { UnsavedRecording.audioFileName($0) }.filter {
                    FileManager.default.fileExists(atPath: store.directory(for: id).appending(path: $0).path)
                } : [])
        var meeting = makeMeeting(audioFiles: audioFiles)
        meeting.endedAt = meeting.endedAt ?? (config.mode == .live ? Date() : nil)
        try await store.save(meeting)
        self.meeting = meeting
        return meeting
    }

    private func makeMeeting(audioFiles: [String]) -> Meeting {
        Meeting(
            id: id, title: config.title ?? defaultTitle(), kind: kind,
            appName: detectedMeeting?.app.displayName, startedAt: startedAt ?? Date(), endedAt: endedAt,
            participants: participants, segments: segments.sorted { $0.range.start < $1.range.start }, report: nil,
            audioFiles: audioFiles, localeIDs: localesUsed, captureWarnings: health.raised)
    }

    /// Renames a participant (typically an unknown "Speaker 2"). Later lines and the report use the new name.
    public func rename(participantKey: String, to name: String) {
        roster.rename(participantKey, to: name)
        journalRoster(force: true)
    }

    /// Seconds of a participant's voice collected so far (enrollment needs at least 5 s).
    public func collectedVoiceSeconds(participantKey: String) async -> Double {
        await collector.seconds(for: participantKey)
    }

    /// Enrolls a participant heard in this meeting as a profile, from the audio collected for them, and
    /// merges them under the profile's key so the rest of the meeting attributes to that person.
    @discardableResult
    public func enrollParticipant(
        key: String, name: String? = nil, into store: SpeakerProfileStore
    ) async throws -> SpeakerProfile {
        guard let participant = roster.participant(key) else { throw SessionError.unknownParticipant(key) }
        let samples = await collector.clip16k(for: key)
        let seconds = Double(samples.count) / 16_000
        guard seconds >= 5 else { throw SessionError.notEnoughSpeech(seconds: seconds) }
        let embeddings = try await SpeakerEnrollment.embeddings(samples16k: samples)
        let existing = await store.all()
        let profile = SpeakerProfile(
            name: name?.nonEmpty ?? participant.displayName, embeddings: embeddings,
            colorIndex: EnrollmentService.nextColorIndex(in: existing),
            voice: VoiceSettings(
                languageCode: SessionVoices.languageCode(ofLocale: participant.localeID ?? config.localeID)))
        try await store.upsert(profile)
        profiles.append(profile)
        voices.upsert(profile)
        for identifier in identifiers.values { await identifier.setProfiles(profiles) }
        for transcriber in transcribers.values { await transcriber.setPrompt(voices.prompt) }
        rekey(key, to: SpeakerTurn.profileKey(profile.id), profile: profile)
        return profile
    }

    // MARK: - Pipeline setup

    private func run(
        channels: [AudioChannel], makeSources: @Sendable (SessionClock) -> [any AudioSource]
    ) async throws {
        guard state == .idle else { return }
        state = .starting
        do {
            try await prepare(channels: channels)
            let clock = SessionClock()
            self.clock = clock
            let made = makeSources(clock)
            var started: [(any AudioSource, AsyncStream<AudioChunk>)] = []
            for source in made {
                do {
                    started.append((source, try await source.start()))
                } catch where source.channel == .system {
                    warn("Meeting audio couldn't be captured (\(error.localizedDescription)); recording the microphone only.")
                    await transcribers.removeValue(forKey: .system)?.finish()
                    identifiers.removeValue(forKey: .system)
                } catch {
                    throw SessionError.microphoneUnavailable(error.localizedDescription)
                }
            }
            sources = started.map(\.0)
            startedAt = recordingStartedAt ?? Date()
            if config.mode == .live {
                health.setMeetingApp(detectedMeeting?.app.displayName, at: 0)
                openJournal()
            } else {
                pacer = ReplayPacer()
            }
            for (source, stream) in started { launch(source: source, stream: stream) }
            pacer?.open()
            for (channel, transcriber) in transcribers { launchEvents(channel: channel, transcriber: transcriber) }
            launchAnalysis()
            if config.mode == .live { launchTicker() }
            state = .recording
        } catch {
            for source in sources { await source.stop() }
            for transcriber in transcribers.values { await transcriber.finish() }
            statusTask?.cancel()
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    private func prepare(channels: [AudioChannel]) async throws {
        if AppleSpeech.isAvailable { try await SpeechAssets.ensureInstalled(localeIDs: [config.localeID]) }
        for kind in SpeechEngineKind.allCases { speechEngineStatuses[kind] = await library.status(kind) }
        observeEngineStatuses()
        if config.speechEngine != .apple, config.speechEngine != .deepgram,
            !SessionVoices.availableEngines(speechEngineStatuses).contains(config.speechEngine)
        {
            let name = SpeechModelLibrary.info(config.speechEngine).displayName
            if AppleSpeech.isAvailable {
                warn("\(name) isn't downloaded yet; lines use Apple's transcription until it's ready.")
            } else {
                // Without Apple Speech the voice model makes the live text too (RefiningTranscriber).
                let stand = library.previewEngine(preferring: config.speechEngine, languageCode: sessionLanguage)
                warn(
                    stand != config.speechEngine
                        ? "\(name) isn't downloaded yet; this meeting is transcribed with \(SpeechModelLibrary.info(stand).displayName)."
                        : "\(name) isn't downloaded yet; lines appear once it is. (Apple Speech, which fills in meanwhile, needs macOS 26.)")
            }
        }
        if voices.mayReroute(sessionLanguage: sessionLanguage) { archive = MeetingAudioArchive() }

        for channel in channels { try await prepare(channel: channel) }

        // The engine is needed for the report even when live analysis is off.
        let choice = ReportWriter.engine(preferring: config.engineKind)
        engine = choice.engine
        if choice.isFallback {
            warn("The selected intelligence engine is unavailable; using \(choice.engine.engineName) instead.")
        }
        intelligenceEngineName = choice.engine.engineName
    }

    /// Starts the transcriber and speaker identifier for one channel.
    private func prepare(channel: AudioChannel) async throws {
        let transcriber = makeTranscriber(channel: channel)
        try await transcriber.start()
        if let deepgram = transcriber as? DeepgramLiveTranscriber {
            if let reason = await deepgram.fallbackReason {
                warn("Deepgram isn't transcribing this meeting (\(reason)); lines are transcribed on this Mac instead.")
            } else if let reason = await deepgram.modelFallbackReason {
                warn("\(reason).")
                liveDeepgramModel = Deepgram.defaultModel
            } else {
                liveDeepgramModel = config.deepgramModel
            }
        }
        transcribers[channel] = transcriber
        currentLocales[channel] = config.localeID
        noteLocale(config.localeID)

        let identifier = SpeakerIdentifier(channel: channel, config: config.speakerConfig)
        do {
            try await identifier.prepare()
            await identifier.setProfiles(profiles)
            identifiers[channel] = identifier
        } catch {
            warn("Speaker identification is unavailable (\(error.localizedDescription)); lines will be unattributed.")
            pending.markComplete(channel)
        }
    }

    /// Deepgram streams when it's the meeting's engine (falling back to on-device per channel when it can't be
    /// used); every other engine refines Apple's live preview.
    private func makeTranscriber(channel: AudioChannel) -> any ChannelTranscriber {
        let offline = config.mode == .offline
        guard config.speechEngine == .deepgram else {
            return RefiningTranscriber(
                channel: channel, appleLocaleID: config.localeID, engine: config.speechEngine,
                languageCode: sessionLanguage, prompt: voices.prompt, customization: nil, library: library,
                autoLanguage: config.autoLanguage, waitForEngine: offline)
        }
        var options = DeepgramLiveTranscriber.Options()
        // Files are streamed faster than realtime; Deepgram may still be catching up when the input ends.
        if offline { options.finishTimeout = .seconds(600) }
        options.model = config.deepgramModel
        return DeepgramLiveTranscriber(
            channel: channel, localeID: config.localeID, languageCode: sessionLanguage, prompt: voices.prompt,
            library: library, fallbackEngine: deepgramFallbackEngine, autoLanguage: config.autoLanguage,
            waitForEngine: offline, options: options)
    }

    /// The most accurate downloaded on-device model for the meeting's language, else Apple.
    private var deepgramFallbackEngine: SpeechEngineKind {
        let available = SessionVoices.availableEngines(speechEngineStatuses)
        return [SpeechEngineKind.cohere, .whisper].first {
            available.contains($0) && SpeechModelLibrary.info($0).languageCodes.contains(sessionLanguage)
        } ?? .apple
    }

    // MARK: - Fan-out

    /// One capture loop per source; every chunk is copied to independent consumer streams so a slow
    /// consumer (transcriber, diarizer, archive, recorder, DOA) never blocks capture or the others.
    ///
    /// Computer audio goes through `AutomaticGainControl` before transcription, speaker identification and the
    /// archive (quiet outputs such as HDMI monitors arrive ~20 dB down); the recording keeps the raw audio. Its
    /// speech times also reach the microphone's identifier and the voice-clip collector, so the computer's audio
    /// heard through the speakers is never matched to, or enrolled as, someone in the room.
    private func launch(source: any AudioSource, stream: AsyncStream<AudioChunk>) {
        let channel = source.channel
        var sinks: [AsyncStream<AudioChunk>.Continuation] = []
        var rawSinks: [AsyncStream<AudioChunk>.Continuation] = []
        let offline = config.mode == .offline
        let pacer = self.pacer
        /// A consumer's copy of the input; offline, it reports to the pacer how far the consumer has got.
        func makeSink(
            _ policy: AsyncStream<AudioChunk>.Continuation.BufferingPolicy = .unbounded
        ) -> (AsyncStream<AudioChunk>, AsyncStream<AudioChunk>.Continuation) {
            let (s, c) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: policy)
            return (pacer?.paced(s) ?? s, c)
        }

        if let system = source as? SystemAudioSource {
            systemSource = system
            observe(system)
        }
        if let transcriber = transcribers[channel] {
            let (s, c) = makeSink()
            sinks.append(c)
            consumerTasks.append(Task.detached { await Self.feedTranscriber(s, transcriber) })
        }
        if let identifier = identifiers[channel] {
            let (s, c) = makeSink()
            sinks.append(c)
            let collector = self.collector
            consumerTasks.append(
                Task.detached { [weak self] in
                    await Self.feedIdentifier(s, identifier, collector, channel: channel, session: self)
                })
        }
        if let archive {
            let (s, c) = makeSink()
            sinks.append(c)
            consumerTasks.append(Task.detached { await Self.feedArchive(s, archive, channel: channel) })
        }
        if channel == .system {
            let (s, c) = makeSink()
            sinks.append(c)
            let micIdentifier = identifiers[.microphone]
            let collector = self.collector
            consumerTasks.append(Task.detached { await Self.feedSystemSpeech(s, micIdentifier, collector) })
        }
        if channel == .microphone, let geometry = config.arrayGeometry {
            // Direction is advisory live: keep only the newest chunks if estimation falls behind.
            let (s, c) = makeSink(offline ? .unbounded : .bufferingNewest(10))
            sinks.append(c)
            let estimator = DirectionEstimator(geometry: geometry)
            consumerTasks.append(Task.detached { [weak self] in await Self.feedDirection(s, estimator, session: self) })
        }
        if config.recordAudio {
            let (s, c) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
            rawSinks.append(c)
            let name = "\(channel.rawValue).wav"
            let url = MeetingStore(directory: config.meetingsDirectory).directory(for: id).appending(path: name)
            recorderTasks.append(Task.detached { [weak self] in await Self.record(s, to: url, session: self) })
        }

        var meter: (@Sendable (AudioChunk) -> Void)?
        if channel == .microphone && !offline {
            meter = { [weak self] chunk in
                let level = Self.rms(chunk.samples)
                let time = chunk.startTime
                Task { @MainActor in self?.updateLevel(level, at: time) }
            }
        }
        let outputs = sinks
        let raw = rawSinks
        let tap = meter
        let normalize = channel == .system
        var levels: (@Sendable (LevelWindow) -> Void)?
        if !offline {
            levels = { [weak self] window in
                Task { @MainActor in self?.noteLevels(window, channel: channel) }
            }
        }
        let report = levels
        captureTasks.append(
            Task.detached {
                var end = 0.0
                var gain = AutomaticGainControl()
                var window = LevelWindow()
                for await chunk in stream {
                    // Offline: wait for every consumer (of every channel) to be close behind.
                    await pacer?.waitToForward(chunk.startTime)
                    for sink in raw { sink.yield(chunk) }
                    let processed = normalize ? gain.process(chunk) : chunk
                    for sink in outputs { sink.yield(processed) }
                    tap?(chunk)
                    if let report, let full = window.add(chunk) { report(full) }
                    end = max(end, chunk.range.end)
                }
                for sink in outputs + raw { sink.finish() }
                return end
            })
    }

    /// Raw level of half a second of one channel, for the capture-health rules.
    struct LevelWindow: Sendable {
        static let seconds = 0.5
        var sumSquares: Double = 0
        var count = 0
        var peak: Float = 0
        var end: TimeInterval = 0
        private var start: TimeInterval?

        var rmsDB: Double { 10 * log10(max(sumSquares / Double(max(count, 1)), 1e-12)) }

        /// Adds a chunk; returns the window and starts a new one once it spans `seconds`.
        mutating func add(_ chunk: AudioChunk) -> LevelWindow? {
            if start == nil { start = chunk.startTime }
            for s in chunk.samples {
                sumSquares += Double(s * s)
                peak = max(peak, abs(s))
            }
            count += chunk.samples.count
            end = chunk.range.end
            guard end - start! >= Self.seconds else { return nil }
            defer { self = LevelWindow() }
            return self
        }
    }

    private func noteLevels(_ window: LevelWindow, channel: AudioChannel) {
        switch channel {
        case .microphone: health.microphone(peak: window.peak, at: window.end)
        case .system: health.system(rmsDB: window.rmsDB, at: window.end)
        }
    }

    /// Logs what the computer-audio source did on its own (falling back to the global tap, failing).
    private func observe(_ system: SystemAudioSource) {
        let events = system.events
        eventTasks.append(
            Task.detached { [weak self] in
                for await event in events { await self?.handle(event) }
            })
    }

    private func handle(_ event: SystemAudioEvent) {
        switch event {
        case .tapping:
            break
        case .fellBackToGlobal(let app, let reason):
            warn("Recording all computer audio instead of only \(app.displayName)'s: \(reason).")
        case .failed(let reason):
            warn("Computer audio couldn't be captured (\(reason)); the meeting's remote side may be missing.")
        }
    }

    private func launchEvents(channel: AudioChannel, transcriber: any ChannelTranscriber) {
        let events = transcriber.events
        eventTasks.append(
            Task.detached { [weak self] in
                for await event in events { await self?.handle(event) }
            })
    }

    private func launchTicker() {
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.releasePending()
                self?.checkHealth()
            }
        }
    }

    private func checkHealth() {
        health.inputVolume(AudioDevices.inputVolume(deviceUID: config.microphoneDeviceUID))
        if health.evaluate(at: now()) { captureWarnings = health.active }
    }

    private func observeEngineStatuses() {
        let updates = library.statusUpdates
        statusTask = Task { [weak self] in
            for await (kind, status) in updates { self?.speechEngineStatuses[kind] = status }
        }
    }

    private nonisolated static func feedTranscriber(_ stream: AsyncStream<AudioChunk>, _ t: any ChannelTranscriber) async {
        for await chunk in stream { await t.append(chunk) }
        await t.finish()
    }

    /// Tells the microphone's identifier and the clip collector when the computer's audio carried speech.
    private nonisolated static func feedSystemSpeech(
        _ stream: AsyncStream<AudioChunk>, _ micIdentifier: SpeakerIdentifier?, _ collector: VoiceClipCollector
    ) async {
        var detector = SpeechSpanDetector()
        for await chunk in stream {
            let spans = detector.spans(in: chunk)
            guard !spans.isEmpty else { continue }
            await micIdentifier?.excludeFromMatching(spans)
            await collector.excludeSystemSpeech(spans)
        }
    }

    private nonisolated static func feedArchive(
        _ stream: AsyncStream<AudioChunk>, _ archive: MeetingAudioArchive, channel: AudioChannel
    ) async {
        for await chunk in stream { await archive.append(chunk) }
        await archive.finish(channel)
    }

    private nonisolated static func feedIdentifier(
        _ stream: AsyncStream<AudioChunk>, _ identifier: SpeakerIdentifier, _ collector: VoiceClipCollector,
        channel: AudioChannel, session: MeetingSession?
    ) async {
        var failures = 0
        for await chunk in stream {
            await collector.append(chunk)
            do {
                let turns = try await identifier.process(chunk)
                if !turns.isEmpty { await collector.collect(turns) }
                await session?.ingest(turns: turns, channel: channel, processedThrough: chunk.range.end)
            } catch {
                failures += 1
                if failures == 1 { await session?.warn("Speaker identification error: \(error.localizedDescription)") }
            }
        }
        do {
            let turns = try await identifier.flush()
            await collector.collect(turns)
            await session?.ingest(turns: turns, channel: channel, processedThrough: .infinity)
        } catch {
            await session?.warn("Speaker identification error: \(error.localizedDescription)")
        }
        await session?.identifierFinished(channel)
    }

    private nonisolated static func feedDirection(
        _ stream: AsyncStream<AudioChunk>, _ estimator: DirectionEstimator, session: MeetingSession?
    ) async {
        for await chunk in stream {
            if let estimate = estimator.estimate(chunk) { await session?.ingest(direction: estimate) }
        }
    }

    /// Writes one channel to `url`, padding leading silence so file time 0 is session time 0.
    /// Returns the file name when anything was written.
    private nonisolated static func record(
        _ stream: AsyncStream<AudioChunk>, to url: URL, session: MeetingSession?
    ) async -> String? {
        var recorder: AudioRecorder?
        var failed = false
        for await chunk in stream {
            if recorder == nil && !failed {
                do {
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let r = try AudioRecorder(url: url, sampleRate: chunk.sampleRate)
                    var t = 0.0
                    let lead = min(chunk.startTime, 600)
                    while t < lead {
                        let n = Int((min(1, lead - t) * chunk.sampleRate).rounded())
                        guard n > 0 else { break }
                        r.append(AudioChunk(channel: chunk.channel, startTime: t, sampleRate: chunk.sampleRate,
                                            samples: [Float](repeating: 0, count: n)))
                        t += Double(n) / chunk.sampleRate
                    }
                    recorder = r
                } catch {
                    failed = true
                    await session?.warn("Audio couldn't be recorded: \(error.localizedDescription)")
                }
            }
            recorder?.append(chunk)
        }
        recorder?.close()
        return recorder == nil ? nil : url.lastPathComponent
    }

    private nonisolated static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return Double((sum / Float(samples.count)).squareRoot())
    }

    // MARK: - Event handling (main actor)

    private func handle(_ event: TranscriptEvent) {
        switch event {
        case .volatile(let u):
            volatileText[u.channel] = u.text
        case .final(let u):
            volatileText[u.channel] = nil
            guard !u.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            pending.enqueue(u, at: now())
            releasePending()
        case .localeChanged(let channel, _, let to, _):
            currentLocales[channel] = to
            noteLocale(to)
        }
    }

    private func ingest(turns newTurns: [SpeakerTurn], channel: AudioChannel, processedThrough: TimeInterval) {
        if !newTurns.isEmpty {
            var list = turns[channel] ?? []
            for var turn in newTurns {
                if let alias = keyAliases[turn.speakerKey] {
                    turn.speakerKey = alias
                    turn.profileID = ParticipantRoster.profileID(fromKey: alias)
                }
                roster.observe(turn)
                list.append(turn)
                if channel == .microphone { addSeatEvidence(for: turn) }
            }
            list.sort { $0.range.start < $1.range.start }
            turns[channel] = list
            pending.advanceCoverage(to: newTurns.map(\.range.end).max()!, for: channel)
        }
        pending.advanceCoverage(to: processedThrough - diarizationLag, for: channel)
        releasePending()
    }

    private func identifierFinished(_ channel: AudioChannel) {
        pending.markComplete(channel)
        releasePending()
    }

    private func ingest(direction: DirectionEstimate) {
        latestDirection = direction
        directionHistory.append(direction)
        if directionHistory.count > Self.maxDirectionHistory + Self.maxDirectionHistory / 4 {
            directionHistory.removeFirst(directionHistory.count - Self.maxDirectionHistory)
        }
    }

    private func updateLevel(_ level: Double, at time: TimeInterval) {
        guard time - lastLevelUpdate >= 0.05 || level > inputLevel else { return }
        lastLevelUpdate = time
        inputLevel = level
    }

    private func warn(_ message: String) {
        if !warnings.contains(message) { warnings.append(message) }
    }

    // MARK: - Journal

    /// Starts the live meeting's journal in its folder (`MeetingJournal`).
    private func openJournal() {
        do {
            journal = try MeetingJournal(directory: MeetingStore(directory: config.meetingsDirectory).directory(for: id))
            journalHeader()
        } catch {
            warn("The transcript can't be saved as it's written (\(error.localizedDescription)); it's saved when the meeting ends.")
        }
    }

    private func journalHeader() {
        guard let journal, let startedAt else { return }
        journal.append(
            .header(
                JournalRecord.Header(
                    meetingID: id, title: config.title, kind: kind, appName: detectedMeeting?.app.displayName,
                    startedAt: startedAt, localeIDs: localesUsed)))
    }

    /// Writes the participants when someone joins, is renamed or enrolled, and at most once a minute otherwise
    /// (speaking times).
    private func journalRoster(force: Bool = false) {
        guard let journal else { return }
        let identity = participants.map { "\($0.id)\u{1F}\($0.displayName)\u{1F}\($0.profileID?.uuidString ?? "")" }
        let time = now()
        if !force, let last = journaledRoster, last.identity == identity, time - last.time < 60 { return }
        journaledRoster = (identity, time)
        journal.append(.participants(participants))
    }

    private func journalSegment(_ segment: TranscriptSegment) {
        guard let journal else { return }
        journal.append(.segment(segment))
        journalRoster()
    }

    private func now() -> TimeInterval { clock?.now() ?? 0 }

    private func noteLocale(_ id: String) {
        if !localesUsed.contains(id) { localesUsed.append(id) }
    }

    // MARK: - Alignment

    private func releasePending() {
        for update in pending.release(now: now()) { attribute(update) }
        pendingFinals = pending.entries.map(\.update)
    }

    private func attribute(_ update: TranscriptUpdate) {
        let window = TimeRange(
            start: update.range.start - TranscriptAligner.nearestTurnTolerance - 1,
            end: update.range.end + TranscriptAligner.nearestTurnTolerance + 1)
        let nearby = (turns[update.channel] ?? []).filter { $0.range.overlap(with: window) > 0 }
        noteLocale(update.localeID)
        for piece in TranscriptAligner.align(update: update, turns: nearby) {
            let segment = TranscriptSegment(
                channel: update.channel, speakerKey: piece.speakerKey, range: piece.range,
                text: voices.customize(piece.text, speakerKey: piece.speakerKey), confidence: piece.confidence,
                localeID: update.localeID,
                direction: update.channel == .microphone ? direction(during: piece.range) : nil, engine: update.engine)
            if isBleed(segment) {
                bleedLinesRemoved += 1
                continue
            }
            roster.ensure(key: piece.speakerKey, channel: update.channel)
            if piece.speakerKey == TranscriptAligner.unknownSpeakerKey(for: update.channel) {
                // Unattributed speech has no turn to credit its time from.
                roster.addSpeakingTime(piece.range.duration, for: piece.speakerKey)
            }
            roster.setLocale(update.localeID, for: piece.speakerKey)
            segments.append(segment)
            journalSegment(segment)
            if segment.channel == .system { removeBleed(repeating: segment) }
            if let archive,
                let route = voices.route(
                    speakerKey: piece.speakerKey, segmentEngine: update.engine,
                    segmentLanguage: SessionVoices.languageCode(ofLocale: update.localeID),
                    available: SessionVoices.availableEngines(speechEngineStatuses),
                    sessionDeepgramModel: liveDeepgramModel)
            {
                reroute(segment, with: route, archive: archive)
            } else {
                enqueueAnalysis(of: segment)
            }
        }
    }

    // MARK: - Bleed

    /// A microphone line that repeats the computer's audio heard through the speakers (`BleedSuppression`).
    private func isBleed(_ segment: TranscriptSegment) -> Bool {
        guard segment.channel == .microphone else { return false }
        let system = segments.filter { $0.channel == .system && $0.range.overlap(with: segment.range) > 0 }
        return BleedSuppression.isBleed(segment, system: system)
    }

    /// Removes microphone lines that turn out to repeat the system line `segment` (the mic's copy is often
    /// finalised first).
    private func removeBleed(repeating segment: TranscriptSegment) {
        let bleed = Set(
            segments.filter { $0.channel == .microphone && $0.range.overlap(with: segment.range) > 0 && isBleed($0) }
                .map(\.id))
        guard !bleed.isEmpty else { return }
        segments.removeAll { bleed.contains($0.id) }
        journal?.append(.removed(Array(bleed)))
        attentionItems.removeAll { bleed.contains($0.segmentID) }
        bleedLinesRemoved += bleed.count
    }

    /// Audio either side of a line included when it's re-transcribed, so edge words aren't clipped.
    private static let reroutePadding: TimeInterval = 0.1

    /// Re-transcribes a line from the archived audio with its speaker's engine/language, then analyses it.
    private func reroute(_ segment: TranscriptSegment, with route: EngineRoute, archive: MeetingAudioArchive) {
        let library = self.library
        let prompt = voices.prompt
        let deepgramModel = route.deepgramModel ?? config.deepgramModel
        let range = TimeRange(
            start: max(0, segment.range.start - Self.reroutePadding), end: segment.range.end + Self.reroutePadding)
        rerouteTasks.append(
            Task { [weak self] in
                let samples = await archive.waitForSamples(channel: segment.channel, range: range)
                var transcript: EngineTranscript?
                do {
                    if !samples.isEmpty {
                        let transcriber = try await library.transcriber(route.engine, deepgramModel: deepgramModel)
                        transcript = try await transcriber.transcribe(
                            samples16k: samples, languageCode: route.languageCode, prompt: prompt)
                    }
                } catch {
                    self?.rerouteFailed(route, error)
                }
                self?.finishReroute(segment.id, transcript: transcript, route: route)
            })
    }

    private func finishReroute(_ segmentID: UUID, transcript: EngineTranscript?, route: EngineRoute) {
        guard let i = segments.lastIndex(where: { $0.id == segmentID }) else { return }
        if let transcript, let text = transcript.text.nonEmpty {
            if let reason = transcript.modelFallbackReason { warn("\(reason) for some lines.") }
            segments[i].text = voices.customize(text, speakerKey: segments[i].speakerKey)
            segments[i].engine = transcript.engine
            if SessionVoices.languageCode(ofLocale: segments[i].localeID) != route.languageCode {
                segments[i].localeID = route.languageCode
                noteLocale(route.languageCode)
            }
        }
        // The new text may now show the line repeats (or is repeated by) the computer's audio.
        let segment = segments[i]
        if isBleed(segment) {
            segments.remove(at: i)
            journal?.append(.removed([segment.id]))
            bleedLinesRemoved += 1
            return
        }
        journalSegment(segment)
        if segment.channel == .system { removeBleed(repeating: segment) }
        enqueueAnalysis(of: segment)
    }

    private func rerouteFailed(_ route: EngineRoute, _ error: Error) {
        guard !rerouteFailureReported else { return }
        rerouteFailureReported = true
        warn(
            "\(SpeechModelLibrary.info(route.engine).displayName) couldn't re-transcribe a speaker's line (\(error.localizedDescription)); keeping the meeting engine's text."
        )
    }

    // MARK: - Direction / seats

    private func direction(during range: TimeRange) -> DirectionEstimate? {
        let inRange = directionHistory.filter { range.contains($0.time) }
        guard !inRange.isEmpty else { return nil }
        var x = 0.0, y = 0.0, w = 0.0
        for e in inRange {
            let a = e.azimuthDegrees * .pi / 180
            x += cos(a) * e.confidence
            y += sin(a) * e.confidence
            w += e.confidence
        }
        guard w > 0 else { return nil }
        var deg = atan2(y, x) * 180 / .pi
        if deg < 0 { deg += 360 }
        return DirectionEstimate(
            azimuthDegrees: deg, confidence: w / Double(inRange.count), time: (range.start + range.end) / 2)
    }

    private func addSeatEvidence(for turn: SpeakerTurn) {
        for e in directionHistory where turn.range.contains(e.time) {
            seatTracker.add(e, speakerKey: turn.speakerKey)
        }
        roster.setSeat(seatTracker.seat(for: turn.speakerKey), for: turn.speakerKey)
    }

    private func rebuildSeats() {
        seatTracker = SeatTracker()
        for turn in turns[.microphone] ?? [] {
            for e in directionHistory where turn.range.contains(e.time) {
                seatTracker.add(e, speakerKey: turn.speakerKey)
            }
        }
        for p in roster.participants where p.channel == .microphone {
            roster.setSeat(seatTracker.seat(for: p.id), for: p.id)
        }
    }

    private func rekey(_ oldKey: String, to newKey: String, profile: SpeakerProfile) {
        keyAliases[oldKey] = newKey
        for (k, v) in keyAliases where v == oldKey { keyAliases[k] = newKey }
        roster.setProfiles(profiles)
        roster.rekey(oldKey, to: newKey, profile: profile)
        for i in segments.indices where segments[i].speakerKey == oldKey { segments[i].speakerKey = newKey }
        journal?.append(.rekey(from: oldKey, to: newKey))
        for i in attentionItems.indices where attentionItems[i].speakerKey == oldKey {
            let a = attentionItems[i]
            attentionItems[i] = AttentionItem(
                id: a.id, kind: a.kind, segmentID: a.segmentID, speakerKey: newKey, time: a.time,
                utterance: a.utterance, text: a.text, detail: a.detail)
        }
        for channel in Array(turns.keys) {
            turns[channel] = turns[channel]?.map { t in
                guard t.speakerKey == oldKey else { return t }
                var t = t
                t.speakerKey = newKey
                t.profileID = profile.id
                return t
            }
        }
        let collector = self.collector
        Task { await collector.rekey(oldKey, to: newKey) }
        rebuildSeats()
        journalRoster(force: true)
    }

    // MARK: - Live analysis

    private struct AnalysisJob: Sendable {
        let line: ContextLine
        let context: [ContextLine]
    }

    private func launchAnalysis() {
        guard config.liveAnalysis, let engine else { return }
        let policy: AsyncStream<AnalysisJob>.Continuation.BufferingPolicy =
            config.mode == .live ? .bufferingNewest(max(1, config.analysisBacklog)) : .unbounded
        let (stream, input) = AsyncStream.makeStream(of: AnalysisJob.self, bufferingPolicy: policy)
        analysisInput = input
        analysisWorker = Task.detached { [weak self] in
            for await job in stream {
                do {
                    let insight = try await engine.analyze(utterance: job.line, recentContext: job.context)
                    await self?.apply(insight, to: job.line.segmentID)
                } catch is CancellationError {
                    return
                } catch IntelligenceError.refused {
                    // The model's safety filter declined this line: it simply gets no insight.
                    analysisLog.info("Live analysis of a line was declined by the safety filter; skipped")
                } catch {
                    await self?.analysisFailed(error)
                }
            }
        }
    }

    private func enqueueAnalysis(of segment: TranscriptSegment) {
        guard let analysisInput else { return }
        // Lines before this one: a re-transcribed line is analysed after later lines were added.
        let index = segments.lastIndex { $0.id == segment.id } ?? segments.endIndex
        let context = segments[..<index].suffix(config.analysisContextLines).map(contextLine)
        analysisInput.yield(AnalysisJob(line: contextLine(segment), context: Array(context)))
    }

    private func contextLine(_ s: TranscriptSegment) -> ContextLine {
        ContextLine(segmentID: s.id, speaker: roster.displayName(for: s.speakerKey), time: s.range.start, text: s.text)
    }

    private func apply(_ insight: UtteranceInsight, to segmentID: UUID) {
        guard let i = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        segments[i].insight = insight
        attentionItems.append(contentsOf: AttentionItem.items(for: insight, segment: segments[i]))
    }

    private func analysisFailed(_ error: Error) {
        guard !analysisFailureReported else { return }
        analysisFailureReported = true
        warn("Live analysis failed: \(error.localizedDescription)")
    }

    // MARK: - Finish

    private func waitForCaptureToEnd() async {
        for task in captureTasks { _ = await task.value }
    }

    private func generateReport(for meeting: Meeting) async -> MeetingReport? {
        guard let engine else { return nil }
        do {
            return try await ReportWriter.report(for: meeting, engine: engine, title: config.title)
        } catch let error as ReportWriter.ReportWriterError {
            reportError = error.localizedDescription
            return nil
        } catch {
            reportError = "The report couldn't be generated: \(error.localizedDescription)"
            return nil
        }
    }

    private func defaultTitle() -> String {
        if let sourceName { return sourceName }
        let date = (startedAt ?? Date()).formatted(date: .abbreviated, time: .shortened)
        if let app = detectedMeeting?.app.displayName { return "\(app) meeting, \(date)" }
        return kind == .online ? "Online meeting, \(date)" : "Meeting, \(date)"
    }

    /// Awaits `task`, cancelling it if it hasn't finished within `timeout`. Returns the task's value.
    @discardableResult
    private static func finish<T: Sendable>(_ task: Task<T, Never>, timeout: Duration?) async -> T {
        guard let timeout else { return await task.value }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { task.cancel() }
        }
        let value = await task.value
        timer.cancel()
        return value
    }
}
