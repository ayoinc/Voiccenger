import Foundation
import Testing
import VCModels
@testable import VCIntelligence

/// Serves scripted HTTP responses to a `URLSession`; scripts are keyed by the request's `x-api-key`, so
/// concurrently running tests each get their own.
final class StubProtocol: URLProtocol, @unchecked Sendable {  // URLProtocol state is per-instance; shared state lives in `registry`.
    struct Reply: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data
    }

    struct Script: Sendable {
        var replies: [Reply]
        var requests: [URLRequest] = []
        var bodies: [[String: Any]] {
            requests.compactMap { $0.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
        }
    }

    private static let registry = Mutex<[String: Script]>([:])

    static func session(key: String, replies: [Reply]) -> URLSession {
        registry.withLock { $0[key] = Script(replies: replies) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func script(key: String) -> Script? { registry.withLock { $0[key] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream { recorded.httpBody = Self.read(stream) }
        let key = request.value(forHTTPHeaderField: "x-api-key") ?? ""
        let reply = Self.registry.withLock { scripts -> Reply? in
            guard var script = scripts[key] else { return nil }
            script.requests.append(recorded)
            let reply = script.replies.isEmpty ? nil : script.replies.removeFirst()
            scripts[key] = script
            return reply
        }
        guard let reply, let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 {
            data.append(buffer, count: count)
        }
        return data
    }
}

@Suite struct ClaudeEngineTests {
    let line = ContextLine(
        segmentID: UUID(), speaker: "Daniel", time: 19.6,
        text: "So let's target the launch for Tuesday the fourteenth, sorry, I mean Wednesday the fifteenth.")

    static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    static func toolReply(_ name: String, input: [String: Any], stopReason: String = "tool_use") -> StubProtocol.Reply {
        .init(status: 200, body: json([
            "id": "msg_1", "type": "message", "role": "assistant", "stop_reason": stopReason,
            "content": [
                ["type": "text", "text": "Recording."],
                ["type": "tool_use", "id": "toolu_1", "name": name, "input": input],
            ],
        ]))
    }

    static func errorReply(_ status: Int, type: String, message: String, headers: [String: String] = [:]) -> StubProtocol.Reply {
        .init(status: status, headers: headers, body: json(["type": "error", "error": ["type": type, "message": message]]))
    }

    static var insightInput: [String: Any] {
        [
            "intent": "correction", "correctionKind": "selfCorrection",
            "correctedText": "So let's target the launch for Wednesday the fifteenth.", "contradictsLine": NSNull(),
            "suggestion": NSNull(), "actionItem": NSNull(),
        ]
    }

    func engine(_ key: String, model: String = ClaudeEngine.defaultModel, replies: [StubProtocol.Reply]) -> ClaudeEngine {
        ClaudeEngine(
            apiKey: key, model: model, session: StubProtocol.session(key: key, replies: replies),
            retryPolicy: .init(maxRetries: 3, baseDelay: .milliseconds(1), maxDelay: .milliseconds(5)))
    }

    @Test func analyzeSendsAuthenticatedStrictToolRequestAndDecodesInsight() async throws {
        let key = "k-\(UUID())"
        let engine = engine(key, replies: [Self.toolReply("record_utterance_insight", input: Self.insightInput)])

        let insight = try await engine.analyze(utterance: line, recentContext: [])

        #expect(insight.intent == .correction)
        #expect(insight.correctedText == "So let's target the launch for Wednesday the fifteenth.")
        #expect(insight.correctionReason == "Daniel corrected themselves")
        #expect(insight.suggestion == nil && insight.actionItem == nil)

        let script = try #require(StubProtocol.script(key: key))
        let request = try #require(script.requests.first)
        #expect(request.url == ClaudeEngine.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == key)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = try #require(script.bodies.first)
        #expect(body["model"] as? String == ClaudeEngine.defaultModel)
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["record_utterance_insight"])
        #expect(tools.first?["strict"] as? Bool == true)
        let schema = try #require(tools.first?["input_schema"] as? [String: Any])
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(
            Set(schema["required"] as? [String] ?? [])
                == ["intent", "correctionKind", "correctedText", "contradictsLine", "suggestion", "actionItem"])
        let properties = try #require(schema["properties"] as? [String: Any])
        let kind = try #require(properties["correctionKind"] as? [String: Any])
        #expect(kind["enum"] as? [String] == ["none", "selfCorrection", "contradiction", "mishearing"])
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect((messages.first?["content"] as? String)?.contains("Tuesday the fourteenth") == true)
    }

    @Test func olderModelsGetForcedToolChoice() async throws {
        let key = "k-\(UUID())"
        let engine = engine(key, model: "claude-haiku-4-5", replies: [Self.toolReply("record_utterance_insight", input: Self.insightInput)])
        _ = try await engine.analyze(utterance: line, recentContext: [])
        let body = try #require(StubProtocol.script(key: key)?.bodies.first)
        let choice = try #require(body["tool_choice"] as? [String: Any])
        #expect(choice["type"] as? String == "tool")
        #expect(choice["name"] as? String == "record_utterance_insight")
        #expect(body["output_config"] == nil)
    }

    @Test func forcedToolChoiceRejectionFallsBackToAuto() async throws {
        let key = "k-\(UUID())"
        let engine = engine(key, model: "claude-future-9", replies: [
            Self.errorReply(400, type: "invalid_request_error", message: "tool_choice type 'tool' is not supported for this model"),
            Self.toolReply("record_utterance_insight", input: Self.insightInput),
        ])
        let insight = try await engine.analyze(utterance: line, recentContext: [])
        #expect(insight.intent == .correction)
        let choices = StubProtocol.script(key: key)?.bodies.compactMap { ($0["tool_choice"] as? [String: Any])?["type"] as? String }
        #expect(choices == ["tool", "auto"])
    }

    @Test func retriesRateLimitAndOverloadThenSucceeds() async throws {
        let key = "k-\(UUID())"
        let engine = engine(key, replies: [
            Self.errorReply(429, type: "rate_limit_error", message: "slow down", headers: ["retry-after": "0"]),
            Self.errorReply(529, type: "overloaded_error", message: "Overloaded"),
            Self.toolReply("record_utterance_insight", input: Self.insightInput),
        ])
        let insight = try await engine.analyze(utterance: line, recentContext: [])
        #expect(insight.intent == .correction)
        #expect(StubProtocol.script(key: key)?.requests.count == 3)
    }

    @Test func givesUpAfterThreeRetriesWithStatusAndMessage() async throws {
        let key = "k-\(UUID())"
        let overloaded = Self.errorReply(529, type: "overloaded_error", message: "Overloaded")
        let engine = engine(key, replies: Array(repeating: overloaded, count: 6))
        await #expect(throws: IntelligenceError.http(status: 529, type: "overloaded_error", message: "Overloaded")) {
            try await engine.analyze(utterance: line, recentContext: [])
        }
        #expect(StubProtocol.script(key: key)?.requests.count == 4)
    }

    @Test func clientErrorsAreNotRetried() async throws {
        let key = "k-\(UUID())"
        let engine = engine(key, replies: [
            Self.errorReply(401, type: "authentication_error", message: "invalid x-api-key"),
            Self.toolReply("record_utterance_insight", input: Self.insightInput),
        ])
        do {
            _ = try await engine.analyze(utterance: line, recentContext: [])
            Issue.record("expected an HTTP error")
        } catch let error as IntelligenceError {
            #expect(error == .http(status: 401, type: "authentication_error", message: "invalid x-api-key"))
            #expect(error.errorDescription?.contains("401") == true)
            #expect(error.errorDescription?.contains("invalid x-api-key") == true)
        }
        #expect(StubProtocol.script(key: key)?.requests.count == 1)
    }

    @Test func nonJSONErrorBodyIsSurfacedVerbatim() {
        let error = ClaudeEngine.httpError(status: 502, data: Data("<html>Bad gateway</html>".utf8))
        #expect(error == .http(status: 502, type: nil, message: "<html>Bad gateway</html>"))
    }

    @Test func refusalAndTruncationAreReported() async throws {
        let refusedKey = "k-\(UUID())"
        let refused = engine(refusedKey, replies: [.init(status: 200, body: Self.json([
            "stop_reason": "refusal", "content": [["type": "text", "text": "I can't help with that."]],
        ]))])
        await #expect(throws: IntelligenceError.refused("I can't help with that.")) {
            try await refused.analyze(utterance: line, recentContext: [])
        }

        let truncatedKey = "k-\(UUID())"
        let truncated = engine(truncatedKey, replies: [Self.toolReply("record_utterance_insight", input: [:], stopReason: "max_tokens")])
        await #expect(throws: IntelligenceError.truncatedResponse) {
            try await truncated.analyze(utterance: line, recentContext: [])
        }
    }

    @Test func missingToolCallIsRetriedOnceThenReported() async throws {
        let key = "k-\(UUID())"
        let textOnly = StubProtocol.Reply(status: 200, body: Self.json([
            "stop_reason": "end_turn", "content": [["type": "text", "text": "The intent is a correction."]],
        ]))
        let engine = engine(key, replies: [textOnly, textOnly, textOnly])
        await #expect(throws: IntelligenceError.malformedResponse("no record_utterance_insight tool call in the response")) {
            try await engine.analyze(utterance: line, recentContext: [])
        }
        #expect(StubProtocol.script(key: key)?.requests.count == 2)
    }

    @Test func reportDecodesIntoMeetingReportInOneCall() async throws {
        let key = "k-\(UUID())"
        let transcript = try Fixture.transcript()
        let input: [String: Any] = [
            "title": "Quarterly planning review",
            "overview": "The team set the mobile app launch for Wednesday the fifteenth.",
            "topics": [["title": "Launch date", "summary": "Agreed on Wednesday the fifteenth.", "speakers": ["Daniel", "Samantha"]]],
            "decisions": [
                ["text": "Launch on Wednesday the fifteenth.", "lines": [5, 10]],
                ["text": "Freeze features by the end of the month.", "lines": ["L6", "L7"]],
                ["text": "Thank everyone for coming.", "lines": [10]],
            ],
            "actionItems": [
                ["task": "Send the updated budget to everyone", "owner": "Rishi", "due": "Friday", "lines": [7]],
                ["task": "Share the press kit with Karen's team", "owner": "Samantha", "due": "Monday", "lines": [8, 9]],
                ["task": "Start the planning review", "owner": "Daniel", "due": NSNull(), "lines": [1]],
            ],
            "notesToRemember": [["text": "Marketing needs at least three weeks of notice.", "lines": [4]]],
            "missedOpportunities": ["Nobody confirmed the launch leaves marketing three weeks of notice."],
            "openQuestions": [],
            "corrections": [[
                "speaker": "Daniel", "kind": "selfCorrection", "original": "Tuesday the fourteenth",
                "corrected": "Wednesday the fifteenth", "lines": [5],
            ]],
            "participantSummaries": [["name": "Karen", "keyPoints": [["text": "Needs three weeks of notice.", "lines": [4]]]]],
            "outline": [
                ["heading": "Engineering and marketing status", "points": [
                    ["speaker": "Rishi", "text": "Engineering on track, payment integration finished last week", "lines": [3]],
                    ["speaker": "Karen", "text": "Marketing needs three weeks of notice before a launch", "lines": [4]],
                ]],
                ["heading": "Launch plan", "points": [
                    ["speaker": "Daniel", "text": "Targets the launch for Wednesday the fifteenth", "lines": [5]],
                    // Rishi only promised to send it.
                    ["speaker": "Rishi", "text": "Sent the updated budget to everyone", "lines": [7]],
                    ["speaker": "Samantha", "text": "Will share the press kit on Monday", "lines": [9]],
                ]],
            ],
        ]
        let engine = engine(key, replies: [Self.toolReply("record_meeting_report", input: input)])

        let report = try await engine.report(transcript: transcript, participants: try Fixture.speakers, meetingTitle: nil)

        #expect(StubProtocol.script(key: key)?.requests.count == 1)
        #expect(report.title == "Quarterly planning review")
        #expect(report.generatedBy == "Claude (\(ClaudeEngine.defaultModel))")
        #expect(report.decisions == ["Launch on Wednesday the fifteenth.", "Freeze features by the end of the month."])
        #expect(report.actionItems.map(\.owner) == ["Rishi", "Samantha"])
        #expect(report.actionItems.map(\.sourceSegmentID) == [Fixture.segmentID(6), Fixture.segmentID(8)])
        #expect(report.notesToRemember == ["Marketing needs at least three weeks of notice."])
        #expect(report.participantSummaries == [ParticipantSummary(name: "Karen", keyPoints: ["Needs three weeks of notice."])])
        #expect(report.corrections.map(\.corrected) == ["Wednesday the fifteenth"])
        #expect(report.corrections.map(\.reason) == ["Daniel corrected themselves"])
        // A 48-second meeting gets one segment, headed by the one with the most of the model's points.
        #expect(report.outline.map(\.heading) == ["Engineering and marketing status"])
        // Samantha's point copies her line, so it is shown as a quote.
        #expect(report.outline.flatMap(\.points).map(\.speaker) == ["Rishi", "Karen", "Daniel", "Samantha"])
        #expect(report.outline.flatMap(\.points).map(\.isQuote) == [false, false, false, true])
        #expect(report.outline.first?.start == transcript.first?.time)
        let body = try #require(StubProtocol.script(key: key)?.bodies.first)
        let prompt = try #require((body["messages"] as? [[String: Any]])?.first?["content"] as? String)
        for (index, line) in transcript.enumerated() {
            #expect(prompt.contains("L\(index + 1) [\(TranscriptFormatter.timestamp(line.time))] \(line.speaker): \(line.text)"))
        }
        // The tool schema asks for cited lines on every list item.
        let schema = try #require((body["tools"] as? [[String: Any]])?.first?["input_schema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        for key in ["decisions", "actionItems", "notesToRemember", "openQuestions", "corrections"] {
            let items = try #require((properties[key] as? [String: Any])?["items"] as? [String: Any])
            #expect((items["required"] as? [String])?.contains("lines") == true, "\(key) lacks lines")
        }
        let segment = try #require((properties["outline"] as? [String: Any])?["items"] as? [String: Any])
        let point = try #require((segment["properties"] as? [String: Any])?["points"] as? [String: Any])
        #expect(((point["items"] as? [String: Any])?["required"] as? [String]) == ["speaker", "text", "lines"])
    }

    @Test func oversizedTranscriptIsRejectedBeforeAnyRequest() async throws {
        let key = "k-\(UUID())"
        let engine = engine(key, replies: [])
        let text = String(repeating: "word ", count: 2_000)
        let transcript = (0..<70).map { ContextLine(segmentID: UUID(), speaker: "A", time: Double($0), text: text) }
        await #expect {
            try await engine.report(transcript: transcript, participants: [], meetingTitle: nil)
        } throws: { error in
            guard case IntelligenceError.transcriptTooLong(let characters, let limit) = error else { return false }
            return characters > limit && limit == ClaudeEngine.maxTranscriptCharacters
        }
        #expect(StubProtocol.script(key: key)?.requests.isEmpty == true)
    }

    @Test func retryDelayHonoursRetryAfterAndGrowsExponentially() {
        let engine = ClaudeEngine(
            apiKey: "x", model: ClaudeEngine.defaultModel, session: .shared,
            retryPolicy: .init(maxRetries: 3, baseDelay: .seconds(1), maxDelay: .seconds(60)))
        #expect(engine.retryDelay(attempt: 0, retryAfter: "7") == .seconds(7))
        #expect(engine.retryDelay(attempt: 0, retryAfter: "600") == .seconds(60))
        for attempt in 0..<3 {
            let delay = engine.retryDelay(attempt: attempt, retryAfter: nil)
            let base = Duration.seconds(1 << attempt)
            #expect(delay >= base && delay <= base * 1.25)
        }
    }
}

/// Real Messages API round trips; run only when `ANTHROPIC_API_KEY` is set.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?.isEmpty == false), .serialized)
struct ClaudeLiveTests {
    var engine: ClaudeEngine { ClaudeEngine(apiKey: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]!) }

    @Test func correctsSelfCorrectedDate() async throws {
        let transcript = try Fixture.transcript()
        let insight = try await engine.analyze(utterance: transcript[4], recentContext: Array(transcript[0..<4]))
        let corrected = try #require(insight.correctedText)
        #expect(corrected.localizedCaseInsensitiveContains("Wednesday"))
        #expect(!corrected.localizedCaseInsensitiveContains("Tuesday"))
    }

    @Test func leavesCleanUtteranceUncorrected() async throws {
        let transcript = try Fixture.transcript()
        let insight = try await engine.analyze(utterance: transcript[2], recentContext: Array(transcript[0..<2]))
        #expect(insight.correctedText == nil)
    }

    @Test func reportsFixtureMeeting() async throws {
        let report = try await engine.report(transcript: try Fixture.transcript(), participants: try Fixture.speakers, meetingTitle: nil)
        #expect(report.actionItems.contains { $0.owner == "Rishi" && $0.task.localizedCaseInsensitiveContains("budget") })
        #expect(report.actionItems.contains { $0.owner == "Samantha" && $0.task.localizedCaseInsensitiveContains("press kit") })
        #expect(report.decisions.contains { $0.localizedCaseInsensitiveContains("Wednesday") })
    }
}
