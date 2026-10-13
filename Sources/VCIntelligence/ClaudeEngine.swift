import Foundation
import VCModels

/// Claude via the Messages API. Structured output comes from a single tool whose JSON schema mirrors the
/// VCModels types; the tool's `input` is decoded leniently and cleaned up like every other engine's output.
public final class ClaudeEngine: MeetingIntelligence {
    public static let defaultModel = "claude-opus-5-5"
    /// Formatted-transcript size accepted for a single report request (~150k tokens, well inside the
    /// 1M-token window of current models while keeping latency and cost bounded).
    public static let maxTranscriptCharacters = 600_000

    struct RetryPolicy: Sendable {
        /// Retries after the first attempt for 429 / 529.
        var maxRetries = 3
        var baseDelay: Duration = .seconds(1)
        var maxDelay: Duration = .seconds(60)
    }

    /// How the tool call is requested. Some models reject forced `tool_choice` (400), so those get
    /// `auto` with a strict tool plus an explicit instruction, and a check that the call happened.
    enum ToolChoiceMode: Equatable, Sendable {
        case forced
        case auto
    }

    enum Task: Sendable {
        case insight
        case report

        var toolName: String {
            switch self {
            case .insight: "record_utterance_insight"
            case .report: "record_meeting_report"
            }
        }

        var maxTokens: Int {
            switch self {
            case .insight: 4_096
            case .report: 16_000
            }
        }

        var effort: String {
            switch self {
            case .insight: "low"
            case .report: "medium"
            }
        }

        var timeout: TimeInterval {
            switch self {
            case .insight: 90
            case .report: 600
            }
        }
    }

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"
    /// Models that return 400 for `tool_choice` `tool`/`any` (and accept `output_config.effort`).
    static let autoToolChoiceModelPrefixes = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-1", "claude-mythos-5-1"]

    public let model: String
    private let apiKey: String
    private let session: URLSession
    private let retryPolicy: RetryPolicy

    public var engineName: String { "Claude (\(model))" }

    public convenience init(apiKey: String, model: String = ClaudeEngine.defaultModel, session: URLSession = .shared) {
        self.init(apiKey: apiKey, model: model, session: session, retryPolicy: RetryPolicy())
    }

    init(apiKey: String, model: String, session: URLSession, retryPolicy: RetryPolicy) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.retryPolicy = retryPolicy
    }

    // MARK: MeetingIntelligence

    public func analyze(utterance: ContextLine, recentContext: [ContextLine]) async throws -> UtteranceInsight {
        let context = Array(recentContext.suffix(40))
        let prompt = IntelligencePrompts.analysisPrompt(utterance: utterance, recentContext: context)
        let input = try await callTool(.insight, system: IntelligencePrompts.analysisInstructions, userText: prompt)
        let raw = try decode(RawInsight.self, from: input)
        return ResultAssembler.insight(from: raw, utterance: utterance, context: context)
    }

    public func report(transcript: [ContextLine], participants: [String], meetingTitle: String?) async throws -> MeetingReport {
        let prompt = IntelligencePrompts.reportPrompt(transcript: transcript, participants: participants, meetingTitle: meetingTitle)
        guard prompt.count <= Self.maxTranscriptCharacters else {
            throw IntelligenceError.transcriptTooLong(characters: prompt.count, limit: Self.maxTranscriptCharacters)
        }
        let input = try await callTool(.report, system: IntelligencePrompts.reportInstructions, userText: prompt)
        let raw = try decode(RawReport.self, from: input)
        return ResultAssembler.report(
            from: raw, transcript: transcript, participants: participants, meetingTitle: meetingTitle, generatedBy: engineName)
    }

    // MARK: Request

    static func initialToolChoiceMode(for model: String) -> ToolChoiceMode {
        autoToolChoiceModelPrefixes.contains { model.hasPrefix($0) } ? .auto : .forced
    }

    func requestBody(_ task: Task, system: String, userText: String, mode: ToolChoiceMode) throws -> Data {
        var tool = Self.tool(for: task)
        tool["strict"] = true
        var systemText = system
        var body: [String: Any] = [
            "model": model,
            "max_tokens": task.maxTokens,
            "tools": [tool],
            "messages": [["role": "user", "content": userText]],
        ]
        switch mode {
        case .forced:
            body["tool_choice"] = ["type": "tool", "name": task.toolName]
        case .auto:
            body["tool_choice"] = ["type": "auto"]
            systemText += "\n\nRespond only by calling the \(task.toolName) tool exactly once."
            if Self.initialToolChoiceMode(for: model) == .auto {
                body["output_config"] = ["effort": task.effort]
            }
        }
        body["system"] = systemText
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    func urlRequest(_ task: Task, body: Data) -> URLRequest {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: task.timeout)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = body
        return request
    }

    /// Returns the JSON `input` of the requested tool call.
    func callTool(_ task: Task, system: String, userText: String) async throws -> Data {
        var mode = Self.initialToolChoiceMode(for: model)
        var retriedMissingCall = false
        while true {
            let body = try requestBody(task, system: system, userText: userText, mode: mode)
            let (data, response) = try await send(urlRequest(task, body: body))
            guard (200..<300).contains(response.statusCode) else {
                let error = Self.httpError(status: response.statusCode, data: data)
                if mode == .forced, response.statusCode == 400, case .http(_, _, let message) = error,
                    message.localizedCaseInsensitiveContains("tool_choice")
                {
                    mode = .auto
                    continue
                }
                throw error
            }
            if let input = try Self.toolInput(named: task.toolName, in: data) { return input }
            if mode == .auto, !retriedMissingCall {
                retriedMissingCall = true
                continue
            }
            throw IntelligenceError.malformedResponse("no \(task.toolName) tool call in the response")
        }
    }

    /// Sends, retrying 429 (rate limited) and 529 (overloaded) with exponential backoff or `retry-after`.
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw IntelligenceError.malformedResponse("not an HTTP response")
            }
            guard [429, 529].contains(http.statusCode), attempt < retryPolicy.maxRetries else {
                return (data, http)
            }
            try await Swift.Task.sleep(for: retryDelay(attempt: attempt, retryAfter: http.value(forHTTPHeaderField: "retry-after")))
            attempt += 1
        }
    }

    func retryDelay(attempt: Int, retryAfter: String?) -> Duration {
        if let retryAfter, let seconds = Double(retryAfter.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
            return min(.milliseconds(Int64(seconds * 1000)), retryPolicy.maxDelay)
        }
        let exponential = retryPolicy.baseDelay * (1 << min(attempt, 16))
        let jitter = exponential * Double.random(in: 0...0.25)
        return min(exponential + jitter, retryPolicy.maxDelay)
    }

    // MARK: Response

    static func httpError(status: Int, data: Data) -> IntelligenceError {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? [String: Any]
        {
            let message = (error["message"] as? String) ?? HTTPURLResponse.localizedString(forStatusCode: status)
            return .http(status: status, type: error["type"] as? String, message: message)
        }
        let text = String(decoding: data.prefix(500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return .http(status: status, type: nil, message: text.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : text)
    }

    /// Finds the named `tool_use` block. Throws when the response is refused, truncated or not JSON;
    /// returns nil when the model answered without calling the tool.
    static func toolInput(named name: String, in data: Data) throws -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IntelligenceError.malformedResponse("the body is not a JSON object")
        }
        let blocks = object["content"] as? [[String: Any]] ?? []
        switch object["stop_reason"] as? String {
        case "refusal":
            let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
            throw IntelligenceError.refused(text.isEmpty ? nil : text)
        case "max_tokens":
            throw IntelligenceError.truncatedResponse
        default:
            break
        }
        guard let block = blocks.first(where: { $0["type"] as? String == "tool_use" && $0["name"] as? String == name }) else {
            return nil
        }
        guard let input = block["input"], JSONSerialization.isValidJSONObject(input) else {
            throw IntelligenceError.malformedResponse("the \(name) tool input is not a JSON object")
        }
        return try JSONSerialization.data(withJSONObject: input)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw IntelligenceError.malformedResponse(String(describing: error))
        }
    }

    // MARK: Tool schemas (strict: every object closed, every property required, absent values are null)

    static func tool(for task: Task) -> [String: Any] {
        switch task {
        case .insight:
            [
                "name": task.toolName,
                "description": "Record the analysis of the new utterance.",
                "input_schema": insightSchema(),
            ]
        case .report:
            [
                "name": task.toolName,
                "description": "Record the post-meeting report.",
                "input_schema": reportSchema(),
            ]
        }
    }

    static func insightSchema() -> [String: Any] {
        object([
            ("intent", ["type": "string", "enum": UtteranceIntent.allCases.map(\.rawValue), "description": "Intent of the new utterance."]),
            ("correctedText", nullableString("What the speaker meant, only when the utterance has a slip, misstatement or recognition error; otherwise null.")),
            ("correctionReason", nullableString("One short sentence explaining the correction; null when there is none.")),
            ("suggestion", nullableString("One short line starting with Propose:, Confirm:, Ask: or Clarify:, only when genuinely useful; otherwise null.")),
            ("actionItem", ["anyOf": [actionItemSchema(withTimestamp: false), ["type": "null"]], "description": "A concrete task someone committed to or was asked to do; otherwise null."]),
        ])
    }

    static func reportSchema() -> [String: Any] {
        object([
            ("title", string("Short meeting title.")),
            ("overview", string("Two to four sentences.")),
            ("topics", array(of: object([
                ("title", string("Topic title.")),
                ("summary", string("Short summary.")),
                ("speakers", stringArray("Speakers involved.")),
            ]), "Main topics in order.")),
            ("decisions", stringArray("Final decisions as agreed.")),
            ("actionItems", array(of: actionItemSchema(withTimestamp: true), "Concrete tasks.")),
            ("notesToRemember", stringArray("Facts, numbers, dates, constraints and caveats.")),
            ("missedOpportunities", stringArray("What could have been said, asked or followed up.")),
            ("openQuestions", stringArray("Questions raised but not resolved.")),
            ("corrections", array(of: object([
                ("speaker", string("Who misspoke.")),
                ("original", string("Original wording.")),
                ("corrected", string("Corrected meaning.")),
                ("reason", string("Why it was corrected.")),
            ]), "Slips, self-corrections and misstatements.")),
            ("participantSummaries", array(of: object([
                ("name", string("Participant name.")),
                ("keyPoints", stringArray("Their key points.")),
            ]), "Key points per participant who spoke.")),
        ])
    }

    private static func actionItemSchema(withTimestamp: Bool) -> [String: Any] {
        var properties: [(String, [String: Any])] = [
            ("task", string("Short imperative task.")),
            ("owner", nullableString("Name of the responsible person, or null.")),
            ("due", nullableString("Deadline words someone said (e.g. \"Friday\"), or null. Never a transcript timestamp.")),
        ]
        if withTimestamp {
            properties.append(("timestamp", nullableString("mm:ss of the transcript line where it was agreed, or null.")))
        }
        return object(properties)
    }

    private static func object(_ properties: [(String, [String: Any])]) -> [String: Any] {
        [
            "type": "object",
            "properties": Dictionary(uniqueKeysWithValues: properties),
            "required": properties.map(\.0),
            "additionalProperties": false,
        ]
    }

    private static func string(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func nullableString(_ description: String) -> [String: Any] {
        ["anyOf": [["type": "string"], ["type": "null"]], "description": description]
    }

    private static func stringArray(_ description: String) -> [String: Any] {
        ["type": "array", "items": ["type": "string"], "description": description]
    }

    private static func array(of items: [String: Any], _ description: String) -> [String: Any] {
        ["type": "array", "items": items, "description": description]
    }
}
