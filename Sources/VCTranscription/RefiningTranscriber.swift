import Foundation
import VCModels

/// Live transcription: Apple streams volatile text immediately; each Apple final's audio is re-transcribed by `engine` (when ready) and emitted as the final.
/// If the engine isn't ready (downloading/warming/failed) the Apple final passes through unchanged (engine = .apple).
/// Words of refined finals get times via TimingTransfer from Apple's words.
///
/// Refinement window: the engines are far more accurate on a passage than on single sentences, so
/// consecutive Apple finals separated by pauses shorter than `joinPauseSeconds` are collected (up to
/// `maximumWindowSeconds`) and their audio is transcribed as one, emitted as one final spanning them.
/// Until then the collected text is shown as volatile — every volatile event carries the text of windows
/// being refined + the open window + Apple's current volatile, so nothing disappears from the preview.
/// A window closes when the next final starts after a long pause, when it would grow too long, when no
/// speech follows for `joinPauseSeconds` of audio, on a language switch, or at `finish()`.
/// Audio is cut from a rolling buffer: from the window's first range (a little earlier when there's a gap,
/// never before the previous window) to its last range's end, plus a little of the following pause only when
/// it is known to be silent. A window cut by the length limit ends at an Apple-final boundary. A refined final
/// whose opening repeats the end of the previous final (engines sometimes run on past the audio) loses that
/// repeat before it is emitted.
public actor RefiningTranscriber {
    public let channel: AudioChannel
    public nonisolated let events: AsyncStream<TranscriptEvent>

    /// Finals whose words are this close are refined together.
    public static let joinPauseSeconds = SpeechChunker.joinPauseSeconds
    /// Upper bound of one refinement window (Cohere's encoder sees 35 s).
    public static let maximumWindowSeconds = SpeechChunker.maximumSeconds
    /// Audio kept before a window's start (when Apple's ranges leave a gap).
    static let leadingPadding: TimeInterval = 0.15

    private let eventContinuation: AsyncStream<TranscriptEvent>.Continuation
    private let live: LiveTranscriber
    private let engine: SpeechEngineKind
    private let customization: VoiceSettings?
    private let library: SpeechModelLibrary
    private let waitForEngine: Bool
    private var languageCode: String
    private var prompt: [String]

    private let timeline = RecognitionTimeline()
    private var audio = SessionAudio(capacitySeconds: 120)
    private var audioEnd: TimeInterval = 0
    /// End of the audio already handed to a job; windows never reach back before it.
    private var consumedEnd: TimeInterval = 0
    /// Apple finals waiting to be refined together.
    private var window: [TranscriptUpdate] = []
    /// Closed windows not yet emitted, oldest first.
    private var pending: [Job] = []
    private var currentVolatile: TranscriptUpdate?
    private var nextJobID = 0
    /// Text of the last final emitted, to drop a refined window's repeat of it.
    private var lastEmittedText = ""

    private let jobs: AsyncStream<Job>
    private let jobContinuation: AsyncStream<Job>.Continuation
    private var pump: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var isStarted = false
    private var isFinished = false

    /// - Parameters:
    ///   - appleLocaleID: locale of the live Apple preview (e.g. "en-GB").
    ///   - languageCode: ISO 639-1 language the engine transcribes; follows Apple's automatic language switches.
    ///   - prompt: names and terms; Apple contextual strings and Whisper prompt.
    ///   - customization: applied to every event's text; nil leaves text unchanged.
    ///   - waitForEngine: offline processing — wait for the engine to load instead of passing Apple finals
    ///     through (Apple is still used when the engine is not downloaded or fails).
    public init(
        channel: AudioChannel, appleLocaleID: String, engine: SpeechEngineKind, languageCode: String,
        prompt: [String], customization: VoiceSettings?, library: SpeechModelLibrary = .shared,
        autoLanguage: Bool = true, waitForEngine: Bool = false
    ) {
        self.channel = channel
        self.engine = engine
        self.languageCode = baseLanguageCode(languageCode)
        self.prompt = prompt
        self.customization = customization
        self.library = library
        self.waitForEngine = waitForEngine
        live = LiveTranscriber(
            channel: channel, localeID: appleLocaleID, contextualStrings: prompt, autoLanguage: autoLanguage)
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (jobs, jobContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Starts Apple recognition (installing its assets if needed). The engine is used once it is ready.
    public func start() async throws {
        guard !isFinished else { throw TranscriptionError.notRunning }
        guard !isStarted else { return }
        try await live.start()
        isStarted = true
        let liveEvents = live.events
        pump = Task { [weak self] in
            for await event in liveEvents {
                guard let self else { return }
                await self.receive(event)
            }
            await self?.endOfInput()
        }
        let jobs = jobs
        worker = Task { [weak self] in
            for await job in jobs {
                guard let self else { return }
                let finals = await self.refine(job)
                await self.complete(job, with: finals)
            }
        }
    }

    /// Feeds audio (any sample rate). Dropped before `start()` and after `finish()`.
    public func append(_ chunk: AudioChunk) async {
        guard isStarted, !isFinished else { return }
        do {
            for span in try timeline.ingest(samples: chunk.samples, sampleRate: chunk.sampleRate, startTime: chunk.startTime) {
                audio.append(span)
            }
        } catch {
            transcriptionLog.error("Buffering \(self.channel.rawValue, privacy: .public) audio failed: \(error.localizedDescription, privacy: .public)")
        }
        audioEnd = max(audioEnd, chunk.range.end)
        closeWindowAfterSilence()
        await live.append(chunk)
    }

    /// Names and terms for Apple's contextual strings and the engine prompt; applies to later windows.
    public func setPrompt(_ prompt: [String]) async {
        self.prompt = prompt
        await live.setContextualStrings(prompt)
    }

    /// Waits for in-flight refinements, then finishes events.
    public func finish() async {
        guard !isFinished else { return }
        isFinished = true
        if isStarted {
            do {
                for span in try timeline.flush() { audio.append(span) }
            } catch {
                transcriptionLog.error("Flushing \(self.channel.rawValue, privacy: .public) audio failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        await live.finish()
        await pump?.value
        endOfInput()
        await worker?.value
        eventContinuation.finish()
    }

    // MARK: - Windows

    private struct Job: Sendable {
        let id: Int
        let finals: [TranscriptUpdate]
        let samples: [Float]
        let languageCode: String
        let prompt: [String]
        let refine: Bool
    }

    private func receive(_ event: TranscriptEvent) async {
        switch event {
        case .volatile(let update):
            currentVolatile = update
            emitPreview()
        case .final(let update):
            currentVolatile = nil
            var refine = engine != .apple
            if refine, !waitForEngine { refine = await library.isReady(engine) }
            guard refine else {
                // Apple text goes out at once; anything collected while the engine was ready goes first.
                closeWindow()
                enqueue([update], refine: false)
                return
            }
            if let last = window.last {
                let pause = Self.firstWordStart(update) - Self.lastWordEnd(last)
                let length = update.range.end - windowAudioStart
                if pause >= Self.joinPauseSeconds {
                    closeWindow(trailingSilence: Self.firstWordStart(update) - last.range.end)
                } else if length > Self.maximumWindowSeconds {
                    // Cut at the Apple-final boundary; the next speech starts right there.
                    closeWindow()
                }
            }
            window.append(update)
            if update.range.end - windowAudioStart >= Self.maximumWindowSeconds { closeWindow() }
            emitPreview()
        case .localeChanged(_, _, let to, _):
            closeWindow()
            languageCode = baseLanguageCode(to)
            eventContinuation.yield(event)
        }
    }

    /// Closes the open window when no speech followed its last word: Apple shows nothing new and
    /// `joinPauseSeconds` + `recognitionLagSeconds` of audio went by (Apple reports speech a little after
    /// hearing it, so a quiet stretch at the end of the fed audio may still be someone talking).
    private func closeWindowAfterSilence() {
        guard let last = window.last, currentVolatile == nil else { return }
        guard audioEnd - Self.lastWordEnd(last) >= Self.joinPauseSeconds + Self.recognitionLagSeconds else { return }
        closeWindow(trailingSilence: audioEnd - Self.recognitionLagSeconds - last.range.end)
    }

    /// Upper bound on how far Apple's results trail the audio fed to it.
    static let recognitionLagSeconds: TimeInterval = 2

    private func endOfInput() {
        closeWindow()
        jobContinuation.finish()
    }

    private var windowAudioStart: TimeInterval {
        max((window.first?.range.start ?? consumedEnd) - Self.leadingPadding, consumedEnd)
    }

    /// - Parameter trailingSilence: audio known to be silent after the last final's end; up to
    ///   `trailingPadding` of it is included so a final word Apple cut short isn't clipped. Nothing after the
    ///   end is included otherwise — the next speech may start there.
    private func closeWindow(trailingSilence: TimeInterval = 0) {
        guard !window.isEmpty else { return }
        enqueue(window, refine: true, trailingSilence: trailingSilence)
        window = []
    }

    /// Silence kept after a window's last final when the pause is known.
    static let trailingPadding: TimeInterval = 0.3

    private func enqueue(_ finals: [TranscriptUpdate], refine: Bool, trailingSilence: TimeInterval = 0) {
        guard let last = finals.last else { return }
        let start = max((finals.first?.range.start ?? 0) - Self.leadingPadding, consumedEnd)
        let end = last.range.end + min(max(trailingSilence, 0), Self.trailingPadding)
        let samples = refine ? audio.samples(from: start, to: end) : []
        consumedEnd = max(consumedEnd, end)
        audio.discard(before: consumedEnd - Self.leadingPadding)
        nextJobID += 1
        let job = Job(
            id: nextJobID, finals: finals, samples: samples, languageCode: languageCode, prompt: prompt, refine: refine)
        pending.append(job)
        jobContinuation.yield(job)
    }

    /// Emits a job's finals and drops its text from the preview in one step, then refreshes the preview.
    private func complete(_ job: Job, with finals: [TranscriptUpdate]) {
        pending.removeAll { $0.id == job.id }
        for final in finals {
            eventContinuation.yield(.final(final))
            lastEmittedText = final.text
        }
        if !pending.isEmpty || !window.isEmpty || currentVolatile != nil { emitPreview() }
    }

    /// One volatile event with everything not yet final: windows being refined, the open window and
    /// Apple's current volatile text.
    private func emitPreview() {
        let parts = pending.flatMap(\.finals) + window + (currentVolatile.map { [$0] } ?? [])
        guard let first = parts.first, let last = parts.last else { return }
        let combined = TranscriptUpdate(
            channel: channel, text: parts.map(\.text).joined(separator: " "),
            range: TimeRange(start: first.range.start, end: last.range.end), confidence: nil,
            localeID: last.localeID, words: parts.flatMap(\.words), engine: .apple)
        eventContinuation.yield(.volatile(customized(combined, engine: .apple)))
    }

    // MARK: - Refinement

    private func refine(_ job: Job) async -> [TranscriptUpdate] {
        let apple = job.finals.map { customized($0, engine: .apple) }
        guard job.refine, !job.samples.isEmpty, let transcriber = await readyTranscriber() else { return apple }
        do {
            let refined = try await Self.refineWindow(
                job.finals, samples: job.samples, with: transcriber, languageCode: job.languageCode,
                prompt: job.prompt, customization: customization, previousText: lastEmittedText)
            switch refined {
            case .heardNothing: return apple
            case .duplicate: return []
            case .final(let update): return [update]
            }
        } catch {
            transcriptionLog.error("\(self.engine.rawValue, privacy: .public) refinement failed; keeping Apple text: \(error.localizedDescription, privacy: .public)")
            return apple
        }
    }

    enum WindowResult: Equatable {
        /// The engine returned no text; keep Apple's finals.
        case heardNothing
        /// Everything the engine wrote repeats the end of the previous final.
        case duplicate
        case final(TranscriptUpdate)
    }

    /// Transcribes one window's audio with `transcriber` and builds its final: customized text over the
    /// window's range, words timed from Apple's, minus any opening that repeats the end of `previousText`.
    static func refineWindow(
        _ finals: [TranscriptUpdate], samples: [Float], with transcriber: any AccurateTranscriber,
        languageCode: String, prompt: [String], customization: VoiceSettings?, previousText: String
    ) async throws -> WindowResult {
        let result = try await transcriber.transcribe(samples16k: samples, languageCode: languageCode, prompt: prompt)
        let raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let first = finals.first, let last = finals.last else { return .heardNothing }
        let text = customization.map { TranscriptCustomizer.apply(raw, settings: $0, extraVocabulary: prompt) } ?? raw
        let range = TimeRange(start: first.range.start, end: last.range.end)
        let update = TranscriptUpdate(
            channel: last.channel, text: text, range: range, confidence: nil, localeID: last.localeID,
            words: TimingTransfer.align(text: text, reference: finals.flatMap(\.words), range: range),
            engine: result.engine)
        return removingOverlap(update, after: previousText).map(WindowResult.final) ?? .duplicate
    }

    /// Longest repeated stretch considered, and the shortest that counts as a repeat (shorter matches
    /// like "and the" happen naturally).
    static let maximumOverlapTokens = 12
    static let minimumOverlapTokens = 3

    /// Drops the opening tokens of `update` that repeat the closing tokens of `previous`, with their word
    /// timings; the range then starts at the first kept word. Nil when nothing remains.
    ///
    /// Tokens compare as lower-cased letters and digits. A repeat is 3–12 opening tokens matching the end of
    /// `previous` within one token edit per four ("plastic of snake" vs "plastic snake" — the two windows
    /// were decoded separately); a 3-token repeat must match exactly. The longest repeat wins.
    static func removingOverlap(_ update: TranscriptUpdate, after previous: String) -> TranscriptUpdate? {
        let tokens = TextTokens.split(update.text)
        let previousKeys = Array(
            TextTokens.split(previous).map(TextTokens.key).filter { !$0.isEmpty }.suffix(maximumOverlapTokens + 2))
        let keys = tokens.map(TextTokens.key)
        let longest = min(maximumOverlapTokens, keys.count)
        guard longest >= minimumOverlapTokens, previousKeys.count >= minimumOverlapTokens else { return update }
        var overlap: Int?
        search: for n in stride(from: longest, through: minimumOverlapTokens, by: -1) {
            let head = Array(keys.prefix(n))
            // The repeat must run to the very end of the previous text.
            guard !head.contains(""), head.last == previousKeys.last else { continue }
            let allowed = n / 4
            let shortest = max(minimumOverlapTokens, n - allowed)
            let longestSuffix = min(previousKeys.count, n + allowed)
            guard shortest <= longestSuffix else { continue }
            for m in shortest...longestSuffix {
                if SequenceAlignment.distance(Array(previousKeys.suffix(m)), head) <= allowed {
                    overlap = n
                    break search
                }
            }
        }
        guard let overlap else { return update }
        guard overlap < tokens.count else { return nil }
        var trimmed = update
        var kept = tokens.dropFirst(overlap).joined(separator: " ")
        if let last = previous.trimmingCharacters(in: .whitespaces).last, ".!?".contains(last),
            let first = kept.first, first.isLowercase
        {
            kept = first.uppercased() + kept.dropFirst()
        }
        trimmed.text = kept
        if update.words.count == tokens.count {
            trimmed.words = Array(update.words.dropFirst(overlap))
            trimmed.words[0].text = String(kept.prefix { !$0.isWhitespace })
            trimmed.range = TimeRange(start: trimmed.words[0].range.start, end: update.range.end)
        } else {
            trimmed.words = TimingTransfer.align(text: kept, reference: update.words, range: update.range)
        }
        return trimmed
    }

    private func readyTranscriber() async -> (any AccurateTranscriber)? {
        if !waitForEngine {
            guard await library.isReady(engine) else { return nil }
        }
        do {
            return try await library.transcriber(engine)
        } catch {
            transcriptionLog.info("\(self.engine.rawValue, privacy: .public) unavailable; using Apple text: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func customized(_ update: TranscriptUpdate, engine: SpeechEngineKind) -> TranscriptUpdate {
        var result = update
        result.engine = engine
        guard let customization else { return result }
        let text = TranscriptCustomizer.apply(update.text, settings: customization, extraVocabulary: prompt)
        guard text != update.text else { return result }
        result.text = text
        result.words = TimingTransfer.align(text: text, reference: update.words, range: update.range)
        return result
    }

    private static func firstWordStart(_ update: TranscriptUpdate) -> TimeInterval {
        update.words.first?.range.start ?? update.range.start
    }

    private static func lastWordEnd(_ update: TranscriptUpdate) -> TimeInterval {
        update.words.last?.range.end ?? update.range.end
    }
}

/// Recent 16 kHz audio of one channel, addressed by session-clock frame. Gaps in the input are kept as silence.
struct SessionAudio {
    let capacity: Int
    private(set) var startFrame: Int64 = 0
    private(set) var samples: [Float] = []

    init(capacitySeconds: Double) {
        capacity = Int(capacitySeconds * PCM.recognitionRate)
    }

    var endFrame: Int64 { startFrame + Int64(samples.count) }

    mutating func append(_ span: RecognitionTimeline.Span) {
        if samples.isEmpty {
            startFrame = span.startFrame
            samples = span.samples
        } else if span.startFrame >= endFrame {
            let gap = Int(span.startFrame - endFrame)
            if gap > capacity {
                startFrame = span.startFrame
                samples = span.samples
            } else {
                samples.append(contentsOf: repeatElement(0, count: gap))
                samples += span.samples
            }
        } else {
            let overlap = Int(endFrame - span.startFrame)
            guard overlap < span.samples.count else { return }
            samples += span.samples[overlap...]
        }
        // Trim in batches so appends stay cheap.
        if samples.count > capacity + capacity / 4 { dropFirst(samples.count - capacity) }
    }

    /// Audio between two session times, clamped to what is buffered.
    func samples(from start: TimeInterval, to end: TimeInterval) -> [Float] {
        let first = max(Int64((start * PCM.recognitionRate).rounded()), startFrame)
        let last = min(Int64((end * PCM.recognitionRate).rounded()), endFrame)
        guard last > first else { return [] }
        return Array(samples[Int(first - startFrame)..<Int(last - startFrame)])
    }

    /// Releases audio before `time` once at least 10 s can go.
    mutating func discard(before time: TimeInterval) {
        let frame = min(Int64((time * PCM.recognitionRate).rounded()), endFrame)
        let count = Int(frame - startFrame)
        if count >= Int(10 * PCM.recognitionRate) { dropFirst(count) }
    }

    private mutating func dropFirst(_ count: Int) {
        samples.removeFirst(count)
        startFrame += Int64(count)
    }
}
