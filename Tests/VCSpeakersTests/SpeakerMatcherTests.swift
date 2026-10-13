import Foundation
import Testing
import VCModels
@testable import VCSpeakers

@Suite("SpeakerMatcher")
struct SpeakerMatcherTests {
    /// Unit vector in `dimension` dims pointing mostly along axis `axis`, rotated toward `toward` by `angle` radians.
    static func vector(axis: Int, toward: Int? = nil, angle: Double = 0, dimension: Int = 8) -> [Float] {
        var v = [Float](repeating: 0, count: dimension)
        v[axis] = Float(cos(angle))
        if let toward { v[toward] = Float(sin(angle)) }
        return v
    }

    @Test func cosineIsScaleInvariantAndSafeOnDegenerateInput() {
        let a: [Float] = [1, 2, 3]
        #expect(abs(SpeakerMatcher.cosine(a, a.map { $0 * 7 }) - 1) < 1e-6)
        #expect(abs(SpeakerMatcher.cosine(a, a.map { -$0 }) + 1) < 1e-6)
        #expect(SpeakerMatcher.cosine(a, [0, 0, 0]) == 0)
        #expect(SpeakerMatcher.cosine(a, [1, 2]) == 0)
        #expect(SpeakerMatcher.cosine([], []) == 0)
    }

    @Test func belowThresholdReturnsNil() {
        let profile = SpeakerProfile(name: "A", embeddings: [Self.vector(axis: 0)])
        // cos(60°) = 0.5
        let probe = Self.vector(axis: 0, toward: 1, angle: .pi / 3)
        #expect(SpeakerMatcher.bestMatch(for: probe, in: [profile], threshold: 0.65, margin: 0.05) == nil)
        let accepted = SpeakerMatcher.bestMatch(for: probe, in: [profile], threshold: 0.49, margin: 0.05)
        #expect(accepted?.profileID == profile.id)
        #expect(abs((accepted?.similarity ?? 0) - 0.5) < 1e-5)
    }

    @Test func thresholdIsInclusive() {
        let profile = SpeakerProfile(name: "A", embeddings: [[1, 0]])
        let probe: [Float] = [0.6, 0.8]  // cosine exactly 0.6
        #expect(SpeakerMatcher.bestMatch(for: probe, in: [profile], threshold: 0.6 - 1e-6, margin: 0)?.profileID == profile.id)
    }

    @Test func closeRunnerUpIsAmbiguousAndClearWinnerIsNot() {
        let a = SpeakerProfile(name: "A", embeddings: [Self.vector(axis: 0)])
        let b = SpeakerProfile(name: "B", embeddings: [Self.vector(axis: 1)])
        // Nearly halfway between A and B, slightly closer to A.
        let nearMiddle = Self.vector(axis: 0, toward: 1, angle: .pi / 4 - 0.02)
        let ambiguous = SpeakerMatcher.bestMatch(for: nearMiddle, in: [a, b], threshold: 0.5, margin: 0.05)
        #expect(ambiguous?.profileID == a.id)
        #expect(ambiguous?.isAmbiguous == true)

        let clearlyA = Self.vector(axis: 0, toward: 1, angle: 0.2)
        let clear = SpeakerMatcher.bestMatch(for: clearlyA, in: [a, b], threshold: 0.5, margin: 0.05)
        #expect(clear?.profileID == a.id)
        #expect(clear?.isAmbiguous == false)

        // A single enrolled profile can never be ambiguous.
        #expect(SpeakerMatcher.bestMatch(for: nearMiddle, in: [a], threshold: 0.5, margin: 0.05)?.isAmbiguous == false)
    }

    @Test func profileScoreIsMaxOverItsEmbeddings() {
        // B has one embedding exactly matching the probe among several far ones; A's single
        // embedding is moderately close. Max (not mean) must pick B.
        let probe = Self.vector(axis: 2)
        let a = SpeakerProfile(name: "A", embeddings: [Self.vector(axis: 2, toward: 0, angle: 0.5)])
        let b = SpeakerProfile(
            name: "B",
            embeddings: [Self.vector(axis: 3), Self.vector(axis: 4), probe, Self.vector(axis: 5)])
        let match = SpeakerMatcher.bestMatch(for: probe, in: [a, b], threshold: 0.65, margin: 0.05)
        #expect(match?.profileID == b.id)
        #expect(abs((match?.similarity ?? 0) - 1) < 1e-5)
        #expect(match?.isAmbiguous == false)
    }

    @Test func mismatchedDimensionsAndEmptyProfilesAreIgnored() {
        let wrongSize = SpeakerProfile(name: "Old model", embeddings: [[1, 0, 0]])
        let empty = SpeakerProfile(name: "Empty", embeddings: [])
        let right = SpeakerProfile(name: "Right", embeddings: [Self.vector(axis: 0, toward: 1, angle: 0.3)])
        let probe = Self.vector(axis: 0)
        let match = SpeakerMatcher.bestMatch(for: probe, in: [wrongSize, empty, right], threshold: 0.65, margin: 0.05)
        #expect(match?.profileID == right.id)
        #expect(match?.isAmbiguous == false)
        #expect(SpeakerMatcher.bestMatch(for: probe, in: [wrongSize, empty], threshold: 0, margin: 0) == nil)
        #expect(SpeakerMatcher.bestMatch(for: probe, in: [], threshold: 0, margin: 0) == nil)
    }

    @Test func normalizedRejectsZeroAndProducesUnitLength() {
        #expect(SpeakerMatcher.normalized([0, 0, 0]) == nil)
        #expect(SpeakerMatcher.normalized([]) == nil)
        #expect(SpeakerMatcher.normalized([.nan, 1]) == nil)
        let n = SpeakerMatcher.normalized([3, 4])
        #expect(n == [0.6, 0.8])
    }
}
