import Foundation
import VCModels

/// Deepgram Nova-3: constants, API key lookup, request building and response decoding shared by the file
/// path (`DeepgramTranscriber`) and the live path (`DeepgramLiveTranscriber`).
///
/// The key is only ever sent in the `Authorization` header. It never appears in URLs, errors or logs.
public enum Deepgram {
    /// Keychain account (service "com.voiccenger.app") holding the user's key.
    public static let keychainAccount = "deepgram-api-key"
    public static let environmentVariable = "DEEPGRAM_API_KEY"
    /// `~/.deepgram_secret`, read by the direct-download app and the CLI; unreachable from the App Sandbox.
    public static let secretFileName = ".deepgram_secret"
    public static let consoleURL = URL(string: "https://console.deepgram.com")!
    public static let privacyPolicyURL = URL(string: "https://deepgram.com/privacy")!

    static let model = "nova-3"
    static let restBase = URL(string: "https://api.deepgram.com")!
    static let streamingBase = URL(string: "wss://api.deepgram.com")!
    /// Keyterms sent per request; Deepgram caps the total at 500 tokens.
    static let maximumKeyterms = 50

    /// `language` values Nova-3 accepts, streaming and pre-recorded (`GET /v1/models`, October 2026), plus
    /// `multi` — code-switching between the ten languages in `multilingualCodes`.
    public static let languageCodes = [
        "multi", "af", "ar", "as", "be", "bg", "bn", "bs", "ca", "cs", "da", "de", "el", "en", "es", "et", "eu", "fa",
        "fi", "fr", "gl", "gu", "he", "hi", "hr", "hu", "hy", "id", "it", "ja", "ka", "kk", "kn", "ko", "lt", "lv", "mk",
        "mn", "mr", "ms", "ne", "nl", "no", "pa", "pl", "ps", "pt", "ro", "ru", "sk", "sl", "sr", "sv", "sw", "ta", "te",
        "th", "tl", "tr", "uk", "ur", "uz", "vi", "zh",
    ]
    /// Languages `language=multi` recognizes.
    public static let multilingualCodes = ["en", "es", "fr", "de", "hi", "ru", "pt", "ja", "it", "nl"]

    // MARK: - API key

    public enum KeySource: Sendable, Hashable {
        case keychain
        case environment
        case file
    }

    public struct ResolvedKey: Sendable, Hashable {
        public let value: String
        public let source: KeySource
    }

    /// Keychain first, then `DEEPGRAM_API_KEY`, then `~/.deepgram_secret`. Blank values are skipped, as is a
    /// file that can't be read (in the App Sandbox `home` is nil and the file isn't tried).
    public static func resolveKey(
        keychain: () -> String? = { KeychainStore.get(account: keychainAccount) },
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL? = defaultHome
    ) -> ResolvedKey? {
        if let key = keychain()?.trimmedKey { return ResolvedKey(value: key, source: .keychain) }
        if let key = environment[environmentVariable]?.trimmedKey { return ResolvedKey(value: key, source: .environment) }
        if let home,
            let data = try? Data(contentsOf: home.appendingPathComponent(secretFileName, isDirectory: false)),
            let key = String(data: data, encoding: .utf8)?.trimmedKey
        {
            return ResolvedKey(value: key, source: .file)
        }
        return nil
    }

    /// The user's home folder, or nil inside the App Sandbox (whose home is the app's container).
    public static var defaultHome: URL? {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil
            ? FileManager.default.homeDirectoryForCurrentUser : nil
    }

    // MARK: - Requests

    /// The `language` parameter for an ISO 639-1 code or locale ("en-GB" → "en", "nb" → "no"); nil when Nova-3
    /// doesn't transcribe it.
    public static func requestLanguage(_ code: String) -> String? {
        var base = baseLanguageCode(code)
        if base == "nb" || base == "nn" { base = "no" }
        return languageCodes.contains(base) ? base : nil
    }

    /// Prompt terms as keyterms: trimmed, blank and repeated (case-insensitively) terms dropped, first 50 kept.
    static func keyterms(_ prompt: [String]) -> [String] {
        var seen: Set<String> = []
        var terms: [String] = []
        for term in prompt {
            let trimmed = term.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            terms.append(trimmed)
            if terms.count == maximumKeyterms { break }
        }
        return terms
    }

    /// Options shared by both paths. `mip_opt_out` keeps the audio out of Deepgram's Model Improvement Program.
    static func commonQuery(language: String, keyterms: [String]) -> [(String, String)] {
        [
            ("model", model), ("smart_format", "true"), ("punctuate", "true"), ("mip_opt_out", "true"),
            ("language", language),
        ] + keyterms.map { ("keyterm", $0) }
    }

    /// `POST /v1/listen` for a WAV body.
    static func listenURL(base: URL = restBase, language: String, keyterms: [String]) -> URL {
        url(base: base, path: "/v1/listen", query: commonQuery(language: language, keyterms: keyterms))
    }

    /// `wss://…/v1/listen` for 16 kHz mono Int16 little-endian frames with interim results.
    static func streamingURL(base: URL = streamingBase, language: String, keyterms: [String]) -> URL {
        let stream: [(String, String)] = [
            ("encoding", "linear16"), ("sample_rate", "16000"), ("channels", "1"), ("interim_results", "true"),
            ("endpointing", "300"), ("utterance_end_ms", "1000"),
        ]
        return url(base: base, path: "/v1/listen", query: commonQuery(language: language, keyterms: keyterms) + stream)
    }

    /// Strict percent-encoding (RFC 3986 unreserved characters only), so "+" and "&" in a term survive.
    static func url(base: URL, path: String, query: [(String, String)]) -> URL {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = query.map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.path = path
        components.percentEncodedQuery = encoded.joined(separator: "&")
        return components.url!
    }

    static func authorize(_ request: inout URLRequest, key: String) {
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
    }

    // MARK: - Audio

    /// Float samples in [-1, 1] as 16-bit little-endian PCM.
    static func int16LittleEndian<C: Collection>(_ samples: C) -> Data where C.Element == Float {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for (i, sample) in samples.enumerated() {
                let clamped = max(-1, min(1, sample))
                out[i] = Int16(clamped * Float(Int16.max)).littleEndian
            }
        }
        return data
    }

    /// A 16 kHz mono 16-bit WAV file.
    static func wav(samples16k: [Float]) -> Data {
        let pcm = int16LittleEndian(samples16k)
        var header = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        header.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + pcm.count))
        header.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))  // PCM
        append(UInt16(1))  // mono
        append(UInt32(16_000))
        append(UInt32(16_000 * 2))  // bytes per second
        append(UInt16(2))  // block align
        append(UInt16(16))  // bits per sample
        header.append(contentsOf: Array("data".utf8))
        append(UInt32(pcm.count))
        return header + pcm
    }

    // MARK: - Responses

    struct Word: Decodable, Sendable {
        let word: String
        let punctuatedWord: String?
        let start: Double
        let end: Double
        let confidence: Double?

        enum CodingKeys: String, CodingKey {
            case word, start, end, confidence
            case punctuatedWord = "punctuated_word"
        }

        var displayText: String { punctuatedWord ?? word }
    }

    struct Alternative: Decodable, Sendable {
        let transcript: String
        let confidence: Double?
        let words: [Word]?
        /// Languages detected in `multi` mode.
        let languages: [String]?
    }

    struct ChannelResult: Decodable, Sendable {
        let alternatives: [Alternative]
    }

    /// `POST /v1/listen` response; only what Voiccenger reads.
    struct ListenResponse: Decodable, Sendable {
        struct Results: Decodable, Sendable {
            let channels: [ChannelResult]
        }
        struct Metadata: Decodable, Sendable {
            let duration: Double?
        }
        let results: Results
        let metadata: Metadata?

        var alternative: Alternative? { results.channels.first?.alternatives.first }
    }

    /// Error body of a failed request: `{"err_code": "...", "err_msg": "..."}`.
    struct ErrorBody: Decodable {
        let errCode: String?
        let errMsg: String?

        enum CodingKeys: String, CodingKey {
            case errCode = "err_code"
            case errMsg = "err_msg"
        }
    }

    /// One JSON message from the streaming socket.
    enum StreamMessage: Sendable, Equatable {
        /// Interim (`isFinal == false`) or final text for `start ..< start + duration` seconds of the stream.
        case results(StreamResult)
        /// No word for `utterance_end_ms` after the last one, which ended at `lastWordEnd` stream seconds.
        case utteranceEnd(lastWordEnd: Double)
        /// Sent once the stream has closed (after `CloseStream`); `duration` is the audio Deepgram received.
        case metadata(duration: Double?)
        case speechStarted
        case error(String)
        case other(String)
    }

    struct StreamResult: Sendable, Equatable {
        let start: Double
        let duration: Double
        let isFinal: Bool
        let speechFinal: Bool
        let transcript: String
        let confidence: Double?
        let words: [StreamWord]
    }

    struct StreamWord: Sendable, Equatable {
        let text: String
        let start: Double
        let end: Double
        let confidence: Double?
    }

    static func decodeStreamMessage(_ text: String) throws -> StreamMessage {
        struct Envelope: Decodable {
            let type: String?
        }
        struct Results: Decodable {
            let start: Double
            let duration: Double
            let isFinal: Bool?
            let speechFinal: Bool?
            let channel: ChannelResult

            enum CodingKeys: String, CodingKey {
                case start, duration, channel
                case isFinal = "is_final"
                case speechFinal = "speech_final"
            }
        }
        struct UtteranceEnd: Decodable {
            let lastWordEnd: Double

            enum CodingKeys: String, CodingKey { case lastWordEnd = "last_word_end" }
        }
        struct Metadata: Decodable {
            let duration: Double?
        }
        struct Failure: Decodable {
            let description: String?
            let message: String?
            let errMsg: String?

            enum CodingKeys: String, CodingKey {
                case description, message
                case errMsg = "err_msg"
            }
        }
        let data = Data(text.utf8)
        let decoder = JSONDecoder()
        let type = try decoder.decode(Envelope.self, from: data).type ?? ""
        switch type {
        case "Results":
            let r = try decoder.decode(Results.self, from: data)
            let alternative = r.channel.alternatives.first
            return .results(
                StreamResult(
                    start: r.start, duration: r.duration, isFinal: r.isFinal ?? false, speechFinal: r.speechFinal ?? false,
                    transcript: alternative?.transcript ?? "", confidence: alternative?.confidence,
                    words: (alternative?.words ?? []).map {
                        StreamWord(text: $0.displayText, start: $0.start, end: $0.end, confidence: $0.confidence)
                    }))
        case "UtteranceEnd":
            return .utteranceEnd(lastWordEnd: try decoder.decode(UtteranceEnd.self, from: data).lastWordEnd)
        case "Metadata":
            return .metadata(duration: try decoder.decode(Metadata.self, from: data).duration)
        case "SpeechStarted":
            return .speechStarted
        case "Error":
            let failure = try? decoder.decode(Failure.self, from: data)
            return .error(failure?.description ?? failure?.message ?? failure?.errMsg ?? "Deepgram reported an error.")
        default:
            return .other(type)
        }
    }
}

/// Deepgram failures. Descriptions are user-facing and never include the key.
public enum DeepgramError: Error, LocalizedError, Sendable, Equatable {
    /// No key in the keychain, `DEEPGRAM_API_KEY` or `~/.deepgram_secret`.
    case missingKey
    /// HTTP 401/403.
    case invalidKey
    /// HTTP 402.
    case outOfCredit
    /// HTTP 429 after retries.
    case rateLimited
    /// HTTP 5xx after retries.
    case serverError(Int)
    /// Any other unsuccessful status, with Deepgram's message.
    case requestFailed(Int, String)
    /// No network, DNS failure, timeout.
    case unreachable(String)
    /// The live connection didn't open in time.
    case connectTimeout
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .missingKey: "Add your Deepgram API key in Settings › Voice Models."
        case .invalidKey: "Deepgram API key invalid: Deepgram rejected it. Check or replace it in Settings › Voice Models."
        case .outOfCredit: "Your Deepgram account is out of credit. Add credit at console.deepgram.com."
        case .rateLimited: "Deepgram is rate-limiting requests; try again shortly."
        case .serverError(let status): "Deepgram had a server error (HTTP \(status))."
        case .requestFailed(let status, let message): "Deepgram refused the request (HTTP \(status)): \(message)"
        case .unreachable(let detail): "Can't reach Deepgram: \(detail)"
        case .connectTimeout: "Deepgram's live connection didn't open within 5 seconds."
        case .malformedResponse: "Deepgram returned a response Voiccenger couldn't read."
        }
    }

    /// Status shown for the engine after this failure (`ModelStatus.failed`).
    public var statusMessage: String {
        switch self {
        case .missingKey: "Add your Deepgram API key"
        case .invalidKey: "Deepgram API key rejected"
        case .outOfCredit: "Deepgram account is out of credit"
        case .unreachable, .connectTimeout: "Can't reach Deepgram (offline?)"
        default: errorDescription ?? "Deepgram failed"
        }
    }

    static func status(_ code: Int, body: Data) -> DeepgramError? {
        switch code {
        case 200..<300: return nil
        case 401, 403: return .invalidKey
        case 402: return .outOfCredit
        case 429: return .rateLimited
        case 500..<600: return .serverError(code)
        default:
            let body = try? JSONDecoder().decode(Deepgram.ErrorBody.self, from: body)
            return .requestFailed(code, body?.errMsg ?? body?.errCode ?? HTTPURLResponse.localizedString(forStatusCode: code))
        }
    }
}

/// Where and how to reach Deepgram: key lookup, HTTP session, endpoints and the live socket. Tests inject
/// stubs; `.live` is the real service.
public struct DeepgramAccount: Sendable {
    public var resolveKey: @Sendable () -> Deepgram.ResolvedKey?
    public var session: URLSession
    public var restBase: URL
    public var streamingBase: URL
    /// First retry delay for 429/5xx; doubles per retry.
    public var retryDelay: Duration
    var makeSocket: @Sendable (URLRequest) -> any DeepgramSocket

    public static let live = DeepgramAccount(
        resolveKey: { Deepgram.resolveKey() }, session: .shared, restBase: Deepgram.restBase,
        streamingBase: Deepgram.streamingBase, retryDelay: .milliseconds(500),
        makeSocket: { URLSessionDeepgramSocket(request: $0) })

    init(
        resolveKey: @escaping @Sendable () -> Deepgram.ResolvedKey?, session: URLSession, restBase: URL,
        streamingBase: URL, retryDelay: Duration, makeSocket: @escaping @Sendable (URLRequest) -> any DeepgramSocket
    ) {
        self.resolveKey = resolveKey
        self.session = session
        self.restBase = restBase
        self.streamingBase = streamingBase
        self.retryDelay = retryDelay
        self.makeSocket = makeSocket
    }
}

/// A checked key plus the account it calls.
struct DeepgramClient: Sendable {
    let key: String
    let account: DeepgramAccount

    /// Attempts per request for 429/5xx responses.
    static let maximumAttempts = 3

    /// `GET /v1/projects`: free, and 200 only for a working key.
    func validate() async throws {
        var request = URLRequest(url: account.restBase.appending(path: "v1/projects"))
        request.timeoutInterval = 15
        _ = try await send(request)
    }

    /// Pre-recorded transcription of a WAV body.
    func listen(wav: Data, language: String, keyterms: [String]) async throws -> Deepgram.ListenResponse {
        var request = URLRequest(url: Deepgram.listenURL(base: account.restBase, language: language, keyterms: keyterms))
        request.httpMethod = "POST"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = wav
        request.timeoutInterval = 120
        let data = try await send(request)
        do {
            return try JSONDecoder().decode(Deepgram.ListenResponse.self, from: data)
        } catch {
            throw DeepgramError.malformedResponse
        }
    }

    /// The live socket request, authorized.
    func streamingRequest(language: String, keyterms: [String]) -> URLRequest {
        var request = URLRequest(
            url: Deepgram.streamingURL(base: account.streamingBase, language: language, keyterms: keyterms))
        Deepgram.authorize(&request, key: key)
        return request
    }

    /// Sends with the key, retrying 429 and 5xx with exponential backoff (honouring `Retry-After` up to 10 s).
    private func send(_ request: URLRequest) async throws -> Data {
        var request = request
        Deepgram.authorize(&request, key: key)
        var delay = account.retryDelay
        for attempt in 1...Self.maximumAttempts {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await account.session.data(for: request)
            } catch let error as URLError where error.code != .cancelled {
                throw DeepgramError.unreachable(error.localizedDescription)
            }
            guard let http = response as? HTTPURLResponse else { throw DeepgramError.malformedResponse }
            guard let failure = DeepgramError.status(http.statusCode, body: data) else { return data }
            let retryable = http.statusCode == 429 || (500..<600).contains(http.statusCode)
            guard retryable, attempt < Self.maximumAttempts else { throw failure }
            var wait = delay
            if let header = http.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(header) {
                wait = .milliseconds(Int(min(max(seconds, 0), 10) * 1000))
            }
            transcriptionLog.info("Deepgram HTTP \(http.statusCode); retrying (attempt \(attempt + 1))")
            try await Task.sleep(for: wait)
            delay *= 2
        }
        throw DeepgramError.malformedResponse
    }
}

extension String {
    fileprivate var trimmedKey: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
