import Foundation
import VCModels

public enum IntelligenceEngineKind: String, Codable, Sendable, CaseIterable {
    case apple
    case claude
    /// No language model: an outline extracted from the transcript. Runs on every Mac.
    case transcriptOutline
}

public enum IntelligenceFactory {
    /// Keychain account holding the Anthropic API key.
    public static let anthropicKeyAccount = "anthropic-api-key"

    /// The requested engine, or nil when it cannot run (Apple Intelligence unavailable, no Anthropic key).
    public static func make(kind: IntelligenceEngineKind) -> (any MeetingIntelligence)? {
        switch kind {
        case .apple:
            if #available(macOS 26.0, *), AppleIntelligenceStatus.current.isAvailable { AppleIntelligenceEngine() } else { nil }
        case .claude:
            anthropicAPIKey().map { ClaudeEngine(apiKey: $0) }
        case .transcriptOutline:
            TranscriptOutlineEngine()
        }
    }

    /// Keychain first, then the `ANTHROPIC_API_KEY` environment variable.
    public static func anthropicAPIKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        for candidate in [KeychainStore.get(account: anthropicKeyAccount), environment["ANTHROPIC_API_KEY"]] {
            if let key = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty { return key }
        }
        return nil
    }
}
