import Foundation
import Testing
import VCModels
@testable import VCTranscription

final class Counter: Sendable {
    let value = Mutex(0)
}

// MARK: - Stubs

/// Serves requests to `https://<host>/…` from a per-host handler, so tests can run in parallel.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data?) -> (status: Int, body: Data)

    private static let handlers = Mutex<[String: Handler]>([:])
    private static let requests = Mutex<[String: [URLRequest]]>([:])

    /// A session whose requests to `host` go to `handler`.
    static func session(host: String, handler: @escaping Handler) -> URLSession {
        handlers.withLock { $0[host] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func recorded(host: String) -> [URLRequest] { requests.withLock { $0[host] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        Self.requests.withLock { $0[host, default: []].append(request) }
        guard let handler = Self.handlers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let (status, data) = handler(request, body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            guard n > 0 else { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

/// A scripted Deepgram socket: records what is sent, delivers pushed messages, fails or closes on demand.
final class FakeSocket: DeepgramSocket {
    enum Sent: Equatable {
        case audio(samples: Int)
        case text(String)
    }

    private struct State {
        var sent: [Sent] = []
        var inbox: [Result<String?, any Error>] = []
        var waiter: CheckedContinuation<String?, any Error>?
        var closed = false
        /// Messages delivered when `CloseStream` arrives, before the socket closes.
        var onCloseStream: [String] = []
    }

    private let state = Mutex(State())
    let openError: DeepgramError?

    init(openError: DeepgramError? = nil, onCloseStream: [String] = []) {
        self.openError = openError
        state.withLock { $0.onCloseStream = onCloseStream }
    }

    var sent: [Sent] { state.withLock { $0.sent } }
    var audioSamples: Int { sent.reduce(0) { if case .audio(let n) = $1 { $0 + n } else { $0 } } }
    var texts: [String] { sent.compactMap { if case .text(let t) = $0 { t } else { nil } } }

    func open() async throws {
        if let openError { throw openError }
    }

    func send(_ data: Data) { state.withLock { $0.sent.append(.audio(samples: data.count / 2)) } }

    func send(text: String) {
        let closing = state.withLock { state -> [String]? in
            state.sent.append(.text(text))
            return text.contains("CloseStream") ? state.onCloseStream : nil
        }
        if let closing {
            for message in closing { push(message) }
            deliver(.success(nil))
        }
    }

    func push(_ message: String) { deliver(.success(message)) }
    func fail() { deliver(.failure(DeepgramError.unreachable("dropped"))) }

    func receive() async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            let next = state.withLock { state -> Result<String?, any Error>? in
                if !state.inbox.isEmpty { return state.inbox.removeFirst() }
                if state.closed { return .success(nil) }
                state.waiter = continuation
                return nil
            }
            if let next { continuation.resume(with: next) }
        }
    }

    func close() {
        let waiter = state.withLock { state -> CheckedContinuation<String?, any Error>? in
            state.closed = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: nil)
    }

    private func deliver(_ result: Result<String?, any Error>) {
        let waiter = state.withLock { state -> CheckedContinuation<String?, any Error>? in
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            state.inbox.append(result)
            return nil
        }
        waiter?.resume(with: result)
    }
}

/// Hands out prepared sockets in order and records their requests.
final class SocketQueue: Sendable {
    private let state: Mutex<(sockets: [FakeSocket], requests: [URLRequest])>

    init(_ sockets: [FakeSocket]) { state = Mutex((sockets, [])) }

    var requests: [URLRequest] { state.withLock { $0.requests } }

    func next(_ request: URLRequest) -> any DeepgramSocket {
        state.withLock { state in
            state.requests.append(request)
            return state.sockets.isEmpty ? FakeSocket(openError: .unreachable("no more sockets")) : state.sockets.removeFirst()
        }
    }
}

/// An on-device stand-in: records audio and emits one final per chunk.
actor FakeFallback: ChannelTranscriber {
    nonisolated let events: AsyncStream<TranscriptEvent>
    private let continuation: AsyncStream<TranscriptEvent>.Continuation
    private(set) var chunks: [AudioChunk] = []
    private(set) var started = false

    init() { (events, continuation) = AsyncStream.makeStream() }

    func start() async throws { started = true }

    func append(_ chunk: AudioChunk) async {
        chunks.append(chunk)
        continuation.yield(
            .final(TranscriptUpdate(channel: chunk.channel, text: "local", range: chunk.range, confidence: nil, localeID: "en-GB", engine: .apple)))
    }

    func setPrompt(_ prompt: [String]) async {}
    func finish() async { continuation.finish() }
}

enum DeepgramStub {
    static func host() -> String { "dg-\(UUID().uuidString.lowercased()).test" }

    static func account(
        key: String? = "test-key", host: String, sockets: SocketQueue = SocketQueue([]),
        handler: @escaping StubProtocol.Handler
    ) -> DeepgramAccount {
        DeepgramAccount(
            resolveKey: { key.map { Deepgram.ResolvedKey(value: $0, source: .environment) } },
            session: StubProtocol.session(host: host, handler: handler), restBase: URL(string: "https://\(host)")!,
            streamingBase: URL(string: "wss://\(host)")!, retryDelay: .milliseconds(1), makeSocket: sockets.next)
    }

    static func library(_ account: DeepgramAccount) -> SpeechModelLibrary {
        SpeechModelLibrary(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("vc-dg-\(UUID().uuidString)"),
            deepgram: account)
    }

    static func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    static let listenBody = json([
        "metadata": ["duration": 2.5],
        "results": [
            "channels": [[
                "alternatives": [[
                    "transcript": "hello world", "confidence": 0.97,
                    "words": [
                        ["word": "hello", "punctuated_word": "Hello", "start": 0.08, "end": 0.42, "confidence": 0.99],
                        ["word": "world", "punctuated_word": "world.", "start": 0.5, "end": 0.91, "confidence": 0.95],
                    ],
                ]]
            ]]
        ],
    ])

    static func results(
        start: Double, duration: Double, final: Bool, words: [(String, Double, Double)]
    ) -> String {
        let body = json([
            "type": "Results", "channel_index": [0, 1], "start": start, "duration": duration, "is_final": final,
            "speech_final": final,
            "channel": [
                "alternatives": [[
                    "transcript": words.map(\.0).joined(separator: " "), "confidence": 0.9,
                    "words": words.map { ["word": $0.0.lowercased(), "punctuated_word": $0.0, "start": $0.1, "end": $0.2, "confidence": 0.9] },
                ]]
            ],
        ])
        return String(decoding: body, as: UTF8.self)
    }
}

// MARK: - Keys, queries, audio

@Suite struct DeepgramRequestTests {
    @Test func keyResolutionPrefersKeychainThenEnvironmentThenFile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("vc-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("  file-key\n".utf8).write(to: home.appendingPathComponent(".deepgram_secret"))
        let env = ["DEEPGRAM_API_KEY": "env-key"]

        #expect(Deepgram.resolveKey(keychain: { "chain-key" }, environment: env, home: home) == .init(value: "chain-key", source: .keychain))
        #expect(Deepgram.resolveKey(keychain: { nil }, environment: env, home: home) == .init(value: "env-key", source: .environment))
        #expect(Deepgram.resolveKey(keychain: { " " }, environment: ["DEEPGRAM_API_KEY": "\n"], home: home) == .init(value: "file-key", source: .file))
        // In the App Sandbox there's no home to read; an unreadable file is skipped silently.
        #expect(Deepgram.resolveKey(keychain: { nil }, environment: [:], home: nil) == nil)
        #expect(Deepgram.resolveKey(keychain: { nil }, environment: [:], home: home.appendingPathComponent("missing")) == nil)
    }

    @Test func keytermsAreTrimmedDedupedAndCapped() {
        let terms = Deepgram.keyterms(["  Ngozi ", "ngozi", "", "Lekki  Phase 1", "NGOZI"] + (0..<80).map { "term\($0)" })
        #expect(terms.prefix(2) == ["Ngozi", "Lekki Phase 1"])
        #expect(terms.count == 50)
        #expect(Set(terms.map { $0.lowercased() }).count == 50)
    }

    @Test func queriesCarryOptionsAndEncodeTermsStrictly() throws {
        let rest = Deepgram.listenURL(language: "en", keyterms: ["C++", "R&D team", "Ọlá"])
        let query = try #require(rest.query(percentEncoded: true))
        #expect(rest.absoluteString.hasPrefix("https://api.deepgram.com/v1/listen?"))
        for item in ["model=nova-3", "smart_format=true", "punctuate=true", "mip_opt_out=true", "language=en"] {
            #expect(query.contains(item), "\(item)")
        }
        #expect(query.contains("keyterm=C%2B%2B"))
        #expect(query.contains("keyterm=R%26D%20team"))
        #expect(!query.contains("interim_results"))
        let items = URLComponents(url: rest, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.filter { $0.name == "keyterm" }.map(\.value) == ["C++", "R&D team", "Ọlá"])

        let live = Deepgram.streamingURL(language: "multi", keyterms: [])
        let liveQuery = try #require(live.query(percentEncoded: true))
        #expect(live.absoluteString.hasPrefix("wss://api.deepgram.com/v1/listen?"))
        for item in [
            "model=nova-3", "encoding=linear16", "sample_rate=16000", "channels=1", "interim_results=true",
            "smart_format=true", "punctuate=true", "endpointing=300", "utterance_end_ms=1000", "mip_opt_out=true",
            "language=multi",
        ] {
            #expect(liveQuery.contains(item), "\(item)")
        }
    }

    @Test func languagesMapToNovaThree() {
        #expect(Deepgram.requestLanguage("en-GB") == "en")
        #expect(Deepgram.requestLanguage("multi") == "multi")
        #expect(Deepgram.requestLanguage("nb") == "no")
        #expect(Deepgram.requestLanguage("sw") == "sw")
        #expect(Deepgram.requestLanguage("yo") == nil)
        #expect(SpeechModelLibrary.info(.deepgram).languageCodes.contains("multi"))
    }

    @Test func wavAndPCMEncoding() {
        let wav = Deepgram.wav(samples16k: [0, 1, -1, 0.5])
        #expect(wav.count == 44 + 8)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        let pcm = Deepgram.int16LittleEndian([1, -1, 2] as [Float])
        #expect(Array(pcm) == [0xFF, 0x7F, 0x01, 0x80, 0xFF, 0x7F])
    }
}

// MARK: - REST

@Suite struct DeepgramRESTTests {
    @Test func transcribesWithWordTimesAndSendsKeyOnlyInHeader() async throws {
        let host = DeepgramStub.host()
        let library = DeepgramStub.library(
            DeepgramStub.account(host: host) { request, _ in
                request.url?.path == "/v1/projects" ? (200, Data("{}".utf8)) : (200, DeepgramStub.listenBody)
            })
        #expect(await library.status(.deepgram) == .downloaded)
        let engine = try await library.transcriber(.deepgram)
        #expect(await library.status(.deepgram) == .ready)
        let result = try await engine.transcribe(
            samples16k: [Float](repeating: 0.1, count: 16_000), languageCode: "en-GB", prompt: ["Ngozi", "ngozi"])
        #expect(result.text == "hello world")
        #expect(result.engine == .deepgram && result.languageCode == "en")
        #expect(result.words?.map(\.text) == ["Hello", "world."])
        #expect(result.words?.first?.range == TimeRange(start: 0.08, end: 0.42))
        #expect(result.words?.last?.confidence == 0.95)

        let requests = StubProtocol.recorded(host: host)
        #expect(requests.map(\.url?.path) == ["/v1/projects", "/v1/listen"])
        let listen = try #require(requests.last)
        #expect(listen.value(forHTTPHeaderField: "Authorization") == "Token test-key")
        #expect(listen.value(forHTTPHeaderField: "Content-Type") == "audio/wav")
        #expect(listen.httpMethod == "POST")
        let query = listen.url?.query(percentEncoded: true) ?? ""
        #expect(!query.contains("test-key"))
        #expect(query.components(separatedBy: "keyterm=").count == 2)

        // The check is cached for the launch.
        _ = try await library.transcriber(.deepgram)
        #expect(StubProtocol.recorded(host: host).filter { $0.url?.path == "/v1/projects" }.count == 1)
    }

    @Test func rejectedKeyAndMissingKey() async throws {
        let host = DeepgramStub.host()
        let rejected = DeepgramStub.library(
            DeepgramStub.account(host: host) { _, _ in (401, Data(#"{"err_code":"INVALID_AUTH","err_msg":"Invalid credentials."}"#.utf8)) })
        await #expect(throws: DeepgramError.invalidKey) { try await rejected.prewarm(.deepgram) }
        #expect(await rejected.status(.deepgram) == .failed("Deepgram API key rejected"))
        #expect(DeepgramError.invalidKey.localizedDescription.contains("Deepgram API key invalid"))
        // A rejected key isn't checked again.
        await #expect(throws: DeepgramError.invalidKey) { try await rejected.prewarm(.deepgram) }
        #expect(StubProtocol.recorded(host: host).count == 1)

        let missing = DeepgramStub.library(DeepgramStub.account(key: nil, host: DeepgramStub.host()) { _, _ in (200, Data()) })
        #expect(await missing.status(.deepgram) == .failed("Add your Deepgram API key"))
        #expect(!missing.isDownloaded(.deepgram))
        await #expect(throws: DeepgramError.missingKey) { _ = try await missing.transcriber(.deepgram) }
        // Nothing to download or delete.
        try await missing.download(.deepgram)
        try await missing.delete(.deepgram)
        #expect(await missing.status(.deepgram) == .failed("Add your Deepgram API key"))
    }

    @Test func mapsHTTPFailuresAndRetries() async throws {
        let attempts = Counter()
        func engine(_ handler: @escaping @Sendable (Int) -> (Int, Data)) async throws -> any AccurateTranscriber {
            attempts.value.withLock { $0 = 0 }
            let library = DeepgramStub.library(
                DeepgramStub.account(host: DeepgramStub.host()) { request, _ in
                    guard request.url?.path == "/v1/listen" else { return (200, Data("{}".utf8)) }
                    let n = attempts.value.withLock { $0 += 1; return $0 }
                    return handler(n)
                })
            return try await library.transcriber(.deepgram)
        }
        let audio = [Float](repeating: 0, count: 1_600)

        let flaky = try await engine { $0 < 3 ? (429, Data()) : (200, DeepgramStub.listenBody) }
        #expect(try await flaky.transcribe(samples16k: audio, languageCode: "en", prompt: []).text == "hello world")
        #expect(attempts.value.withLock { $0 } == 3)

        let down = try await engine { _ in (503, Data()) }
        await #expect(throws: DeepgramError.serverError(503)) { _ = try await down.transcribe(samples16k: audio, languageCode: "en", prompt: []) }
        #expect(attempts.value.withLock { $0 } == DeepgramClient.maximumAttempts)

        let broke = try await engine { _ in (402, Data()) }
        await #expect(throws: DeepgramError.outOfCredit) { _ = try await broke.transcribe(samples16k: audio, languageCode: "en", prompt: []) }
        #expect(attempts.value.withLock { $0 } == 1)

        let bad = try await engine { _ in (400, Data(#"{"err_code":"Bad Request","err_msg":"Bad audio."}"#.utf8)) }
        await #expect(throws: DeepgramError.requestFailed(400, "Bad audio.")) {
            _ = try await bad.transcribe(samples16k: audio, languageCode: "en", prompt: [])
        }
        await #expect(throws: TranscriptionError.unsupportedLanguage("yo", .deepgram)) {
            _ = try await bad.transcribe(samples16k: audio, languageCode: "yo", prompt: [])
        }

        let garbled = try await engine { _ in (200, Data("not json".utf8)) }
        await #expect(throws: DeepgramError.malformedResponse) {
            _ = try await garbled.transcribe(samples16k: audio, languageCode: "en", prompt: [])
        }
    }
}

// MARK: - Streaming

@Suite struct DeepgramStreamingTests {
    @Test func decodesStreamMessages() throws {
        let interim = try Deepgram.decodeStreamMessage(
            DeepgramStub.results(start: 1.5, duration: 0.8, final: false, words: [("Hel", 1.6, 1.9)]))
        guard case .results(let r) = interim else { Issue.record("not results"); return }
        #expect(!r.isFinal && r.start == 1.5 && r.duration == 0.8 && r.transcript == "Hel")
        #expect(r.words == [Deepgram.StreamWord(text: "Hel", start: 1.6, end: 1.9, confidence: 0.9)])

        let final = try Deepgram.decodeStreamMessage(
            DeepgramStub.results(start: 1.5, duration: 1.2, final: true, words: [("Hello,", 1.6, 2.0), ("there.", 2.1, 2.6)]))
        guard case .results(let f) = final else { Issue.record("not results"); return }
        #expect(f.isFinal && f.speechFinal && f.words.map(\.text) == ["Hello,", "there."])

        #expect(try Deepgram.decodeStreamMessage(#"{"type":"UtteranceEnd","channel":[0,1],"last_word_end":2.6}"#) == .utteranceEnd(lastWordEnd: 2.6))
        #expect(try Deepgram.decodeStreamMessage(#"{"type":"Metadata","request_id":"x","duration":48.2,"channels":1}"#) == .metadata(duration: 48.2))
        #expect(try Deepgram.decodeStreamMessage(#"{"type":"SpeechStarted","timestamp":1.0}"#) == .speechStarted)
        #expect(try Deepgram.decodeStreamMessage(#"{"type":"Error","description":"bad"}"#) == .error("bad"))
        #expect(throws: (any Error).self) { try Deepgram.decodeStreamMessage("nope") }
    }

    @Test func streamClockMapsAcrossGaps() {
        var clock = StreamClock()
        clock.record(RecognitionTimeline.Span(samples: .init(repeating: 0, count: 16_000), startFrame: 160_000))  // 10–11 s
        clock.record(RecognitionTimeline.Span(samples: .init(repeating: 0, count: 8_000), startFrame: 176_000))  // 11–11.5 s
        clock.record(RecognitionTimeline.Span(samples: .init(repeating: 0, count: 8_000), startFrame: 320_000))  // 20–20.5 s
        #expect(clock.sessionTime(0.25) == 10.25)
        #expect(clock.sessionTime(1.25) == 11.25)
        #expect(clock.sessionTime(1.75) == 20.25)
    }

    private static func chunk(_ start: Double, seconds: Double = 0.1) -> AudioChunk {
        AudioChunk(
            channel: .microphone, startTime: start, sampleRate: 16_000,
            samples: [Float](repeating: 0.01, count: Int(seconds * 16_000)))
    }

    private static func waitUntil(_ condition: @Sendable () async -> Bool) async {
        for _ in 0..<400 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func streamsRebasesTimesAndResendsAfterReconnect() async throws {
        let first = FakeSocket()
        let second = FakeSocket(onCloseStream: [
            DeepgramStub.results(start: 0.7, duration: 0.3, final: true, words: [("again.", 0.8, 0.95)]),
            #"{"type":"Metadata","duration":1.0}"#,
        ])
        let sockets = SocketQueue([first, second])
        let library = DeepgramStub.library(DeepgramStub.account(host: DeepgramStub.host(), sockets: sockets) { _, _ in (200, Data("{}".utf8)) })
        var options = DeepgramLiveTranscriber.Options()
        options.reconnectDelays = [.milliseconds(5)]
        options.keepAliveInterval = .milliseconds(50)
        options.finishTimeout = .seconds(2)
        let live = DeepgramLiveTranscriber(
            channel: .microphone, localeID: "en-GB", languageCode: "en", prompt: ["Ngozi"], library: library,
            options: options, makeFallback: { _ in FakeFallback() })
        let (log, collecting) = EventLog.collecting(live.events)

        try await live.start()
        #expect(await live.fallbackReason == nil)
        #expect(await library.status(.deepgram) == .ready)
        let request = try #require(sockets.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Token test-key")
        #expect(request.url?.query(percentEncoded: true)?.contains("keyterm=Ngozi") == true)

        // One second of audio starting 10 s into the session.
        for i in 0..<10 { await live.append(Self.chunk(10 + Double(i) / 10)) }
        #expect(first.audioSamples == 16_000)
        first.push(DeepgramStub.results(start: 0, duration: 0.5, final: true, words: [("Hello", 0.1, 0.4)]))
        first.push(DeepgramStub.results(start: 0.5, duration: 0.3, final: false, words: [("wor", 0.55, 0.7)]))
        await Self.waitUntil { await log.events.count == 2 }
        let events = await log.events
        guard case .final(let hello) = events.first, case .volatile(let partial) = events.last else {
            Issue.record("unexpected events \(events)")
            return
        }
        #expect(hello.text == "Hello" && hello.engine == .deepgram && hello.localeID == "en-GB")
        #expect(abs(hello.words[0].range.start - 10.1) < 1e-9 && abs(hello.range.end - 10.4) < 1e-9)
        #expect(abs(partial.range.start - 10.55) < 1e-9)

        // The connection drops; 0.2 s more arrives while reconnecting.
        first.fail()
        await live.append(Self.chunk(11.0))
        await live.append(Self.chunk(11.1))
        await Self.waitUntil { second.audioSamples >= 11_200 }
        // The unfinalized 0.5 s (10.5–11 s) is sent again, then the new audio.
        #expect(second.audioSamples == 8_000 + 3_200)
        second.push(DeepgramStub.results(start: 0, duration: 0.6, final: true, words: [("world.", 0.25, 0.5)]))
        await Self.waitUntil { await log.finals.count == 2 }
        let world = try #require(await log.finals.last)
        #expect(abs(world.words[0].range.start - 10.75) < 1e-9)

        // After a gap, stream time continues but session time jumps.
        await live.append(Self.chunk(20.0, seconds: 0.3))
        // Idle long enough for a KeepAlive.
        await Self.waitUntil { second.texts.contains(#"{"type":"KeepAlive"}"#) }
        #expect(second.texts.contains(#"{"type":"KeepAlive"}"#))

        await live.finish()
        await collecting.value
        #expect(second.texts.last == #"{"type":"CloseStream"}"#)
        let finals = await log.finals
        #expect(finals.map(\.text) == ["Hello", "world.", "again."])
        // Stream 0.8 s on the second connection = 0.1 s into the audio that started at 20 s.
        #expect(abs(finals[2].words[0].range.start - 20.1) < 1e-9)
        let starts = finals.flatMap(\.words).map(\.range.start)
        #expect(starts == starts.sorted())
    }

    @Test func fallsBackOnDeviceWithoutAKey() async throws {
        let library = DeepgramStub.library(DeepgramStub.account(key: nil, host: DeepgramStub.host()) { _, _ in (200, Data()) })
        let fallback = FakeFallback()
        let live = DeepgramLiveTranscriber(
            channel: .system, localeID: "en-GB", languageCode: "en", prompt: [], library: library,
            options: .init(), makeFallback: { _ in fallback })
        let (log, collecting) = EventLog.collecting(live.events)
        try await live.start()
        #expect(await live.fallbackReason == "Add your Deepgram API key")
        #expect(await fallback.started)
        await live.append(Self.chunk(1))
        await live.finish()
        await collecting.value
        #expect(await fallback.chunks.count == 1)
        #expect(await log.finals.map(\.text) == ["local"])
        #expect(await library.status(.deepgram) == .failed("Add your Deepgram API key"))
    }

    @Test func fallsBackWhenDeepgramRefusesTheStream() async throws {
        let sockets = SocketQueue([FakeSocket(openError: .invalidKey)])
        let library = DeepgramStub.library(DeepgramStub.account(host: DeepgramStub.host(), sockets: sockets) { _, _ in (200, Data("{}".utf8)) })
        let fallback = FakeFallback()
        let live = DeepgramLiveTranscriber(
            channel: .microphone, localeID: "en-US", languageCode: "en", prompt: [], library: library,
            options: .init(), makeFallback: { _ in fallback })
        try await live.start()
        #expect(await live.fallbackReason == "Deepgram API key rejected")
        #expect(await library.status(.deepgram) == .failed("Deepgram API key rejected"))
        await live.finish()
    }
}
