import Accelerate
import Foundation
import VCModels

/// Frame-energy voice activity detector with an adaptive noise floor. Pure value type.
///
/// Each 30 ms frame's energy (dBFS) is compared with a noise-floor estimate that drops quickly to quieter
/// frames and creeps up slowly (`floorRiseTime`) during louder ones, so stationary noise — fans, hum,
/// steady hiss — is absorbed into the floor while speech, which keeps returning to the floor between
/// syllables and phrases, stays above it. A frame is speech when it is `thresholdDB` above the floor and
/// above `absoluteThresholdDB`; a short hangover bridges the gaps inside words.
public struct VoiceActivityDetector: Sendable {
    public var frameDuration: TimeInterval = 0.03
    public var thresholdDB: Double = 9
    public var absoluteThresholdDB: Double = -55
    public var floorRiseTime: TimeInterval = 8
    public var hangover: TimeInterval = 0.3

    /// Current noise-floor estimate in dBFS (nil before the first frame).
    public private(set) var noiseFloorDB: Double?
    private var hangoverLeft: TimeInterval = 0
    private var carry: [Float] = []
    private var sampleRate: Double = 0

    public init() {}

    /// Classifies every complete frame in `samples` (partial frames carry over to the next call).
    public mutating func process(_ samples: [Float], sampleRate: Double) -> [Bool] {
        guard sampleRate > 0 else { return [] }
        if sampleRate != self.sampleRate {
            self.sampleRate = sampleRate
            carry.removeAll()
        }
        let frameLength = max(1, Int((frameDuration * sampleRate).rounded()))
        carry.append(contentsOf: samples)
        var decisions: [Bool] = []
        decisions.reserveCapacity(carry.count / frameLength)
        var offset = 0
        carry.withUnsafeBufferPointer { buffer in
            while offset + frameLength <= buffer.count {
                var meanSquare: Float = 0
                vDSP_measqv(buffer.baseAddress! + offset, 1, &meanSquare, vDSP_Length(frameLength))
                decisions.append(classify(energyDB: 10 * log10(max(Double(meanSquare), 1e-10))))
                offset += frameLength
            }
        }
        carry.removeFirst(offset)
        return decisions
    }

    /// Classifies one frame given its energy in dBFS.
    public mutating func classify(energyDB: Double) -> Bool {
        let floor = noiseFloorDB ?? energyDB
        let updated: Double
        if energyDB < floor {
            updated = floor + (energyDB - floor) * 0.5
        } else {
            updated = floor + (energyDB - floor) * min(1, frameDuration / floorRiseTime)
        }
        noiseFloorDB = updated
        let active = energyDB >= absoluteThresholdDB && energyDB - updated >= thresholdDB
        if active {
            hangoverLeft = hangover
            return true
        }
        if hangoverLeft > 0 {
            hangoverLeft -= frameDuration
            return true
        }
        return false
    }
}

/// Energy VAD with adaptive noise floor on microphone chunks; emits .conversationDetected after ~30 s of ≥50% speech activity within a 60 s window. Not used while recording.
///
/// Fires once speech within the trailing `window` adds up to `requiredSpeechSeconds`, then starts counting
/// afresh (the noise floor is kept), so a long conversation is reported again only after another full
/// quota of speech.
public final class ConversationDetector: Sendable {
    public let requiredSpeechSeconds: TimeInterval
    public let window: TimeInterval
    private let state = Mutex(State())

    private struct State {
        var vad = VoiceActivityDetector()
        /// Start times of recent speech frames, oldest first.
        var speechFrames: [TimeInterval] = []
        var head = 0
        /// Session time just past the last processed frame.
        var cursor: TimeInterval?
    }

    public init(requiredSpeechSeconds: TimeInterval = 30, window: TimeInterval = 60) {
        self.requiredSpeechSeconds = requiredSpeechSeconds
        self.window = max(window, requiredSpeechSeconds)
    }

    /// Feeds one chunk; returns `.conversationDetected` when the speech quota is reached.
    public func ingest(_ chunk: AudioChunk) -> MeetingDetectionEvent? {
        state.withLock { s -> MeetingDetectionEvent? in
            let frameDuration = s.vad.frameDuration
            // Frames are timed from the chunk stream; a gap or rewind in the input re-anchors the cursor.
            if s.cursor == nil || abs(chunk.startTime - s.cursor!) > 1 { s.cursor = chunk.startTime }
            for isSpeech in s.vad.process(chunk.samples, sampleRate: chunk.sampleRate) {
                let t = s.cursor!
                s.cursor = t + frameDuration
                if isSpeech { s.speechFrames.append(t) }
            }
            guard let now = s.cursor else { return nil }
            while s.head < s.speechFrames.count, s.speechFrames[s.head] < now - window { s.head += 1 }
            if s.head > 4_096 {
                s.speechFrames.removeFirst(s.head)
                s.head = 0
            }
            let speech = Double(s.speechFrames.count - s.head) * frameDuration
            guard speech >= requiredSpeechSeconds else { return nil }
            s.speechFrames.removeAll(keepingCapacity: true)
            s.head = 0
            return .conversationDetected(at: Date())
        }
    }

    /// Forgets all history, including the noise floor.
    public func reset() {
        state.withLock { $0 = State() }
    }
}
