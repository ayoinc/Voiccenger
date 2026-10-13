import Foundation

public struct DirectionEstimate: Codable, Sendable, Hashable {
    /// Degrees in [0, 360). 0 = array +x axis ("front"), increasing counter-clockwise seen from above.
    public var azimuthDegrees: Double
    /// Peak sharpness of the steered response in 0...1. Low values mean diffuse sound or multiple talkers.
    public var confidence: Double
    /// Session time at the centre of the analysed frame.
    public var time: TimeInterval

    public init(azimuthDegrees: Double, confidence: Double, time: TimeInterval) {
        self.azimuthDegrees = azimuthDegrees
        self.confidence = confidence
        self.time = time
    }
}

/// Planar microphone positions in metres, relative to the array centre.
public struct MicArrayGeometry: Codable, Sendable, Hashable, Identifiable {
    public struct Point: Codable, Sendable, Hashable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public var id: String { name }
    public var name: String
    public var mics: [Point]
    /// Device input channel index for each entry in `mics` (arrays often expose extra processed channels).
    public var channelMap: [Int]

    public init(name: String, mics: [Point], channelMap: [Int]) {
        self.name = name
        self.mics = mics
        self.channelMap = channelMap
    }

    /// Mics evenly spaced on a circle of `radius` metres, first mic on +x.
    public static func circular(name: String, count: Int, radius: Double, channelMap: [Int]? = nil) -> Self {
        let mics = (0..<count).map { i in
            let a = 2 * Double.pi * Double(i) / Double(count)
            return Point(x: radius * cos(a), y: radius * sin(a))
        }
        return Self(name: name, mics: mics, channelMap: channelMap ?? Array(0..<count))
    }

    /// Largest distance between any two mics (sets the max TDOA and the spatial-aliasing limit).
    public var aperture: Double {
        var best = 0.0
        for i in mics.indices {
            for j in mics.indices where j > i {
                best = max(best, hypot(mics[i].x - mics[j].x, mics[i].y - mics[j].y))
            }
        }
        return best
    }
}
