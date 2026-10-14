import Foundation
import VCModels

/// Live transcription of one channel by Deepgram (Nova-3 unless `Options.model` names another) over a
/// WebSocket, as Granola does it: audio is resampled to 16 kHz Int16 and streamed; interim results become
/// `.volatile` events and finals `.final` events with Deepgram's punctuated words on the session clock.
///
/// Timing: Deepgram's times count seconds of audio received on the current connection. `StreamClock` maps
/// them back to the session clock, including across gaps in the input and after a reconnect.
///
/// Resilience: a dropped connection is reopened with backoff. Audio sent but not yet covered by a final is
/// sent again on the new connection, and audio arriving meanwhile is buffered (up to `maximumBufferSeconds`).
/// When there's no usable key, Deepgram rejects it, the socket doesn't open within `connectTimeout`, or the
/// buffer overflows while reconnecting, the channel switches to on-device transcription (the buffered audio
/// goes there too) and the reason is reported as the library's Deepgram status.
///
/// Prompt changes apply from the next connection (keyterms are fixed per connection).
public actor DeepgramLiveTranscriber: ChannelTranscriber {
    public struct Options: Sendable {
        public var connectTimeout: Duration = .seconds(5)
        /// `KeepAlive` is sent when no audio went out for this long (Deepgram closes idle streams after 10 s).
        public var keepAliveInterval: Duration = .seconds(5)
        /// After `CloseStream`, how long `finish()` waits for the last finals.
        public var finishTimeout: Duration = .seconds(5)
        /// Audio kept while reconnecting before giving up on Deepgram for this channel.
        public var maximumBufferSeconds: Double = 30
        /// Delays before reconnect attempts; the last repeats.
        public var reconnectDelays: [Duration] = [.milliseconds(250), .seconds(1), .seconds(2), .seconds(4)]
        /// Deepgram model to stream with. One that can't stream the language (or that Deepgram refuses) is
        /// replaced by Nova-3, with the reason in `modelFallbackReason`.
        public var model: String = Deepgram.defaultModel

        public init() {}
    }

    public let channel: AudioChannel
    public nonisolated let events: AsyncStream<TranscriptEvent>
    private let eventContinuation: AsyncStream<TranscriptEvent>.Continuation

    private let localeID: String
    private let languageCode: String
    private var prompt: [String]
    private let library: SpeechModelLibrary
    private let options: Options
    private let makeFallback: @Sendable ([String]) -> any ChannelTranscriber
    /// The model and `language` of the stream, settled by `start()`.
    private var model = Deepgram.defaultModel
    private var streamLanguage: String?

    private enum Phase: Equatable {
        case idle, connecting, streaming, reconnecting, fallback
    }

    private struct Connection {
        let socket: any DeepgramSocket
        let generation: Int
        var clock = StreamClock()
        /// Stream frame of the first sample in `inFlight`.
        var acknowledgedFrames: Int64 = 0
    }

    private var phase = Phase.idle
    private var isFinished = false
    private var client: DeepgramClient?
    private var connection: Connection?
    private var generation = 0
    private let timeline = RecognitionTimeline()
    /// Audio waiting for a connection, oldest first.
    private var unsent: [RecognitionTimeline.Span] = []
    /// Audio sent on the current connection that no final covers yet; resent after a drop.
    private var inFlight: [RecognitionTimeline.Span] = []
    private var lastSend = ContinuousClock.now
    private var receiveTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var fallback: (any ChannelTranscriber)?
    private var fallbackForward: Task<Void, Never>?

    /// - Parameters:
    ///   - localeID: locale recorded on the text (and of the on-device fallback's Apple preview).
    ///   - languageCode: ISO 639-1 language Deepgram transcribes, or "multi".
    ///   - fallbackEngine: on-device engine refining Apple's preview when Deepgram can't be used.
    public init(
        channel: AudioChannel, localeID: String, languageCode: String, prompt: [String],
        library: SpeechModelLibrary = .shared, fallbackEngine: SpeechEngineKind = .apple, autoLanguage: Bool = true,
        waitForEngine: Bool = false, options: Options = Options()
    ) {
        self.init(
            channel: channel, localeID: localeID, languageCode: languageCode, prompt: prompt, library: library,
            options: options,
            makeFallback: { prompt in
                RefiningTranscriber(
                    channel: channel, appleLocaleID: localeID, engine: fallbackEngine, languageCode: languageCode,
                    prompt: prompt, customization: nil, library: library, autoLanguage: autoLanguage,
                    waitForEngine: waitForEngine)
            })
    }

    init(
        channel: AudioChannel, localeID: String, languageCode: String, prompt: [String], library: SpeechModelLibrary,
        options: Options, makeFallback: @escaping @Sendable ([String]) -> any ChannelTranscriber
    ) {
        self.channel = channel
        self.localeID = localeID
        self.languageCode = languageCode
        self.prompt = prompt
        self.library = library
        self.options = options
        self.makeFallback = makeFallback
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Why this channel gave up on Deepgram; nil while Deepgram transcribes it.
    public private(set) var fallbackReason: String?
    /// Why Deepgram streams with Nova-3 instead of `Options.model`; nil when the chosen model is used.
    public private(set) var modelFallbackReason: String?

    // MARK: - ChannelTranscriber

    /// Checks the key and opens the stream; on failure switches to on-device transcription (never throws for
    /// Deepgram problems).
    public func start() async throws {
        guard !isFinished else { throw TranscriptionError.notRunning }
        guard phase == .idle else { return }
        phase = .connecting
        let choice = await library.deepgramModelChoice(options.model, languageCode: languageCode, live: true)
        model = choice.model
        modelFallbackReason = choice.fallbackReason
        if let reason = choice.fallbackReason {
            transcriptionLog.info("\(self.channel.rawValue, privacy: .public): \(reason, privacy: .public)")
        }
        guard let language = choice.language else {
            try await switchToFallback(
                reason: "Deepgram \(Deepgram.modelDisplayName(choice.model)) doesn't transcribe “\(languageCode)”",
                report: false)
            return
        }
        streamLanguage = language
        do {
            client = try await library.deepgramClient()
            do {
                try await connect(language: language)
            } catch DeepgramError.requestFailed(let status, let message)
                where (400..<500).contains(status) && !Deepgram.isDefaultModel(model)
            {
                // Deepgram refused the model for this stream; Nova-3 streams instead.
                guard let nova3Language = Deepgram.requestLanguage(languageCode) else {
                    throw DeepgramError.requestFailed(status, message)
                }
                modelFallbackReason =
                    "Deepgram refused \(Deepgram.modelDisplayName(model)) (\(message)), so Nova-3 is used instead"
                model = Deepgram.defaultModel
                streamLanguage = nova3Language
                try await connect(language: nova3Language)
            }
        } catch {
            try await switchToFallback(reason: Self.reason(error))
            return
        }
        startKeepAlive()
    }

    public func append(_ chunk: AudioChunk) async {
        guard phase != .idle, !isFinished else { return }
        if let fallback {
            await fallback.append(chunk)
            return
        }
        do {
            for span in try timeline.ingest(samples: chunk.samples, sampleRate: chunk.sampleRate, startTime: chunk.startTime) {
                route(span)
            }
        } catch {
            transcriptionLog.error("Resampling \(self.channel.rawValue, privacy: .public) audio for Deepgram failed: \(error.localizedDescription, privacy: .public)")
        }
        if phase == .reconnecting, bufferedSeconds > options.maximumBufferSeconds {
            try? await switchToFallback(reason: "Lost the connection to Deepgram")
        }
    }

    public func setPrompt(_ prompt: [String]) async {
        self.prompt = prompt
        await fallback?.setPrompt(prompt)
    }

    public func finish() async {
        guard !isFinished else { return }
        isFinished = true
        keepAliveTask?.cancel()
        if fallback == nil, phase != .fallback {
            do {
                for span in try timeline.flush() { route(span) }
            } catch {
                transcriptionLog.error("Flushing \(self.channel.rawValue, privacy: .public) audio for Deepgram failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let reconnecting = reconnectTask {
            reconnecting.cancel()
            await reconnecting.value
            reconnectTask = nil
        }
        // Audio still waiting for a connection gets one more try, else goes on-device.
        if phase == .reconnecting, !(unsent.isEmpty && inFlight.isEmpty) {
            do {
                try await connect(language: streamLanguage ?? languageCode)
            } catch {
                try? await switchToFallback(reason: Self.reason(error))
            }
        }
        if let connection, phase == .streaming {
            connection.socket.send(text: #"{"type":"CloseStream"}"#)
            await waitForClose(connection.socket)
            connection.socket.close()
            self.connection = nil
        }
        receiveTask?.cancel()
        if let fallback {
            await fallback.finish()
            await fallbackForward?.value
        }
        eventContinuation.finish()
    }

    // MARK: - Connection

    private func connect(language: String) async throws {
        guard let client else { throw DeepgramError.missingKey }
        let socket = client.account.makeSocket(
            client.streamingRequest(model: model, language: language, keyterms: Deepgram.keyterms(prompt)))
        do {
            try await Self.open(socket, timeout: options.connectTimeout)
        } catch {
            socket.close()
            throw error
        }
        generation += 1
        let id = generation
        connection = Connection(socket: socket, generation: id)
        phase = .streaming
        lastSend = .now
        receiveTask = Task { [weak self] in
            do {
                while let text = try await socket.receive() {
                    guard let self else { return }
                    await self.handle(text, generation: id)
                }
                await self?.connectionEnded(generation: id, error: nil)
            } catch {
                await self?.connectionEnded(generation: id, error: error)
            }
        }
        await library.reportDeepgramConnection(.ready)
        let waiting = inFlight + unsent
        inFlight = []
        unsent = []
        for span in waiting { send(span) }
    }

    private static func open(_ socket: any DeepgramSocket, timeout: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await socket.open() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw DeepgramError.connectTimeout
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func route(_ span: RecognitionTimeline.Span) {
        if phase == .streaming, connection != nil {
            send(span)
        } else {
            unsent.append(span)
        }
    }

    private func send(_ span: RecognitionTimeline.Span) {
        guard var connection else {
            unsent.append(span)
            return
        }
        connection.socket.send(Deepgram.int16LittleEndian(span.samples))
        connection.clock.record(span)
        inFlight.append(span)
        // Bound what is kept for resending; Deepgram finalizes far more often than this.
        let excess = inFlight.reduce(0) { $0 + $1.samples.count } - Int(options.maximumBufferSeconds * PCM.recognitionRate)
        if excess > 0 { connection.acknowledgedFrames += Int64(dropInFlight(frames: excess)) }
        self.connection = connection
        lastSend = .now
    }

    /// Removes up to `frames` samples from the front of `inFlight`; returns how many were removed.
    private func dropInFlight(frames: Int) -> Int {
        var remaining = frames
        while remaining > 0, let first = inFlight.first {
            if first.samples.count <= remaining {
                remaining -= first.samples.count
                inFlight.removeFirst()
            } else {
                inFlight[0] = RecognitionTimeline.Span(
                    samples: Array(first.samples.dropFirst(remaining)), startFrame: first.startFrame + Int64(remaining))
                remaining = 0
            }
        }
        return frames - remaining
    }

    private var bufferedSeconds: Double {
        Double((unsent + inFlight).reduce(0) { $0 + $1.samples.count }) / PCM.recognitionRate
    }

    private func connectionEnded(generation id: Int, error: (any Error)?) async {
        guard id == generation, let ended = connection else { return }
        connection = nil
        ended.socket.close()
        guard !isFinished, phase == .streaming else { return }
        if let error { transcriptionLog.error("Deepgram connection dropped: \(error.localizedDescription, privacy: .public)") }
        // Unfinalized audio is sent again on the next connection; interim text for it will come again too.
        unsent = inFlight + unsent
        inFlight = []
        phase = .reconnecting
        reconnectTask = Task { [weak self] in await self?.reconnect() }
    }

    private func reconnect() async {
        var attempt = 0
        while phase == .reconnecting, !Task.isCancelled {
            let delays = options.reconnectDelays
            try? await Task.sleep(for: delays.isEmpty ? .seconds(1) : delays[min(attempt, delays.count - 1)])
            guard phase == .reconnecting, !Task.isCancelled else { return }
            do {
                try await connect(language: streamLanguage ?? languageCode)
                reconnectTask = nil
                return
            } catch let error as DeepgramError where error == .invalidKey || error == .outOfCredit {
                reconnectTask = nil
                try? await switchToFallback(reason: error.statusMessage)
                return
            } catch {
                attempt += 1
                transcriptionLog.error("Reconnecting to Deepgram failed (attempt \(attempt)): \(error.localizedDescription, privacy: .public)")
                if bufferedSeconds > options.maximumBufferSeconds {
                    reconnectTask = nil
                    try? await switchToFallback(reason: Self.reason(error))
                    return
                }
            }
        }
    }

    private func startKeepAlive() {
        let tick = max(options.keepAliveInterval / 5, .milliseconds(10))
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tick)
                await self?.keepAliveIfIdle()
            }
        }
    }

    private func keepAliveIfIdle() {
        guard phase == .streaming, let connection, ContinuousClock.now - lastSend >= options.keepAliveInterval else { return }
        connection.socket.send(text: #"{"type":"KeepAlive"}"#)
        lastSend = .now
    }

    /// Waits until Deepgram closes the stream after `CloseStream` (all finals delivered) or `finishTimeout`.
    private func waitForClose(_ socket: any DeepgramSocket) async {
        guard let receiving = receiveTask else { return }
        let timeout = options.finishTimeout
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await receiving.value }
            group.addTask {
                try? await Task.sleep(for: timeout)
                if !Task.isCancelled { socket.close() }
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Results

    private func handle(_ text: String, generation id: Int) {
        guard id == generation, var connection else { return }
        let message: Deepgram.StreamMessage
        do {
            message = try Deepgram.decodeStreamMessage(text)
        } catch {
            transcriptionLog.error("Unreadable Deepgram message: \(error.localizedDescription, privacy: .public)")
            return
        }
        switch message {
        case .results(let result):
            if result.isFinal {
                let end = Int64(((result.start + result.duration) * PCM.recognitionRate).rounded())
                if end > connection.acknowledgedFrames {
                    connection.acknowledgedFrames += Int64(dropInFlight(frames: Int(end - connection.acknowledgedFrames)))
                    self.connection = connection
                }
            }
            guard let update = Self.update(result, clock: connection.clock, channel: channel, localeID: localeID) else { return }
            eventContinuation.yield(result.isFinal ? .final(update) : .volatile(update))
        case .error(let description):
            transcriptionLog.error("Deepgram error: \(description, privacy: .public)")
        case .utteranceEnd, .metadata, .speechStarted, .other:
            break
        }
    }

    /// Text and words on the session clock; nil for an empty result.
    static func update(
        _ result: Deepgram.StreamResult, clock: StreamClock, channel: AudioChannel, localeID: String
    ) -> TranscriptUpdate? {
        let text = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let words = result.words.map {
            TimedWord(
                text: $0.text, range: TimeRange(start: clock.sessionTime($0.start), end: clock.sessionTime($0.end)),
                confidence: $0.confidence)
        }
        let range = TimeRange(
            start: words.first?.range.start ?? clock.sessionTime(result.start),
            end: words.last?.range.end ?? clock.sessionTime(result.start + result.duration))
        return TranscriptUpdate(
            channel: channel, text: text, range: range, confidence: result.confidence, localeID: localeID, words: words,
            engine: .deepgram)
    }

    // MARK: - Fallback

    /// Moves the channel to on-device transcription and hands it the audio Deepgram didn't finalize.
    private func switchToFallback(reason: String, report: Bool = true) async throws {
        guard phase != .fallback else { return }
        phase = .fallback
        fallbackReason = reason
        keepAliveTask?.cancel()
        if let connection {
            self.connection = nil
            connection.socket.close()
        }
        receiveTask?.cancel()
        transcriptionLog.info("\(self.channel.rawValue, privacy: .public) leaves Deepgram: \(reason, privacy: .public)")
        if report { await library.reportDeepgramConnection(.failed(reason)) }
        let fallback = makeFallback(prompt)
        try await fallback.start()
        let fallbackEvents = fallback.events
        let continuation = eventContinuation
        fallbackForward = Task {
            for await event in fallbackEvents { continuation.yield(event) }
        }
        var pending = inFlight + unsent + ((try? timeline.flush()) ?? [])
        inFlight = []
        unsent = []
        // Audio arriving while this replays is queued in `unsent` and replayed next, keeping time order.
        while !pending.isEmpty {
            for span in pending {
                await fallback.append(
                    AudioChunk(
                        channel: channel, startTime: Double(span.startFrame) / PCM.recognitionRate,
                        sampleRate: PCM.recognitionRate, samples: span.samples))
            }
            pending = unsent
            unsent = []
        }
        self.fallback = fallback
    }

    private static func reason(_ error: any Error) -> String {
        (error as? DeepgramError)?.statusMessage ?? error.localizedDescription
    }
}

/// Maps seconds of audio received on one Deepgram connection to session-clock seconds. Each discontinuity in
/// what was sent (a gap in the input, or the first audio of the connection) starts a new anchor.
struct StreamClock: Sendable {
    private(set) var anchors: [(stream: Int64, session: Int64)] = []
    private(set) var streamFrames: Int64 = 0
    private var nextSessionFrame: Int64?

    mutating func record(_ span: RecognitionTimeline.Span) {
        if span.startFrame != nextSessionFrame { anchors.append((streamFrames, span.startFrame)) }
        streamFrames += Int64(span.samples.count)
        nextSessionFrame = span.startFrame + Int64(span.samples.count)
    }

    func sessionTime(_ streamSeconds: Double) -> TimeInterval {
        let frame = streamSeconds * PCM.recognitionRate
        guard let anchor = anchors.last(where: { Double($0.stream) <= frame }) ?? anchors.first else { return streamSeconds }
        return (Double(anchor.session) + frame - Double(anchor.stream)) / PCM.recognitionRate
    }
}
