import Accelerate
import CoreML
import FluidAudio
import Foundation

public enum SpeakerEnrollmentError: Error, LocalizedError, Equatable {
    /// The clip contained less voiced audio than enrollment needs.
    case insufficientSpeech(seconds: Double, required: Double)
    /// Every window produced an invalid (zero / non-finite) embedding.
    case noUsableEmbedding
    /// The loaded models do not expose the expected segmentation output shape.
    case unexpectedModelShape

    public var errorDescription: String? {
        switch self {
        case .insufficientSpeech(let seconds, let required):
            String(
                format: "Only %.1f s of speech was detected; at least %.0f s is needed to enroll a voice. Record a longer sample in a quiet room.",
                seconds, required)
        case .noUsableEmbedding:
            "No usable voice print could be extracted from the recording. Try again closer to the microphone."
        case .unexpectedModelShape:
            "The speaker model has an unexpected format. Delete the cached FluidAudio models and retry."
        }
    }
}

public enum SpeakerEnrollment {
    public static let minimumSpeechSeconds: Double = 5
    public static let windowSeconds: Double = 5
    static let sampleRate: Double = 16_000

    /// L2-normalized embeddings from one clip (multiple from ~5 s sub-windows for robustness). Requires ≥ 5 s of speech.
    ///
    /// Silence is stripped first (energy VAD), the remaining speech is cut into 5 s windows with
    /// 50 % overlap (plus one window flush with the end so the tail is used), windows more than
    /// 20 dB quieter than the median window are dropped, and each window yields one WeSpeaker
    /// embedding. Several embeddings per person let the matcher take the closest phonetic context.
    public static func embeddings(samples16k: [Float]) async throws -> [[Float]] {
        let speech = SpeechActivity.compactSpeech(samples16k, sampleRate: sampleRate)
        let speechSeconds = Double(speech.count) / sampleRate
        guard speechSeconds >= minimumSpeechSeconds else {
            throw SpeakerEnrollmentError.insufficientSpeech(seconds: speechSeconds, required: minimumSpeechSeconds)
        }
        let windows = energeticWindows(in: speech)
        let raw = try await EmbeddingEngine.shared.embeddings(of: speech, windows: windows)
        let normalized = raw.compactMap(SpeakerMatcher.normalized)
        guard !normalized.isEmpty else { throw SpeakerEnrollmentError.noUsableEmbedding }
        return normalized
    }

    /// 5 s windows, 50 % hop, final window aligned to the end; low-energy windows removed.
    static func windows(count: Int) -> [Range<Int>] {
        let length = Int(windowSeconds * sampleRate)
        guard count > length else { return [0..<count] }
        let hop = length / 2
        var result: [Range<Int>] = []
        var start = 0
        while start + length <= count {
            result.append(start..<(start + length))
            start += hop
        }
        if let last = result.last, count - last.upperBound > hop / 2 {
            result.append((count - length)..<count)
        }
        return result
    }

    static func energeticWindows(in speech: [Float]) -> [Range<Int>] {
        let all = windows(count: speech.count)
        let rms = all.map { range in
            speech.withUnsafeBufferPointer { vDSP.rootMeanSquare(UnsafeBufferPointer(rebasing: $0[range])) }
        }
        let median = rms.sorted()[rms.count / 2]
        let kept = zip(all, rms).filter { $0.1 >= median * 0.1 }.map(\.0)
        return kept.isEmpty ? all : kept
    }
}

/// Owns the (non-Sendable) WeSpeaker extractor; CoreML inference runs on its own serial queue
/// rather than blocking the cooperative pool.
actor EmbeddingEngine {
    static let shared = EmbeddingEngine()

    private let queue = DispatchSerialQueue(label: "VCSpeakers.EmbeddingEngine", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private var extractor: EmbeddingExtractor?
    private var maskFrames = 0

    /// One raw embedding per window; every frame of each window is treated as target speech.
    func embeddings(of samples: [Float], windows: [Range<Int>]) async throws -> [[Float]] {
        let models = try await SpeakerModels.loaded()
        if extractor == nil {
            guard
                let shape = models.segmentationModel.modelDescription.outputDescriptionsByName["segments"]?
                    .multiArrayConstraint?.shape,
                shape.count >= 2
            else { throw SpeakerEnrollmentError.unexpectedModelShape }
            maskFrames = shape[1].intValue
            extractor = EmbeddingExtractor(embeddingModel: models.embeddingModel)
        }
        guard let extractor else { throw SpeakerEnrollmentError.unexpectedModelShape }
        let mask = [Float](repeating: 1, count: maskFrames)
        var result: [[Float]] = []
        for window in windows {
            let embedding = try extractor.getEmbeddings(audio: samples[window], masks: [mask]).first
            if let embedding { result.append(embedding) }
        }
        return result
    }
}
