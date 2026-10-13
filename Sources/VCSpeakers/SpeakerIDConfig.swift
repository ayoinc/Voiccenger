import Foundation

/// Tuning for `SpeakerIdentifier`.
public struct SpeakerIDConfig: Sendable {
    /// Minimum cosine similarity (max over a profile's embeddings) to accept an enrolled match.
    public var matchThreshold: Double = 0.65
    /// When `best − runnerUp < ambiguityMargin` the match is flagged `isAmbiguous` (similar voices).
    public var ambiguityMargin: Double = 0.05
    /// FluidAudio clustering threshold (0.5–0.9). Lower creates more clusters. 0.7 is FluidAudio's
    /// best streaming setting on real meetings (AMI, 10 s chunks); it can merge distinct but similar
    /// unenrolled voices into one cluster. Enrolled attribution does not depend on it, because
    /// segments are matched to profiles by embedding.
    public var clusteringThreshold: Float = 0.7
    /// Audio buffered per diarization pass. FluidAudio's segmentation model sees 10 s at a time.
    public var windowSeconds: Double = 10
    /// Seed FluidAudio's `SpeakerManager` with enrolled profiles as permanent speakers so the
    /// diarizer's own cluster ids start anchored to enrolled voices.
    public var seedDiarizerWithProfiles: Bool = false

    public init() {}
}
