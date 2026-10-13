@preconcurrency import AVFAudio
import CoreMedia
import Foundation
import Speech
import VCModels

/// One per channel. SpeechAnalyzer + SpeechTranscriber (volatile results, audioTimeRange, transcriptionConfidence).
/// Contextual strings (participant names, jargon) via AnalysisContext.
/// Language/accent auto-switch: keeps a rolling ~10 s audio buffer; when mean confidence of recent finals drops below threshold,
/// ranks candidate locales with AccentDetector on the buffer and restarts recognition in the winner (emits .localeChanged).
///
/// Audio of any sample rate is resampled once to a continuous 16 kHz session timeline; every buffer handed to the
/// analyzer after a gap carries its session-clock start time, so result and word ranges are session-clock seconds.
public actor LiveTranscriber {
    public let channel: AudioChannel
    public nonisolated let events: AsyncStream<TranscriptEvent>
    /// BCP-47 identifier of the recognition locale (normalized to the supported identifier once started).
    public private(set) var currentLocaleID: String

    private let eventContinuation: AsyncStream<TranscriptEvent>.Continuation
    private let autoLanguage: Bool
    private let candidateLocaleIDs: [String]
    private var contextualStrings: [String]
    private var policy = AutoLanguagePolicy()

    private var session: RecognitionSession?
    private var sessionCount = 0
    private let timeline = RecognitionTimeline()
    private var recentAudio: RollingAudioBuffer
    private var monitor: ConfidenceMonitor
    private var detectionTask: Task<Void, Never>?
    private var localeChange: Task<Void, any Error>?
    private var isFinished = false

    public init(
        channel: AudioChannel, localeID: String, contextualStrings: [String] = [], autoLanguage: Bool = true,
        candidateLocaleIDs: [String] = []
    ) {
        self.channel = channel
        self.currentLocaleID = localeID
        self.contextualStrings = contextualStrings
        self.autoLanguage = autoLanguage
        self.candidateLocaleIDs = candidateLocaleIDs
        let policy = AutoLanguagePolicy()
        self.recentAudio = RollingAudioBuffer(capacity: Int(policy.bufferSeconds * PCM.recognitionRate))
        self.monitor = ConfidenceMonitor(policy: policy)
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Replaces the auto-language tunables; confidence history is kept only if the window size is unchanged.
    public func setAutoLanguagePolicy(_ newPolicy: AutoLanguagePolicy) {
        policy = newPolicy
        monitor = ConfidenceMonitor(policy: newPolicy)
        let capacity = Int(newPolicy.bufferSeconds * PCM.recognitionRate)
        if capacity != recentAudio.capacity { recentAudio = RollingAudioBuffer(capacity: capacity) }
    }

    /// Installs the locale's assets if needed (may download), loads the model and starts recognition.
    public func start() async throws {
        guard !isFinished else { throw TranscriptionError.notRunning }
        guard session == nil else { return }
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.speechTranscriberUnavailable }
        try await SpeechAssets.ensureInstalled(localeIDs: [currentLocaleID])
        let locale = try await SpeechAssets.resolveInstalledLocale(currentLocaleID)
        let newSession = try await makeSession(locale: locale)
        guard session == nil, !isFinished else {
            await newSession.cancel()
            return
        }
        session = newSession
        currentLocaleID = newSession.localeID
    }

    /// Feeds audio. Any sample rate; chunks dropped while not running. Never blocks on recognition.
    public func append(_ chunk: AudioChunk) async {
        guard let session, !isFinished else { return }
        do {
            let spans = try timeline.ingest(
                samples: chunk.samples, sampleRate: chunk.sampleRate, startTime: chunk.startTime)
            for span in spans {
                recentAudio.append(span.samples)
                try session.feed(span)
            }
        } catch {
            transcriptionLog.error(
                "Dropping \(chunk.channel.rawValue, privacy: .public) audio at \(chunk.startTime): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Biases recognition toward names and jargon. Applies immediately and to later locale switches.
    public func setContextualStrings(_ strings: [String]) async {
        contextualStrings = strings
        guard let session else { return }
        do {
            try await session.analyzer.setContext(Self.context(strings))
        } catch {
            transcriptionLog.error("Setting contextual strings failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Restarts recognition in another locale: the old analyzer finalizes the audio it already has while new
    /// audio flows to the new one, the event stream stays open and `.localeChanged` is emitted.
    /// Installs the locale's assets if needed. Calls are serialized.
    public func setLocale(_ localeID: String, reason: String) async throws {
        let previous = localeChange
        let change = Task {
            _ = await previous?.result
            try await self.performLocaleChange(to: localeID, reason: reason)
        }
        localeChange = change
        try await change.value
    }

    /// Finalizes everything appended so far, delivers the last results, then finishes `events`.
    public func finish() async {
        guard !isFinished else { return }
        isFinished = true
        detectionTask?.cancel()
        _ = await localeChange?.result
        if let session {
            do {
                for span in try timeline.flush() { try session.feed(span) }
            } catch {
                transcriptionLog.error("Flushing resampler failed: \(error.localizedDescription, privacy: .public)")
            }
            await session.finish()
            self.session = nil
        }
        _ = await detectionTask?.value
        eventContinuation.finish()
    }

    // MARK: - Locale switching

    private func performLocaleChange(to localeID: String, reason: String) async throws {
        guard !isFinished, let old = session else { throw TranscriptionError.notRunning }
        try await SpeechAssets.ensureInstalled(localeIDs: [localeID])
        let locale = try await SpeechAssets.resolveInstalledLocale(localeID)
        let newID = locale.identifier(.bcp47)
        guard newID != currentLocaleID else { return }
        let newSession = try await makeSession(locale: locale)
        guard !isFinished, session === old else {
            await newSession.cancel()
            throw TranscriptionError.notRunning
        }
        // Swap without awaiting: audio appended from here on goes to the new analyzer (audio still inside the
        // 16 kHz resampler continues seamlessly into it), the old one finalizes what it already received.
        session = newSession
        let from = currentLocaleID
        currentLocaleID = newID
        monitor.resetHistory()
        eventContinuation.yield(.localeChanged(channel: channel, from: from, to: newID, reason: reason))
        transcriptionLog.info("\(self.channel.rawValue, privacy: .public) locale \(from, privacy: .public) → \(newID, privacy: .public): \(reason, privacy: .public)")
        await old.finish()
    }

    private func makeSession(locale: Locale) async throws -> RecognitionSession {
        sessionCount += 1
        let id = sessionCount
        let transcriber = TranscriberFactory.make(locale: locale, volatile: true)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.noCompatibleAudioFormat
        }
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering))
        let converter = try PCMStreamConverter(from: PCM.monoFloatFormat(sampleRate: PCM.recognitionRate), to: format)
        try await analyzer.prepareToAnalyze(in: format)
        if !contextualStrings.isEmpty { try await analyzer.setContext(Self.context(contextualStrings)) }

        let (input, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let localeID = locale.identifier(.bcp47)
        let channel = channel
        let results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let update = ResultMapper.update(from: result, channel: channel, localeID: localeID)
                    else { continue }
                    await self?.receive(update, isFinal: result.isFinal, generation: id)
                }
            } catch is CancellationError {
            } catch {
                transcriptionLog.error("\(localeID, privacy: .public) results failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        do {
            try await analyzer.start(inputSequence: input)
        } catch {
            inputContinuation.finish()
            await analyzer.cancelAndFinishNow()
            results.cancel()
            throw error
        }
        return RecognitionSession(
            generation: id, localeID: localeID, analyzer: analyzer, converter: converter,
            input: inputContinuation, results: results)
    }

    private static func context(_ strings: [String]) -> AnalysisContext {
        let context = AnalysisContext()
        context.contextualStrings[.general] = strings
        return context
    }

    // MARK: - Results and auto language

    private func receive(_ update: TranscriptUpdate, isFinal: Bool, generation id: Int) {
        guard isFinal else {
            eventContinuation.yield(.volatile(update))
            return
        }
        eventContinuation.yield(.final(update))
        guard id == session?.generation else { return }
        monitor.record(update)
        considerLanguageCheck(at: update.range.end)
    }

    private func considerLanguageCheck(at time: TimeInterval) {
        guard autoLanguage, !isFinished, detectionTask == nil,
            Double(recentAudio.count) >= policy.minimumBufferSeconds * PCM.recognitionRate,
            monitor.shouldCheck(at: time)
        else { return }
        let samples = recentAudio.snapshot()
        let current = currentLocaleID
        let explicit = candidateLocaleIDs
        let policy = policy
        let observed = monitor.meanConfidence
        detectionTask = Task(priority: .utility) { [weak self] in
            let installed = await SpeechAssets.installedLocaleIDs()
            let candidates = CandidateSelection.candidates(
                current: current, explicit: explicit, installed: installed, limit: policy.maximumCandidates)
            var decision: (localeID: String, reason: String)?
            if candidates.count > 1 {
                do {
                    let scores = try await AccentDetector().rank(
                        samples: samples, sampleRate: PCM.recognitionRate, candidateLocaleIDs: candidates)
                    decision = Self.decide(scores: scores, current: current, observed: observed, policy: policy)
                } catch is CancellationError {
                } catch {
                    transcriptionLog.error("Language check failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            await self?.completeLanguageCheck(decision)
        }
    }

    private func completeLanguageCheck(_ decision: (localeID: String, reason: String)?) async {
        detectionTask = nil
        guard let decision, !isFinished else { return }
        do {
            try await setLocale(decision.localeID, reason: decision.reason)
        } catch {
            transcriptionLog.error("Automatic switch to \(decision.localeID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Picks the winner when it beats the current locale's score on the same audio by the required margin.
    static func decide(scores: [LocaleScore], current: String, observed: Double?, policy: AutoLanguagePolicy)
        -> (localeID: String, reason: String)?
    {
        guard let best = scores.first, best.localeID != current, best.wordCount > 0 else { return nil }
        let baseline = scores.first { $0.localeID == current }?.meanConfidence ?? observed ?? 0
        guard best.meanConfidence - baseline >= policy.minimumImprovement else { return nil }
        let reason = String(
            format: "Low recognition confidence (%.2f in %@); %@ scored %.2f on the last %.0f s",
            baseline, current, best.localeID, best.meanConfidence, policy.bufferSeconds)
        return (best.localeID, reason)
    }
}

/// One analyzer run in one locale. Owned and used only by its `LiveTranscriber` actor.
private final class RecognitionSession {
    let generation: Int
    let localeID: String
    let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let results: Task<Void, Never>
    private let converter: PCMStreamConverter
    private var expectedFrame: Int64 = -1
    private var pendingStartTime: CMTime?

    init(
        generation: Int, localeID: String, analyzer: SpeechAnalyzer, converter: PCMStreamConverter,
        input: AsyncStream<AnalyzerInput>.Continuation, results: Task<Void, Never>
    ) {
        self.generation = generation
        self.localeID = localeID
        self.analyzer = analyzer
        self.converter = converter
        self.input = input
        self.results = results
    }

    /// Converts a 16 kHz timeline span to the analyzer format. Spans that don't continue the previous
    /// one (first span, gaps) carry their session-clock start time.
    func feed(_ span: RecognitionTimeline.Span) throws {
        if span.startFrame != expectedFrame {
            if expectedFrame >= 0 { yield(try converter.flush()) }
            pendingStartTime = CMTime(value: span.startFrame, timescale: CMTimeScale(PCM.recognitionRate))
        }
        expectedFrame = span.startFrame + Int64(span.samples.count)
        yield(try converter.convert(PCM.monoFloatBuffer(span.samples, format: converter.inputFormat)))
    }

    private func yield(_ buffers: [AVAudioPCMBuffer]) {
        for buffer in buffers {
            input.yield(AnalyzerInput(buffer: buffer, bufferStartTime: pendingStartTime))
            pendingStartTime = nil
        }
    }

    /// Ends input, finalizes all pending audio and waits until the last result was delivered.
    nonisolated(nonsending) func finish() async {
        do {
            yield(try converter.flush())
        } catch {
            transcriptionLog.error("Flushing analyzer converter failed: \(error.localizedDescription, privacy: .public)")
        }
        input.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            transcriptionLog.error("Finalizing \(self.localeID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            await analyzer.cancelAndFinishNow()
        }
        await results.value
    }

    /// Abandons the session without delivering further results.
    nonisolated(nonsending) func cancel() async {
        input.finish()
        await analyzer.cancelAndFinishNow()
        results.cancel()
        await results.value
    }
}
