import FluidAudio
import Foundation
import Speech
import Synchronization
import VCModels

/// Lifecycle of a voice model on this Mac.
public enum ModelStatus: Sendable, Hashable {
    case notDownloaded
    /// Fraction 0...1.
    case downloading(Double)
    /// Files present, not loaded in this process.
    case downloaded
    /// Loading and warming up (seconds per launch; Core ML's first-ever compile of a model takes longer).
    case loading
    /// Loaded and warm; transcribes immediately.
    case ready
    /// Last download or load failed; the message is user-facing.
    case failed(String)
}

/// What the user sees in the voice model picker.
public struct SpeechModelInfo: Sendable, Hashable, Identifiable {
    public var id: SpeechEngineKind { kind }
    public let kind: SpeechEngineKind
    /// "Cohere Transcribe", "Whisper Large v3 Turbo", "Apple Speech".
    public let displayName: String
    /// One line, user-facing.
    public let summary: String
    /// Approximate download size; 0 for Apple (built into macOS).
    public let downloadBytes: Int64
    /// ISO 639-1 languages the engine transcribes.
    public let languageCodes: [String]
    /// Word error rate on 54 African speakers of the Speech Accent Archive (lower is better).
    public let africanWordErrorRate: Double?

    public init(
        kind: SpeechEngineKind, displayName: String, summary: String, downloadBytes: Int64, languageCodes: [String],
        africanWordErrorRate: Double?
    ) {
        self.kind = kind
        self.displayName = displayName
        self.summary = summary
        self.downloadBytes = downloadBytes
        self.languageCodes = languageCodes
        self.africanWordErrorRate = africanWordErrorRate
    }
}

/// Owns model files under `root` (default ~/Library/Application Support/Voiccenger/Models), downloads, deletes, loads and keeps one warm instance per engine.
///
/// Layout under `root`: `cohere-transcribe/q8/` (FluidAudio's folder for `Repo.cohereTranscribeCoreml`) and
/// `whisper/` (WhisperKit `downloadBase`: `models/argmaxinc/whisperkit-coreml/<variant>` plus the tokenizer in
/// `models/openai/whisper-large-v3`). Apple Speech is part of macOS and always counts as ready when available.
public actor SpeechModelLibrary {
    public static let shared = SpeechModelLibrary(root: defaultRoot)

    /// ~/Library/Application Support/Voiccenger/Models
    public static var defaultRoot: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Voiccenger/Models", isDirectory: true)
    }

    public nonisolated let root: URL
    private nonisolated let broadcaster: StatusBroadcaster
    private var instances: [SpeechEngineKind: any AccurateTranscriber] = [:]
    private var downloads: [SpeechEngineKind: Task<Void, any Error>] = [:]
    private var loads: [SpeechEngineKind: Task<any AccurateTranscriber, any Error>] = [:]

    public init(root: URL) {
        self.root = root
        var statuses: [SpeechEngineKind: ModelStatus] = [:]
        for kind in SpeechEngineKind.allCases {
            statuses[kind] = Self.filesStatus(kind, root: root)
        }
        broadcaster = StatusBroadcaster(statuses)
    }

    // MARK: - Catalogue

    public nonisolated static func info(_ kind: SpeechEngineKind) -> SpeechModelInfo {
        switch kind {
        case .cohere:
            SpeechModelInfo(
                kind: .cohere, displayName: "Cohere Transcribe",
                summary: "Most accurate on accented English, including African accents. 14 languages; warms up for a few seconds per launch.",
                downloadBytes: 2_220_000_000, languageCodes: CohereTranscriber.languageCodes, africanWordErrorRate: 0.043)
        case .whisper:
            SpeechModelInfo(
                kind: .whisper, displayName: "Whisper Large v3 Turbo",
                summary: "Close second on accents, with word timings and name hints. 100 languages including Swahili, Yoruba, Hausa and Amharic.",
                downloadBytes: 1_660_000_000, languageCodes: WhisperTranscriber.languageCodes, africanWordErrorRate: 0.051)
        case .apple:
            SpeechModelInfo(
                kind: .apple, displayName: "Apple Speech",
                summary: "Built into macOS: instant live text, nothing to download, but the weakest on accented speech.",
                downloadBytes: 0, languageCodes: appleLanguageCodes, africanWordErrorRate: 0.101)
        }
    }

    /// Most accurate on accents first.
    public nonisolated static var allInfo: [SpeechModelInfo] { [.cohere, .whisper, .apple].map(info) }

    /// Languages macOS 26 SpeechTranscriber transcribes.
    static let appleLanguageCodes = ["en", "fr", "de", "es", "it", "pt", "ja", "ko", "zh", "yue"]

    // MARK: - Status

    public func status(_ kind: SpeechEngineKind) -> ModelStatus {
        broadcaster.status(kind)
    }

    /// Multicast: every subscriber gets updates; yields current statuses on subscribe.
    public nonisolated var statusUpdates: AsyncStream<(SpeechEngineKind, ModelStatus)> {
        broadcaster.subscribe()
    }

    public func isReady(_ kind: SpeechEngineKind) -> Bool {
        kind == .apple ? SpeechTranscriber.isAvailable : instances[kind] != nil
    }

    /// True when every file the engine loads is present (always true for Apple).
    public nonisolated func isDownloaded(_ kind: SpeechEngineKind) -> Bool {
        Self.filesPresent(kind, root: root)
    }

    // MARK: - Download / delete

    /// Idempotent; concurrent calls share one download. Progress via `statusUpdates`.
    public func download(_ kind: SpeechEngineKind) async throws {
        guard kind != .apple else { return }
        if let running = downloads[kind] { return try await running.value }
        if isDownloaded(kind) {
            if case .failed = broadcaster.status(kind) { broadcaster.set(kind, .downloaded) }
            if case .notDownloaded = broadcaster.status(kind) { broadcaster.set(kind, .downloaded) }
            return
        }
        broadcaster.set(kind, .downloading(0))
        let root = root
        let broadcaster = broadcaster
        let task = Task {
            try await Self.fetch(kind, root: root) { broadcaster.progress(kind, $0) }
            guard Self.filesPresent(kind, root: root) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [
                    NSLocalizedDescriptionKey: "The \(Self.info(kind).displayName) download is incomplete."
                ])
            }
        }
        downloads[kind] = task
        do {
            try await task.value
            if downloads[kind] == task {
                downloads[kind] = nil
                broadcaster.set(kind, .downloaded)
                transcriptionLog.info("Downloaded \(kind.rawValue, privacy: .public) to \(root.path, privacy: .public)")
            }
        } catch {
            if downloads[kind] == task {
                downloads[kind] = nil
                broadcaster.set(kind, .failed(error.localizedDescription))
                transcriptionLog.error("Downloading \(kind.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            throw error
        }
    }

    /// Cancels a running download or load, unloads the engine and removes its files. No-op for Apple.
    public func delete(_ kind: SpeechEngineKind) throws {
        guard kind != .apple else { return }
        downloads.removeValue(forKey: kind)?.cancel()
        loads.removeValue(forKey: kind)?.cancel()
        instances[kind] = nil
        for url in Self.storage(kind, root: root) where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        broadcaster.set(kind, .notDownloaded)
    }

    // MARK: - Loading

    /// Load + warm-up inference; status → `.ready`. Throws `TranscriptionError.modelNotDownloaded` when files are missing.
    public func prewarm(_ kind: SpeechEngineKind) async throws {
        _ = try await transcriber(kind)
    }

    /// Ready instance (loads/warms if needed; throws if not downloaded). `.apple` returns an Apple-backed offline transcriber.
    public func transcriber(_ kind: SpeechEngineKind) async throws -> any AccurateTranscriber {
        if kind == .apple {
            guard SpeechTranscriber.isAvailable else { throw TranscriptionError.speechTranscriberUnavailable }
            return AppleOfflineTranscriber()
        }
        if let instance = instances[kind] { return instance }
        if let running = loads[kind] { return try await running.value }
        guard isDownloaded(kind) else { throw TranscriptionError.modelNotDownloaded(kind) }
        broadcaster.set(kind, .loading)
        let root = root
        let task = Task<any AccurateTranscriber, any Error> {
            let start = ContinuousClock.now
            let engine = try await Self.load(kind, root: root)
            // The first inference specializes the Core ML graphs; doing it now keeps the first utterance fast.
            _ = try await engine.transcribe(samples16k: Self.warmUpSamples, languageCode: "en", prompt: [])
            transcriptionLog.info("\(kind.rawValue, privacy: .public) ready in \(ContinuousClock.now - start, privacy: .public)")
            return engine
        }
        loads[kind] = task
        do {
            let engine = try await task.value
            if loads[kind] == task {
                loads[kind] = nil
                instances[kind] = engine
                broadcaster.set(kind, .ready)
            }
            return engine
        } catch {
            if loads[kind] == task {
                loads[kind] = nil
                broadcaster.set(kind, .failed(error.localizedDescription))
                transcriptionLog.error("Loading \(kind.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            throw error
        }
    }

    // MARK: - Files

    static func cohereDirectory(root: URL) -> URL {
        root.appendingPathComponent(Repo.cohereTranscribeCoreml.folderName, isDirectory: true)
    }

    static func whisperBase(root: URL) -> URL {
        root.appendingPathComponent("whisper", isDirectory: true)
    }

    /// Top-level items `delete` removes.
    static func storage(_ kind: SpeechEngineKind, root: URL) -> [URL] {
        switch kind {
        case .apple: []
        case .cohere: [cohereDirectory(root: root).deletingLastPathComponent()]
        case .whisper: [whisperBase(root: root)]
        }
    }

    static func filesPresent(_ kind: SpeechEngineKind, root: URL) -> Bool {
        let fm = FileManager.default
        switch kind {
        case .apple:
            return true
        case .cohere:
            let dir = cohereDirectory(root: root)
            return CohereTranscriber.requiredFiles.allSatisfy { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
        case .whisper:
            let base = whisperBase(root: root)
            let model = WhisperTranscriber.modelFolder(base: base)
            let tokenizer = WhisperTranscriber.tokenizerFolder(base: base).appendingPathComponent("tokenizer.json")
            return fm.fileExists(atPath: tokenizer.path)
                && WhisperTranscriber.requiredModels.allSatisfy { fm.fileExists(atPath: model.appendingPathComponent($0).path) }
        }
    }

    private static func filesStatus(_ kind: SpeechEngineKind, root: URL) -> ModelStatus {
        if kind == .apple {
            return SpeechTranscriber.isAvailable ? .ready : .failed(TranscriptionError.speechTranscriberUnavailable.localizedDescription)
        }
        return filesPresent(kind, root: root) ? .downloaded : .notDownloaded
    }

    private static func fetch(
        _ kind: SpeechEngineKind, root: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        switch kind {
        case .apple:
            return
        case .cohere:
            // `ModelHub.download` lands the files in `root/<folderName>`. It reports downloading as the first
            // half of a download+compile operation; the compiled models ship ready, so its 0...0.5 is our 0...1.
            try await ModelHub.download(.cohereTranscribeCoreml, to: root) { p in
                switch p.phase {
                case .listing: progress(0)
                case .downloading: progress(min(p.fractionCompleted * 2, 1))
                case .compiling: progress(1)
                }
            }
        case .whisper:
            try await WhisperTranscriber.download(base: whisperBase(root: root), progress: progress)
        }
    }

    private static func load(_ kind: SpeechEngineKind, root: URL) async throws -> any AccurateTranscriber {
        switch kind {
        case .apple: AppleOfflineTranscriber()
        case .cohere: try await CohereTranscriber.load(from: cohereDirectory(root: root))
        case .whisper: try await WhisperTranscriber.load(base: whisperBase(root: root))
        }
    }

    /// One second of quiet, deterministic noise.
    static let warmUpSamples: [Float] = {
        var state: UInt32 = 0x9E37_79B9
        return (0..<16_000).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Float(state >> 8) / Float(1 << 24) - 0.5) * 0.002
        }
    }()
}

/// Current statuses plus fan-out to every `statusUpdates` subscriber, in update order.
final class StatusBroadcaster: Sendable {
    private struct State {
        var statuses: [SpeechEngineKind: ModelStatus]
        var subscribers: [UUID: AsyncStream<(SpeechEngineKind, ModelStatus)>.Continuation] = [:]
    }

    private let state: Mutex<State>

    init(_ statuses: [SpeechEngineKind: ModelStatus]) {
        state = Mutex(State(statuses: statuses))
    }

    func status(_ kind: SpeechEngineKind) -> ModelStatus {
        state.withLock { $0.statuses[kind] ?? .notDownloaded }
    }

    func set(_ kind: SpeechEngineKind, _ status: ModelStatus) {
        state.withLock { state in
            guard state.statuses[kind] != status else { return }
            state.statuses[kind] = status
            for continuation in state.subscribers.values { continuation.yield((kind, status)) }
        }
    }

    /// Download progress: applied only while downloading, monotonic, in steps of at least 0.5 %.
    func progress(_ kind: SpeechEngineKind, _ fraction: Double) {
        state.withLock { state in
            guard case .downloading(let current) = state.statuses[kind] else { return }
            let next = min(max(fraction, 0), 1)
            guard next - current >= 0.005 || (next == 1 && current < 1) else { return }
            state.statuses[kind] = .downloading(next)
            for continuation in state.subscribers.values { continuation.yield((kind, .downloading(next))) }
        }
    }

    func subscribe() -> AsyncStream<(SpeechEngineKind, ModelStatus)> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: (SpeechEngineKind, ModelStatus).self, bufferingPolicy: .unbounded)
        let id = UUID()
        state.withLock { state in
            for kind in SpeechEngineKind.allCases {
                continuation.yield((kind, state.statuses[kind] ?? .notDownloaded))
            }
            state.subscribers[id] = continuation
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }
}
