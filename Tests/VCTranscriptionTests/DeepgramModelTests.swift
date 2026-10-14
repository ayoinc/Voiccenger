import Foundation
import Testing
import VCModels
@testable import VCTranscription

/// A trimmed `GET /v1/models` response: per-language streaming/batch entries, several versions of one model,
/// a multilingual entry, Deepgram's internal test and phoneme models, and text-to-speech models.
enum ModelsFixture {
    static let body = DeepgramStub.json([
        "stt": [
            entry("nova-3-general", "nova-3", ["en", "en-US", "en-GB"], "2025-01-01.0", batch: false, streaming: true),
            entry("nova-3-general", "nova-3", ["en", "en-US"], "2025-02-01.0", batch: true, streaming: false),
            entry("nova-3-general", "nova-3", ["de", "en", "fr"], "2025-03-01.0", batch: true, streaming: true, multilingual: true),
            entry("nova-3-general", "nova-3", ["sw"], "2026-10-02.1", batch: true, streaming: false),
            entry("nova-2-meeting", "nova-2", ["en", "en-US"], "2024-02-07.1", batch: true, streaming: true),
            entry("whisper-large", "whisper", ["en", "sw", "yo"], "2022-12-08.0", batch: true, streaming: false),
            entry("meeting", "base", ["en"], "2022-06-27.0", batch: true, streaming: true),
            entry("general-dQw4w9WgXcQ", "base", ["en"], "2021-10-12.0", batch: true, streaming: true),
            entry("phoneme", "base", ["en"], "2020-04-02.0", batch: true, streaming: true),
            entry("nova-2-general", "nova-2", ["nb", "en"], "2024-01-01.0", batch: true, streaming: true),
        ],
        "tts": [
            ["name": "aura-asteria-en", "canonical_name": "aura-asteria-en", "architecture": "aura", "languages": ["en"], "version": "2023-11-08.0"]
        ],
    ])

    static func entry(
        _ name: String, _ architecture: String, _ languages: [String], _ version: String, batch: Bool, streaming: Bool,
        multilingual: Bool = false
    ) -> [String: Any] {
        [
            "name": name.components(separatedBy: "-").last ?? name, "canonical_name": name, "architecture": architecture,
            "languages": languages, "version": version, "uuid": UUID().uuidString, "batch": batch, "streaming": streaming,
            "formatted_output": true, "multilingual": multilingual,
        ]
    }

    static func catalog() throws -> DeepgramModelCatalog {
        try DeepgramModelCatalog.decode(body, source: .publicList, fetchedAt: Date(timeIntervalSince1970: 0))
    }

    /// Serves the key check, the project and its models (or `projectModelsStatus` there), `/v1/models` and
    /// `/v1/listen` (whose transcript names the model it was asked for).
    static func account(
        host: String, sockets: SocketQueue = SocketQueue([]), projectModelsStatus: Int = 200,
        listenStatus: @escaping @Sendable (String) -> Int = { _ in 200 }
    ) -> DeepgramAccount {
        DeepgramStub.account(host: host, sockets: sockets) { request, _ in
            let path = request.url?.path ?? ""
            switch path {
            case "/v1/projects":
                return (200, DeepgramStub.json(["projects": [["project_id": "p1", "name": "Mine"]]]))
            case "/v1/projects/p1/models":
                return projectModelsStatus == 200 ? (200, body) : (projectModelsStatus, Data(#"{"err_msg":"User does not have sufficient permissions."}"#.utf8))
            case "/v1/models":
                return (200, body)
            case "/v1/listen":
                let model = query(request, "model") ?? ""
                let status = listenStatus(model)
                guard status == 200 else { return (status, Data(#"{"err_code":"Bad Request","err_msg":"No such model."}"#.utf8)) }
                return (200, listen(transcript: "said by \(model)"))
            default:
                return (404, Data())
            }
        }
    }

    static func listen(transcript: String) -> Data {
        DeepgramStub.json([
            "metadata": ["duration": 1.0],
            "results": ["channels": [["alternatives": [["transcript": transcript, "confidence": 0.9, "words": []]]]]],
        ])
    }

    static func query(_ request: URLRequest, _ name: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}

@Suite struct DeepgramModelCatalogTests {
    @Test func decodesSpeechModelsGroupedByCanonicalName() throws {
        let catalog = try ModelsFixture.catalog()
        // Text-to-speech, test (mixed-case) and phoneme models are left out; newest families first, general first.
        #expect(catalog.models.map(\.name) == ["nova-3-general", "nova-2-general", "nova-2-meeting", "whisper-large", "meeting"])
        #expect(catalog.source == .publicList)

        let nova3 = try #require(catalog.model(named: "nova-3"))
        #expect(nova3.name == "nova-3-general" && nova3.architecture == "nova-3" && nova3.version == "2026-10-02.1")
        #expect(nova3.streamingLanguageCodes == ["de", "en", "fr", "multi"])
        #expect(nova3.batchLanguageCodes == ["de", "en", "fr", "multi", "sw"])
        #expect(nova3.canStream && nova3.family == "Nova-3" && nova3.displayName == "Nova-3 General")
        #expect(nova3.transcribes("sw", live: false) && !nova3.transcribes("sw", live: true))
        #expect(nova3.transcribes("en-GB", live: true) && nova3.requestLanguage("en-GB", live: true) == "en")
        #expect(nova3.transcribes("multi", live: true))

        let whisper = try #require(catalog.model(named: "WHISPER-LARGE"))
        #expect(!whisper.canStream && whisper.family == "Whisper" && whisper.displayName == "Whisper Large")
        let base = try #require(catalog.model(named: "meeting"))
        #expect(base.displayName == "Base Meeting" && base.family == "Base")
        // Norwegian Bokmål counts as Norwegian; the request uses the code Deepgram listed.
        let nova2 = try #require(catalog.model(named: "nova-2"))
        #expect(nova2.languageCodes == ["en", "no"] && nova2.requestLanguage("no", live: true) == "nb")
        #expect(catalog.model(named: "nova-9") == nil)
    }

    @Test func filtersByLanguageAndUse() throws {
        let catalog = try ModelsFixture.catalog()
        #expect(catalog.models(transcribing: "yo").map(\.name) == ["whisper-large"])
        #expect(catalog.models(transcribing: "sw").map(\.name) == ["nova-3-general", "whisper-large"])
        #expect(catalog.models(transcribing: "sw", live: true).isEmpty)
        #expect(catalog.models(transcribing: "en-GB", live: true).map(\.name) == ["nova-3-general", "nova-2-general", "nova-2-meeting", "meeting"])
        #expect(catalog.models(transcribing: "en", live: false).count == 5)
        #expect(catalog.models(transcribing: "ja").isEmpty)
    }

    @Test func catalogRoundTripsThroughJSON() throws {
        let catalog = try ModelsFixture.catalog()
        let decoded = try JSONDecoder().decode(DeepgramModelCatalog.self, from: JSONEncoder().encode(catalog))
        #expect(decoded == catalog)
    }

    @Test func modelNames() {
        #expect(Deepgram.modelDisplayName("nova-3") == "Nova-3")
        #expect(Deepgram.modelDisplayName("nova-2-conversationalai") == "Nova-2 Conversational AI")
        #expect(Deepgram.modelDisplayName("enhanced-drivethru") == "Enhanced Drive-thru")
        #expect(Deepgram.isDefaultModel(nil) && Deepgram.isDefaultModel(" Nova-3-General ") && !Deepgram.isDefaultModel("nova-2"))
        #expect(Deepgram.sameModel("nova-3", nil) && Deepgram.sameModel("nova-2-meeting", "NOVA-2-MEETING"))
        #expect(!Deepgram.sameModel("nova-3", "nova-2-meeting") && !Deepgram.sameModel(nil, "whisper-large"))
    }

    @Test func choosesTheModelOrNovaThreeWithAReason() throws {
        let catalog = try ModelsFixture.catalog()
        func choose(_ model: String?, _ language: String, live: Bool, catalog: DeepgramModelCatalog? = catalog) -> Deepgram.ModelChoice {
            Deepgram.chooseModel(model, languageCode: language, live: live, catalog: catalog)
        }
        #expect(choose(nil, "en-GB", live: true) == .init(model: "nova-3", language: "en"))
        #expect(choose("nova-3-general", "yo", live: false) == .init(model: "nova-3", language: nil))
        #expect(choose("nova-2-meeting", "en-GB", live: true) == .init(model: "nova-2-meeting", language: "en"))
        #expect(choose("whisper-large", "yo", live: false) == .init(model: "whisper-large", language: "yo"))
        // Without the key's models the request is trusted.
        #expect(choose("nova-2-meeting", "en-GB", live: true, catalog: nil) == .init(model: "nova-2-meeting", language: "en"))

        #expect(
            choose("whisper-large", "en", live: true)
                == .init(model: "nova-3", language: "en", fallbackReason: "Whisper Large can't stream English live, so Nova-3 is used instead"))
        #expect(
            choose("nova-2-meeting", "sw", live: false)
                == .init(model: "nova-3", language: "sw", fallbackReason: "Nova-2 Meeting doesn't transcribe Swahili, so Nova-3 is used instead"))
        #expect(
            choose("nova-9", "en", live: true)
                == .init(model: "nova-3", language: "en", fallbackReason: "Nova-9 isn't available to this Deepgram key, so Nova-3 is used instead"))
        // Neither the model nor Nova-3 transcribes Yoruba.
        #expect(choose("nova-2-meeting", "yo", live: false).language == nil)
    }
}

@Suite struct DeepgramModelFetchTests {
    @Test func fetchesTheProjectsModelsOnceAndRefreshes() async throws {
        let host = DeepgramStub.host()
        let library = DeepgramStub.library(ModelsFixture.account(host: host))
        let catalog = try await library.deepgramModels()
        #expect(catalog.source == .project && catalog.models.count == 5)
        let requests = StubProtocol.recorded(host: host)
        #expect(requests.map(\.url?.path) == ["/v1/projects", "/v1/projects", "/v1/projects/p1/models"])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Token test-key" })
        #expect(requests.allSatisfy { !($0.url?.absoluteString.contains("test-key") ?? true) })

        _ = try await library.deepgramModels()
        #expect(StubProtocol.recorded(host: host).count == 3, "cached for the launch")
        _ = try await library.deepgramModels(refresh: true)
        #expect(StubProtocol.recorded(host: host).count == 5)

        // A new key forgets the models.
        await library.deepgramKeyChanged()
        _ = try await library.deepgramModels()
        #expect(StubProtocol.recorded(host: host).filter { $0.url?.path == "/v1/projects/p1/models" }.count == 3)
    }

    @Test func fallsBackToThePublicListWhenTheKeyCantReadItsProject() async throws {
        let host = DeepgramStub.host()
        let library = DeepgramStub.library(ModelsFixture.account(host: host, projectModelsStatus: 403))
        let catalog = try await library.deepgramModels()
        #expect(catalog.source == .publicList && catalog.models.count == 5)
        #expect(StubProtocol.recorded(host: host).map(\.url?.path).last == "/v1/models")
        // The key still counts as valid.
        #expect(await library.status(.deepgram) == .ready)

        // No project at all: straight to the public list.
        let bare = DeepgramStub.host()
        let noProject = DeepgramStub.library(
            DeepgramStub.account(host: bare) { request, _ in
                request.url?.path == "/v1/models" ? (200, ModelsFixture.body) : (200, Data("{}".utf8))
            })
        #expect(try await noProject.deepgramModels().source == .publicList)
        #expect(StubProtocol.recorded(host: bare).map(\.url?.path) == ["/v1/projects", "/v1/projects", "/v1/models"])
    }

    @Test func unreadableModelsAndMissingKeyFail() async throws {
        let garbled = DeepgramStub.library(
            DeepgramStub.account(host: DeepgramStub.host()) { request, _ in
                request.url?.path == "/v1/models" ? (200, Data("[1,2]".utf8)) : (200, Data("{}".utf8))
            })
        await #expect(throws: DeepgramError.malformedResponse) { _ = try await garbled.deepgramModels() }

        let missing = DeepgramStub.library(DeepgramStub.account(key: nil, host: DeepgramStub.host()) { _, _ in (200, Data()) })
        await #expect(throws: DeepgramError.missingKey) { _ = try await missing.deepgramModels() }
        // Without the models a chosen model is trusted.
        #expect(await missing.deepgramModelChoice("nova-2-meeting", languageCode: "en", live: true).model == "nova-2-meeting")
    }
}

@Suite struct DeepgramModelTranscriptionTests {
    @Test func transcribesWithTheChosenModelOrNovaThree() async throws {
        let host = DeepgramStub.host()
        let library = DeepgramStub.library(ModelsFixture.account(host: host))
        let audio = [Float](repeating: 0.1, count: 1_600)

        let meeting = try await library.transcriber(.deepgram, deepgramModel: "nova-2-meeting")
        #expect(meeting.model == "nova-2-meeting")
        let english = try await meeting.transcribe(samples16k: audio, languageCode: "en-GB", prompt: [])
        #expect(english.text == "said by nova-2-meeting" && english.model == "nova-2-meeting" && english.modelFallbackReason == nil)

        // Nova-2 Meeting doesn't transcribe Swahili: Nova-3 does, and says why.
        let swahili = try await meeting.transcribe(samples16k: audio, languageCode: "sw", prompt: [])
        #expect(swahili.text == "said by nova-3" && swahili.model == "nova-3" && swahili.languageCode == "sw")
        #expect(swahili.modelFallbackReason == "Nova-2 Meeting doesn't transcribe Swahili, so Nova-3 is used instead")

        let listens = StubProtocol.recorded(host: host).filter { $0.url?.path == "/v1/listen" }
        #expect(listens.map { ModelsFixture.query($0, "model") } == ["nova-2-meeting", "nova-3"])
        #expect(listens.map { ModelsFixture.query($0, "language") } == ["en", "sw"])

        // The default needs no model list.
        let plain = DeepgramStub.library(ModelsFixture.account(host: DeepgramStub.host()))
        #expect(try await plain.transcriber(.deepgram).transcribe(samples16k: audio, languageCode: "en", prompt: []).model == "nova-3")
    }

    @Test func aModelDeepgramRefusesFallsBackToNovaThree() async throws {
        let host = DeepgramStub.host()
        let library = DeepgramStub.library(
            ModelsFixture.account(host: host, listenStatus: { $0 == "nova-2-meeting" ? 400 : 200 }))
        let result = try await library.transcriber(.deepgram, deepgramModel: "nova-2-meeting")
            .transcribe(samples16k: [Float](repeating: 0.1, count: 1_600), languageCode: "en", prompt: [])
        #expect(result.text == "said by nova-3" && result.model == "nova-3")
        #expect(result.modelFallbackReason == "Deepgram refused Nova-2 Meeting (No such model.), so Nova-3 is used instead")
    }

    @Test func calibrationScoresEachDeepgramModel() async throws {
        let library = DeepgramStub.library(ModelsFixture.account(host: DeepgramStub.host()))
        let calibration = await VoiceCalibrator.calibrate(
            samples16k: [Float](repeating: 0.1, count: 1_600), expected: "said by nova-2-meeting", engines: [.deepgram],
            languageCode: "en", deepgramModels: ["nova-3", "nova-2-meeting", "nova-9", "meeting"], library: library)
        // nova-9 isn't available, falls back to Nova-3 and isn't scored twice.
        #expect(calibration.scores.map(\.model) == ["nova-2-meeting", "nova-3", "meeting"])
        #expect(calibration.scores.allSatisfy { $0.engine == .deepgram })
        #expect(calibration.best?.wordErrorRate == 0 && calibration.bestDeepgramModel == "nova-2-meeting")
    }
}

@Suite struct DeepgramModelStreamingTests {
    private static func live(model: String, socket: FakeSocket) async throws -> (DeepgramLiveTranscriber, SocketQueue) {
        let sockets = SocketQueue([socket])
        var options = DeepgramLiveTranscriber.Options()
        options.model = model
        options.finishTimeout = .milliseconds(200)
        let live = DeepgramLiveTranscriber(
            channel: .microphone, localeID: "en-GB", languageCode: "en", prompt: [],
            library: DeepgramStub.library(ModelsFixture.account(host: DeepgramStub.host(), sockets: sockets)),
            options: options, makeFallback: { _ in FakeFallback() })
        try await live.start()
        return (live, sockets)
    }

    @Test func streamsWithTheChosenModel() async throws {
        let (live, sockets) = try await Self.live(model: "nova-2-meeting", socket: FakeSocket())
        #expect(await live.fallbackReason == nil)
        #expect(await live.modelFallbackReason == nil)
        let request = try #require(sockets.requests.first)
        #expect(ModelsFixture.query(request, "model") == "nova-2-meeting")
        #expect(ModelsFixture.query(request, "language") == "en")
        await live.finish()
    }

    @Test func aModelThatCantStreamUsesNovaThree() async throws {
        let (live, sockets) = try await Self.live(model: "whisper-large", socket: FakeSocket())
        #expect(await live.fallbackReason == nil)
        #expect(await live.modelFallbackReason == "Whisper Large can't stream English live, so Nova-3 is used instead")
        #expect(ModelsFixture.query(try #require(sockets.requests.first), "model") == "nova-3")
        await live.finish()
    }

    @Test func aModelDeepgramRefusesReconnectsWithNovaThree() async throws {
        let refused = FakeSocket(openError: .requestFailed(400, "Bad Request"))
        let sockets = SocketQueue([refused, FakeSocket()])
        // The model list can't be fetched, so the model is tried as asked.
        let library = DeepgramStub.library(
            DeepgramStub.account(host: DeepgramStub.host(), sockets: sockets) { request, _ in
                request.url?.path == "/v1/models" ? (404, Data()) : (200, Data("{}".utf8))
            })
        var options = DeepgramLiveTranscriber.Options()
        options.model = "nova-2-meeting"
        options.finishTimeout = .milliseconds(200)
        let live = DeepgramLiveTranscriber(
            channel: .microphone, localeID: "en-GB", languageCode: "en", prompt: [], library: library, options: options,
            makeFallback: { _ in FakeFallback() })
        try await live.start()
        #expect(await live.fallbackReason == nil)
        #expect(await live.modelFallbackReason == "Deepgram refused Nova-2 Meeting (Bad Request), so Nova-3 is used instead")
        #expect(sockets.requests.map { ModelsFixture.query($0, "model") } == ["nova-2-meeting", "nova-3"])
        await live.finish()
    }
}
