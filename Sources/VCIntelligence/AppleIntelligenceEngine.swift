import Foundation
import FoundationModels
import VCModels

/// On-device engine on Apple's system language model (guided generation).
///
/// Every request uses a fresh `LanguageModelSession`, so calls are independent and can run concurrently.
/// The model's context window is small (4,096 tokens on macOS 26), so reports over long transcripts are
/// built map-reduce by `ReportComposer`: notes per transcript chunk, then merges of those notes until one set
/// remains. A request the safety filter declines is retried with permissive guardrails, then narrowed down to
/// the lines it declines, which are handled without AI.
@available(macOS 26.0, *)
public final class AppleIntelligenceEngine: MeetingIntelligence {
    /// Upper bound for transcript tokens in one notes request (summary or lists).
    static let maximumTranscriptBudget = 2_000
    /// Tokens kept free for the answer of a summary request (detailed overview, topics, participants).
    static let summaryResponseReserve = 1_300
    /// Tokens kept free for the answer of a lists request.
    static let listsResponseReserve = 1_100
    /// Tokens kept free for the answer of a merge request (title, up to eight topics, a multi-paragraph overview).
    static let mergeResponseReserve = 1_400
    /// Upper bound for transcript tokens in one outline request: its answer restates every chunk in detail.
    static let maximumOutlineBudget = 1_500
    /// Tokens kept free for the answer of an outline request (four segments of six points).
    static let outlineResponseReserve = 1_500
    /// Upper bound for recent-context tokens in one live-analysis request.
    static let maximumContextBudget = 1_200
    /// Below this, a report request cannot carry enough transcript to be worth sending.
    static let minimumTranscriptBudget = 250

    private let transcriptBudgetOverride: Int?

    public var engineName: String { "Apple Intelligence (on-device)" }

    public init() {
        transcriptBudgetOverride = nil
    }

    /// `transcriptTokenBudget` forces the per-request transcript size (exercises map-reduce on short transcripts).
    init(transcriptTokenBudget: Int) {
        precondition(transcriptTokenBudget >= Self.minimumTranscriptBudget, "budget below minimum")
        transcriptBudgetOverride = transcriptTokenBudget
    }

    public static var isAvailable: Bool { AppleIntelligenceStatus.current.isAvailable }

    public static var unavailableReason: String? { AppleIntelligenceStatus.current.reason }

    private static var generationOptions: GenerationOptions {
        // The macOS 27 SDK (Swift 6.4) renamed `sampling:` to `samplingMode:`.
        #if compiler(>=6.4)
        GenerationOptions(samplingMode: .greedy)
        #else
        GenerationOptions(sampling: .greedy)
        #endif
    }

    // MARK: Live analysis

    public func analyze(utterance: ContextLine, recentContext: [ContextLine]) async throws -> UtteranceInsight {
        try Self.requireAvailable()
        var budget = Self.maximumContextBudget
        while true {
            let context = budget > 0 ? TranscriptChunker.tail(recentContext, tokenBudget: budget) : []
            let prompt = IntelligencePrompts.analysisPrompt(utterance: utterance, recentContext: context)
            do {
                let insight = try await Self.generate(GenInsight.self, instructions: IntelligencePrompts.analysisInstructions, prompt: prompt)
                return ResultAssembler.insight(from: insight.raw, utterance: utterance, context: context)
            } catch let error where Self.isContextOverflow(error) {
                // Less context first; an utterance that does not fit even alone cannot be analysed.
                guard !context.isEmpty else { throw IntelligenceError.contextWindowExceeded }
                budget = budget >= 200 ? budget / 2 : 0
            }
        }
    }

    // MARK: Report

    /// The report, written by `ReportComposer` over the window-derived budgets.
    public func report(transcript: [ContextLine], participants: [String], meetingTitle: String?) async throws -> MeetingReport {
        try Self.requireAvailable()
        let budgets = transcript.isEmpty
            ? ReportBudgets(notes: 0, merge: 0, outline: 0)
            : ReportBudgets(notes: await transcriptBudget(), merge: await mergeBudget(), outline: await outlineBudget())
        return try await ReportComposer(model: AppleReportModel(), minimumBudget: Self.minimumTranscriptBudget).report(
            transcript: transcript, participants: participants, meetingTitle: meetingTitle, budgets: budgets,
            generatedBy: engineName, modelName: "Apple Intelligence")
    }

    /// Whether `lines` fit `budget` transcript tokens: by the estimate, or else (macOS 26.4 and later) by the
    /// model's own count, since the estimate runs about 20% high and the budget itself comes from exact counts.
    static func fits(_ lines: [NumberedLine], budget: Int) async -> Bool {
        if lines.reduce(0, { $0 + TranscriptChunker.defaultCost($1) }) <= budget { return true }
        if #available(macOS 26.4, *), let exact = try? await SystemLanguageModel.default.tokenCount(for: TranscriptFormatter.format(lines)) {
            return exact <= budget
        }
        return false
    }

    // MARK: Budgets

    /// Transcript tokens per notes request: the window-derived budget unless an override forces smaller requests.
    func transcriptBudget() async -> Int {
        if let transcriptBudgetOverride { return transcriptBudgetOverride }
        return await windowBudget()
    }

    /// Transcript tokens a summary request and a lists request can both carry: what the window leaves after each
    /// one's instructions, schema and answer.
    func windowBudget() async -> Int {
        let summary = await Self.overhead(IntelligencePrompts.summaryInstructions, GenSummary.generationSchema, estimatedSchema: 470)
            + Self.summaryResponseReserve
        let lists = await Self.overhead(IntelligencePrompts.listsInstructions, GenLists.generationSchema, estimatedSchema: 740)
            + Self.listsResponseReserve
        let available = SystemLanguageModel.default.contextSize - max(summary, lists)
        return min(Self.maximumTranscriptBudget, max(Self.minimumTranscriptBudget, available))
    }

    /// Rendered part summaries one merge request can carry.
    func mergeBudget() async -> Int {
        let overhead = await Self.overhead(IntelligencePrompts.mergeSummaryInstructions, GenSummary.mergeSchema, estimatedSchema: 350)
        let available = SystemLanguageModel.default.contextSize - overhead - Self.mergeResponseReserve
        return min(Self.maximumTranscriptBudget, max(Self.minimumTranscriptBudget, available))
    }

    /// Transcript tokens per outline request: what the window leaves after the outline instructions, schema and
    /// answer, at most `maximumOutlineBudget` (and at most a forced transcript budget).
    func outlineBudget() async -> Int {
        let overhead = await Self.overhead(IntelligencePrompts.outlineInstructions, GenOutline.generationSchema, estimatedSchema: 350)
        let available = SystemLanguageModel.default.contextSize - overhead - Self.outlineResponseReserve
        let budget = min(Self.maximumOutlineBudget, max(Self.minimumTranscriptBudget, available))
        return transcriptBudgetOverride.map { min($0, budget) } ?? budget
    }

    /// Tokens of a request's instructions and schema plus the prompt header: counted by the model on macOS 26.4 and
    /// later, else estimated (`estimatedSchema` is the schema's count measured on macOS 26.4).
    static func overhead(_ instructions: String, _ schema: GenerationSchema, estimatedSchema: Int) async -> Int {
        if #available(macOS 26.4, *) {
            let model = SystemLanguageModel.default
            if let instructionTokens = try? await model.tokenCount(for: Instructions(instructions)),
                let schemaTokens = try? await model.tokenCount(for: schema)
            {
                return instructionTokens + schemaTokens + 100
            }
        }
        return TokenEstimator.estimate(instructions) + estimatedSchema + 100
    }

    // MARK: Model calls

    private static func requireAvailable() throws {
        if let reason = unavailableReason { throw IntelligenceError.unavailable(reason) }
    }

    /// One request in a fresh session, answered in `schema` (by default `Content`'s own). With `.permissive`
    /// guardrails the request runs on the model's permissive content-transformation mode, which only covers
    /// String answers (guided generation keeps the default guardrails): the same schema is asked for as JSON
    /// text and parsed strictly into the same type.
    static func generate<Content: Generable>(
        _ type: Content.Type, schema: GenerationSchema = Content.generationSchema, instructions: String, prompt: String,
        guardrails: ReportGuardrails = .standard
    ) async throws -> Content {
        do {
            switch guardrails {
            case .standard:
                let session = LanguageModelSession(instructions: instructions)
                let content = try await session.respond(to: prompt, schema: schema, includeSchemaInPrompt: true, options: generationOptions).content
                return try Content(content)
            case .permissive:
                let schemaJSON = String(decoding: try JSONEncoder().encode(schema), as: UTF8.self)
                let session = LanguageModelSession(
                    model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
                    instructions: instructions + "\n" + IntelligencePrompts.jsonAnswerInstructions(schema: schemaJSON))
                let text: String = try await session.respond(to: prompt, options: generationOptions).content
                return try Content(try strictJSON(text, schema: schemaJSON))
            }
        } catch {
            throw mapped(error)
        }
    }

    /// `text` as generated content when it is one complete JSON object (optionally in a Markdown code fence)
    /// holding every property `schema` (JSON Schema text) requires; else `IntelligenceError.malformedResponse`.
    /// `GeneratedContent(json:)` alone would accept a truncated object.
    static func strictJSON(_ text: String, schema: String) throws -> GeneratedContent {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            body = String(body.drop { $0 != "\n" }).trimmingCharacters(in: .whitespacesAndNewlines)
            if body.hasSuffix("```") { body = String(body.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
            throw IntelligenceError.malformedResponse("the answer is not one JSON object")
        }
        let required = (try? JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])?["required"] as? [String] ?? []
        let missing = required.filter { object[$0] == nil }
        guard missing.isEmpty else {
            throw IntelligenceError.malformedResponse("the answer lacks \(missing.joined(separator: ", "))")
        }
        return try GeneratedContent(json: body)
    }

    static func isContextOverflow(_ error: any Error) -> Bool {
        if let error = error as? LanguageModelSession.GenerationError, case .exceededContextWindowSize = error { return true }
        #if compiler(>=6.4)
        // macOS 27 reports errors as `LanguageModelError`; the type only exists in its SDK.
        if #available(macOS 27.0, *), let error = error as? LanguageModelError, case .contextSizeExceeded = error { return true }
        #endif
        return false
    }

    /// Context overflow passes through untouched (callers shrink and retry); refusals, guardrails and
    /// missing assets become `IntelligenceError`; anything else is rethrown as is.
    private static func mapped(_ error: any Error) -> any Error {
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal:
                return IntelligenceError.refused(error.errorDescription)
            case .assetsUnavailable:
                return IntelligenceError.unavailable(unavailableReason ?? "The Apple Intelligence model assets are not available.")
            case .unsupportedLanguageOrLocale:
                return IntelligenceError.unavailable("Apple Intelligence does not support this transcript's language.")
            default:
                return error
            }
        }
        #if compiler(>=6.4)
        if #available(macOS 27.0, *), let error = error as? LanguageModelError {
            switch error {
            case .guardrailViolation, .refusal:
                return IntelligenceError.refused(error.errorDescription)
            case .unsupportedLanguageOrLocale:
                return IntelligenceError.unavailable("Apple Intelligence does not support this transcript's language.")
            default:
                return error
            }
        }
        #endif
        return error
    }
}

/// The on-device model behind `ReportComposer`: one guided-generation request per report request, retried as
/// JSON text with permissive guardrails after a refusal.
@available(macOS 26.0, *)
struct AppleReportModel: ReportModel {
    var hasPermissiveGuardrails: Bool { true }

    func respond(to request: ReportRequest, guardrails: ReportGuardrails) async throws -> RawReport {
        switch request.kind {
        case .summary:
            try await AppleIntelligenceEngine.generate(
                GenSummary.self, schema: GenSummary.schema(paragraphs: request.paragraphs), instructions: IntelligencePrompts.summaryInstructions,
                prompt: request.prompt, guardrails: guardrails
            ).raw
        case .lists:
            try await AppleIntelligenceEngine.generate(
                GenLists.self, instructions: IntelligencePrompts.listsInstructions, prompt: request.prompt, guardrails: guardrails
            ).raw
        case .outline:
            RawReport(outline: try await AppleIntelligenceEngine.generate(
                GenOutline.self, instructions: IntelligencePrompts.outlineInstructions, prompt: request.prompt, guardrails: guardrails
            ).raw)
        case .merge:
            try await AppleIntelligenceEngine.generate(
                GenSummary.self, schema: GenSummary.mergeSchema, instructions: IntelligencePrompts.mergeSummaryInstructions,
                prompt: request.prompt, guardrails: guardrails
            ).raw
        }
    }

    func fits(_ lines: [NumberedLine], budget: Int) async -> Bool {
        await AppleIntelligenceEngine.fits(lines, budget: budget)
    }

    func isContextOverflow(_ error: any Error) -> Bool {
        AppleIntelligenceEngine.isContextOverflow(error)
    }
}
