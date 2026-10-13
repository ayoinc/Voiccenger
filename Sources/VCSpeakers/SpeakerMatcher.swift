import Accelerate
import Foundation
import VCModels

/// Pure scoring of speaker embeddings against enrolled profiles.
///
/// A profile's score is the **maximum** cosine over all of its embeddings: each enrollment
/// sub-window captures a slightly different phonetic context, so the closest one is the best
/// evidence that a segment came from that person.
public enum SpeakerMatcher {
    /// Cosine similarity in [-1, 1]; 0 for empty, mismatched or zero-norm vectors.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let dot = vDSP.dot(a, b)
        let norms = vDSP.sumOfSquares(a) * vDSP.sumOfSquares(b)
        guard norms > 0, norms.isFinite, dot.isFinite else { return 0 }
        return Double(dot / norms.squareRoot())
    }

    public struct Match: Sendable, Hashable {
        public let profileID: UUID
        public let similarity: Double
        public let isAmbiguous: Bool

        public init(profileID: UUID, similarity: Double, isAmbiguous: Bool) {
            self.profileID = profileID
            self.similarity = similarity
            self.isAmbiguous = isAmbiguous
        }
    }

    /// Best enrolled profile for `embedding`, or nil when no profile reaches `threshold`.
    /// `isAmbiguous` is set when the runner-up profile scores within `margin` of the best.
    public static func bestMatch(
        for embedding: [Float], in profiles: [SpeakerProfile], threshold: Double, margin: Double
    ) -> Match? {
        match(ranked: scores(for: embedding, in: profiles), threshold: threshold, margin: margin)
    }

    /// `bestMatch` over precomputed `scores(for:in:)` output.
    static func match(ranked: [(profileID: UUID, similarity: Double)], threshold: Double, margin: Double) -> Match? {
        guard let best = ranked.first, best.similarity >= threshold else { return nil }
        let runnerUp = ranked.count > 1 ? ranked[1].similarity : -1
        return Match(profileID: best.profileID, similarity: best.similarity, isAmbiguous: best.similarity - runnerUp < margin)
    }

    /// Per-profile scores (max cosine over each profile's embeddings), best first.
    /// Profiles without a comparable embedding are omitted.
    public static func scores(for embedding: [Float], in profiles: [SpeakerProfile]) -> [(profileID: UUID, similarity: Double)] {
        var result: [(profileID: UUID, similarity: Double)] = []
        result.reserveCapacity(profiles.count)
        for profile in profiles {
            var best: Double?
            for candidate in profile.embeddings where candidate.count == embedding.count {
                let s = cosine(embedding, candidate)
                if best.map({ s > $0 }) ?? true { best = s }
            }
            if let best { result.append((profile.id, best)) }
        }
        result.sort { $0.similarity > $1.similarity }
        return result
    }

    /// Returns `v / ‖v‖`, or nil when the vector is empty, zero or non-finite.
    public static func normalized(_ v: [Float]) -> [Float]? {
        guard !v.isEmpty else { return nil }
        let norm = vDSP.sumOfSquares(v).squareRoot()
        guard norm > 1e-6, norm.isFinite else { return nil }
        return vDSP.divide(v, norm)
    }
}
