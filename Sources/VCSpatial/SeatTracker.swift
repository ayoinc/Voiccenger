import Foundation
import VCModels

/// Turns noisy per-utterance direction estimates into a stable seat azimuth per speaker.
///
/// Each speaker's seat is the confidence-weighted circular mean of their estimates (unit vectors
/// summed, so 350° and 10° average to 0°, not 180°). Estimates below `minimumConfidence` are ignored
/// because they come from diffuse sound or overlapping talkers.
public struct SeatTracker: Sendable {
    /// Estimates with lower confidence than this are discarded.
    public static let minimumConfidence = 0.2

    private struct Resultant: Sendable {
        var x = 0.0
        var y = 0.0
    }

    private var resultants: [String: Resultant] = [:]

    public init() {}

    public mutating func add(_ e: DirectionEstimate, speakerKey: String) {
        guard e.confidence >= SeatTracker.minimumConfidence, e.azimuthDegrees.isFinite else { return }
        let radians = e.azimuthDegrees * .pi / 180
        var resultant = resultants[speakerKey, default: Resultant()]
        resultant.x += e.confidence * cos(radians)
        resultant.y += e.confidence * sin(radians)
        resultants[speakerKey] = resultant
    }

    /// Seat azimuth in [0, 360), or nil if the speaker has no confident estimates or their
    /// estimates cancel out (no dominant direction).
    public func seat(for speakerKey: String) -> Double? {
        guard let resultant = resultants[speakerKey] else { return nil }
        return SeatTracker.azimuth(of: resultant)
    }

    public var seats: [String: Double] {
        resultants.compactMapValues(SeatTracker.azimuth(of:))
    }

    private static func azimuth(of resultant: Resultant) -> Double? {
        guard hypot(resultant.x, resultant.y) > 1e-9 else { return nil }
        return DirectionEstimator.normalizedDegrees(atan2(resultant.y, resultant.x) * 180 / .pi)
    }
}
