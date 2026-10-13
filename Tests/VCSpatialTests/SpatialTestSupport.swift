import AVFAudio
import Foundation
import VCSpatial

enum SpatialFixtures {
    static let sampleRate = 16_000.0

    /// One second of real speech from the enrollment fixture (16 kHz mono), or seeded speech-like
    /// pink noise when fixtures have not been generated.
    static let speech: (samples: [Float], isRecorded: Bool) = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent(".fixtures/enroll_Daniel.wav")
        if let samples = try? loadMono(url: url), samples.count >= Int(sampleRate * 2.5) {
            return (Array(samples[Int(sampleRate * 1.0)..<Int(sampleRate * 2.0)]), true)
        }
        return (SignalGenerator.speechLike(count: Int(sampleRate), sampleRate: sampleRate, seed: 7), false)
    }()

    private static func loadMono(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == sampleRate,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { return [] }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }

    static func whiteNoise(count: Int, seed: UInt64) -> [Float] {
        var random = SeededGenerator(seed: seed)
        return (0..<count).map { _ in Float(0.1 * random.nextGaussian()) }
    }

    /// Smallest absolute difference between two azimuths in degrees.
    static func angularError(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }
}
