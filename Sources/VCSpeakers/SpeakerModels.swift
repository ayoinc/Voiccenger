import FluidAudio
import Foundation

/// FluidAudio pyannote segmentation + WeSpeaker embedding models, downloaded from Hugging Face
/// on first use and compiled once per process. Every `SpeakerIdentifier` and enrollment shares them.
public enum SpeakerModels {
    /// Downloads (if needed) and loads the diarizer models. Safe to call repeatedly and concurrently.
    public static func prepare() async throws {
        _ = try await DiarizerModelCache.shared.models()
    }

    static func loaded() async throws -> DiarizerModels {
        try await DiarizerModelCache.shared.models()
    }
}

/// Single-flight cache: concurrent callers await the same load; a failed load is retried next call.
actor DiarizerModelCache {
    static let shared = DiarizerModelCache()

    private var loading: Task<DiarizerModels, any Error>?

    func models() async throws -> DiarizerModels {
        let task: Task<DiarizerModels, any Error>
        if let loading {
            task = loading
        } else {
            task = Task { try await DiarizerModels.downloadIfNeeded() }
            loading = task
        }
        do {
            return try await task.value
        } catch {
            loading = nil
            throw error
        }
    }
}
