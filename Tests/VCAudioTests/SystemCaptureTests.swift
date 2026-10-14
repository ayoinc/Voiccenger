import CoreAudio
import Foundation
import Testing
import VCModels

@testable import VCAudio

private let zoom = MeetingAppCatalog.app(forBundleID: "us.zoom.xos")!
private let teams = MeetingAppCatalog.app(forBundleID: "com.microsoft.teams2")!
private let chrome = MeetingAppCatalog.app(forBundleID: "com.google.Chrome")!

private func process(_ object: AudioObjectID, _ pid: Int32, _ bundleID: String, output: Bool = false) -> AudioProcessInfo {
    AudioProcessInfo(objectID: object, pid: pid, bundleID: bundleID, isRunningInput: false, isRunningOutput: output)
}

// MARK: - Fake taps

private final class FakeTap: ProcessTap {
    let objects: [AudioObjectID]?
    let sink: TapSink
    let sampleRate: Double
    private let stopped = Mutex(false)

    init(objects: [AudioObjectID]?, sink: TapSink, sampleRate: Double) {
        self.objects = objects
        self.sink = sink
        self.sampleRate = sampleRate
    }

    var isStopped: Bool { stopped.withLock { $0 } }

    func stop() { stopped.withLock { $0 = true } }

    /// Delivers `samples` as if captured ending at session time `arrival` (ignored once stopped, like the HAL).
    func deliver(_ samples: [Float], arrival: TimeInterval) {
        guard !isStopped else { return }
        samples.withUnsafeBufferPointer { sink.append($0, arrival: arrival) }
    }
}

private final class FakeWatch: ProcessWatch {
    func cancel() {}
}

private final class FakeBackend: ProcessTapBackend {
    struct State {
        var processes: [AudioProcessInfo]
        var taps: [FakeTap] = []
        var onChange: (@Sendable () -> Void)?
    }

    let state: Mutex<State>
    static let sampleRate = 16_000.0

    init(processes: [AudioProcessInfo]) {
        state = Mutex(State(processes: processes))
    }

    var taps: [FakeTap] { state.withLock { $0.taps } }

    func processes() -> [AudioProcessInfo] { state.withLock { $0.processes } }

    func startTap(processObjects: [AudioObjectID]?, clock: SessionClock, sink: TapSink, reserve: TimeInterval) throws
        -> any ProcessTap
    {
        let tap = FakeTap(objects: processObjects, sink: sink, sampleRate: Self.sampleRate)
        state.withLock { $0.taps.append(tap) }
        return tap
    }

    func watchProcesses(_ onChange: @escaping @Sendable () -> Void) -> any ProcessWatch {
        state.withLock { $0.onChange = onChange }
        return FakeWatch()
    }

    /// A new process appeared (Core Audio's process-list notification).
    func add(_ info: AudioProcessInfo) {
        let onChange = state.withLock { s in
            s.processes.append(info)
            return s.onChange
        }
        onChange?()
    }

    /// The running tap that isn't the global probe.
    var familyTap: FakeTap? { taps.last { !$0.isStopped && $0.objects != nil } }
    var probeTap: FakeTap? { taps.last { !$0.isStopped && $0.objects == nil } }
}

/// Collects a stream's chunks in the background.
private final class ChunkCollector: Sendable {
    private let chunks = Mutex<[AudioChunk]>([])
    let task: Task<Void, Never>

    init(_ stream: AsyncStream<AudioChunk>) {
        let chunks = self.chunks
        task = Task { for await chunk in stream { chunks.withLock { $0.append(chunk) } } }
    }

    var all: [AudioChunk] { chunks.withLock { $0 } }
    var duration: TimeInterval { all.reduce(0) { $0 + $1.duration } }
}

private func waitUntil(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out waiting")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

// MARK: - Signals

/// Deterministic speech-like noise: low-passed noise under a ~4 Hz syllable envelope with a 0.3 s pause every
/// 1.5 s, scaled to `rmsDB` dBFS over the whole signal.
func speechLike(seconds: Double, rmsDB: Double, sampleRate: Double = 16_000, seed: UInt64 = 7) -> [Float] {
    var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    var low: Float = 0
    let count = Int(seconds * sampleRate)
    var out = [Float](repeating: 0, count: count)
    for i in 0..<count {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let white = Float(Int64(bitPattern: state >> 11) % 2_000_000) / 1_000_000 - 1
        low += 0.3 * (white - low)
        let t = Double(i) / sampleRate
        let paused = t.truncatingRemainder(dividingBy: 1.5) > 1.2
        let envelope = paused ? 0 : Float(0.3 + 0.7 * pow(sin(.pi * 4 * t), 2))
        out[i] = low * envelope
    }
    let rms = sqrt(out.reduce(0) { $0 + $1 * $1 } / Float(count))
    let scale = Float(pow(10, rmsDB / 20)) / max(rms, 1e-9)
    return out.map { $0 * scale }
}

/// RMS (dBFS) over the 30 ms frames a voice-activity detector calls speech.
func speechRMS(_ samples: [Float], sampleRate: Double = 16_000) -> Double {
    var vad = VoiceActivityDetector()
    let flags = vad.process(samples, sampleRate: sampleRate)
    let frame = Int((vad.frameDuration * sampleRate).rounded())
    var sum = 0.0, count = 0
    for (i, speech) in flags.enumerated() where speech {
        for s in samples[(i * frame)..<((i + 1) * frame)] { sum += Double(s * s) }
        count += frame
    }
    return 10 * log10(max(sum / Double(max(count, 1)), 1e-12))
}

private func level(_ samples: ArraySlice<Float>) -> Double {
    10 * log10(max(samples.reduce(0) { $0 + Double($1 * $1) } / Double(max(samples.count, 1)), 1e-12))
}

// MARK: - Tests

@Suite("System audio capture")
struct SystemCaptureTests {
    @Test("A meeting app's family is every process its bundle IDs map to, not just the microphone users")
    func familyResolution() {
        let processes = [
            process(1, 101, "com.microsoft.teams2"),
            process(2, 102, "com.microsoft.teams2.helper.renderer", output: true),
            process(3, 103, "com.microsoft.teams"),
            process(4, 104, "com.google.Chrome.helper"),
            process(5, 105, ""),
            process(6, 106, "com.microsoft.teams2x"),
            process(7, 99, "com.microsoft.teams2.modulehost"),
        ]
        #expect(AudioProcesses.family(of: teams, in: processes).map(\.pid) == [99, 101, 102, 103])
        let faceTime = MeetingAppCatalog.app(forBundleID: "com.apple.FaceTime")!
        let daemons = [process(8, 200, "com.apple.FaceTime"), process(9, 201, "com.apple.avconferenced")]
        #expect(AudioProcesses.family(of: faceTime, in: daemons).map(\.pid) == [200, 201])
        #expect(AudioProcesses.family(of: zoom, in: processes).isEmpty)
    }

    @Test("Native apps get their family tap; browsers and no app get the global tap")
    func targets() {
        #expect(SystemAudioTarget(meetingApp: zoom) == .app(zoom))
        #expect(SystemAudioTarget(meetingApp: chrome) == .global)
        #expect(SystemAudioTarget(meetingApp: nil) == .global)
    }

    @Test("A new family process rebuilds the tap without breaking the timeline; the gap becomes silence")
    func rebuildKeepsTimeline() async throws {
        let backend = FakeBackend(processes: [process(10, 100, "us.zoom.xos"), process(20, 200, "com.google.Chrome")])
        let source = SystemAudioSource(target: .app(zoom), clock: SessionClock(), chunkDuration: 0.1, backend: backend)
        let collector = ChunkCollector(try await source.start())

        let first = try #require(backend.familyTap)
        #expect(first.objects == [10])
        #expect(backend.probeTap != nil)
        first.deliver([Float](repeating: 0.1, count: 16_000), arrival: 1.0)
        try await waitUntil { collector.duration >= 1.0 - 1e-9 }

        backend.add(process(11, 101, "us.zoom.xos.helper", output: true))
        try await waitUntil { backend.familyTap?.objects.map(Set.init) == [10, 11] }
        #expect(first.isStopped)
        let second = try #require(backend.familyTap)
        second.deliver([Float](repeating: 0.2, count: 8_000), arrival: 2.0)
        try await waitUntil { collector.duration >= 2.0 - 1e-9 }

        await source.stop()
        await collector.task.value
        let chunks = collector.all
        #expect(chunks.first?.startTime == 0)
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            #expect(abs(b.startTime - a.range.end) < 1e-9, "timeline jumps between \(a.range) and \(b.startTime)")
        }
        let samples = chunks.flatMap(\.samples)
        #expect(samples.count == 32_000)
        #expect(samples[0..<16_000].allSatisfy { $0 == 0.1 })
        #expect(samples[16_000..<24_000].allSatisfy { $0 == 0 })
        #expect(samples[24_000...].allSatisfy { $0 == 0.2 })

        var tapped: [SystemAudioTarget] = []
        for await event in source.events {
            if case .tapping(let target, _) = event { tapped.append(target) }
        }
        #expect(tapped == [.app(zoom), .app(zoom)])
    }

    @Test("A silent family tap while other audio carries speech for over 10 s switches to the global tap")
    func silentFamilyFallsBack() async throws {
        let backend = FakeBackend(processes: [process(10, 100, "us.zoom.xos")])
        let source = SystemAudioSource(target: .app(zoom), clock: SessionClock(), chunkDuration: 0.1, backend: backend)
        let collector = ChunkCollector(try await source.start())
        let family = try #require(backend.familyTap)
        let probe = try #require(backend.probeTap)

        // 16 s of silence from the app while another process plays speech, delivered a second at a time.
        let speech = speechLike(seconds: 16, rmsDB: -30)
        for second in 0..<16 {
            family.deliver([Float](repeating: 0, count: 16_000), arrival: Double(second + 1))
            probe.deliver(Array(speech[(second * 16_000)..<((second + 1) * 16_000)]), arrival: Double(second + 1))
            try await Task.sleep(for: .milliseconds(60))
        }
        try await waitUntil { source.target == .global }
        try await waitUntil { backend.familyTap == nil && backend.probeTap?.objects == nil && family.isStopped }
        await source.stop()
        await collector.task.value

        var fellBack: String?
        for await event in source.events {
            if case .fellBackToGlobal(let app, let reason) = event, app == zoom { fellBack = reason }
        }
        #expect(fellBack?.contains("Zoom stayed silent") == true)
    }

    @Test("The fallback rule: family audio or a long pause resets the count")
    func fallbackRule() {
        var rule = SilentTapFallback()
        for t in 1...10 {
            let fired = rule.update(familyAudible: false, globalSpeechSeconds: 1, at: Double(t))
            #expect(!fired)
        }
        let fired = rule.update(familyAudible: false, globalSpeechSeconds: 0.5, at: 11)
        #expect(fired)

        var audible = SilentTapFallback()
        for t in 1...20 {
            let fired = audible.update(familyAudible: t % 5 == 0, globalSpeechSeconds: 1, at: Double(t))
            #expect(!fired)
        }

        var paused = SilentTapFallback()
        for t in 1...8 { _ = paused.update(familyAudible: false, globalSpeechSeconds: 1, at: Double(t)) }
        let afterPause = paused.update(familyAudible: false, globalSpeechSeconds: 1, at: 15)
        #expect(!afterPause)
    }

    @Test("Speech captured at −41 dBFS RMS (HDMI monitor) counts as speech and as audible")
    func quietSpeechIsDetected() {
        let quiet = speechLike(seconds: 6, rmsDB: -41)
        var vad = VoiceActivityDetector()
        let flags = vad.process(quiet, sampleRate: 16_000)
        #expect(Double(flags.filter { $0 }.count) / Double(flags.count) > 0.6)

        var spans = SpeechSpanDetector()
        var covered = 0.0
        for start in stride(from: 0, to: quiet.count, by: 1_600) {
            let chunk = AudioChunk(
                channel: .system, startTime: Double(start) / 16_000, sampleRate: 16_000,
                samples: Array(quiet[start..<min(quiet.count, start + 1_600)]))
            covered += spans.spans(in: chunk).reduce(0) { $0 + $1.duration }
        }
        #expect(covered > 3.6)
        #expect(SilentTapFallback.isAudible(quiet))
    }

    @Test("Gain control brings −41 dBFS speech to about −20 dBFS")
    func quietInputIsRaised() {
        var agc = AutomaticGainControl()
        let input = speechLike(seconds: 15, rmsDB: -41)
        var output: [Float] = []
        for start in stride(from: 0, to: input.count, by: 1_600) {
            output += agc.process(Array(input[start..<min(input.count, start + 1_600)]), sampleRate: 16_000)
        }
        let settled = speechRMS(Array(output[(10 * 16_000)...]))
        #expect(abs(settled - -20) < 2, "speech RMS \(settled) dBFS")
        #expect(agc.gainDB > 15)
        #expect(output.allSatisfy { abs($0) <= agc.ceiling })
    }

    @Test("Gain control lowers loud speech to about −20 dBFS without exceeding the ceiling")
    func loudInputIsLowered() {
        var agc = AutomaticGainControl()
        let input = speechLike(seconds: 12, rmsDB: -6)
        let output = agc.process(input, sampleRate: 16_000)
        let settled = speechRMS(Array(output[(7 * 16_000)...]))
        #expect(abs(settled - -20) < 2, "speech RMS \(settled) dBFS")
        #expect(output.allSatisfy { abs($0) <= agc.ceiling })
    }

    @Test("The limiter catches a sudden loud burst after the gain has risen, then releases")
    func limiter() {
        var agc = AutomaticGainControl()
        _ = agc.process(speechLike(seconds: 10, rmsDB: -41), sampleRate: 16_000)
        let raised = agc.gainDB
        #expect(raised > 15)
        let burst = (0..<8_000).map { Float(sin(2 * Double.pi * 1_000 * Double($0) / 16_000)) }
        let output = agc.process(burst, sampleRate: 16_000)
        #expect(output.allSatisfy { abs($0) <= agc.ceiling })
        #expect(output.map(abs).max()! > 0.8)
        // Slow-moving: half a second of loud audio can't pull the gain all the way down.
        #expect(agc.gainDB > raised - 6)
    }

    @Test("Silence and faint noise don't move the gain")
    func silenceHoldsGain() {
        var agc = AutomaticGainControl()
        let noise = speechLike(seconds: 10, rmsDB: -80)
        let output = agc.process(noise, sampleRate: 16_000)
        #expect(agc.gainDB == 0)
        #expect(abs(level(output[...]) - -80) < 0.5)
    }

    @Test("A continuing assembler fills the gap to its first buffer with silence")
    func continuingAssembler() {
        var assembler = ChunkAssembler(
            channel: .system, sampleRate: 10, chunkDuration: 1, channelCount: 1, keepChannels: false, continuing: 2)
        let ones = [Float](repeating: 1, count: 5)
        let chunks = ones.withUnsafeBufferPointer { b in assembler.append(frames: 5, arrivalTime: 3) { _ in b } }
        #expect(chunks.map(\.startTime) == [2])
        #expect(chunks.first?.samples == [0, 0, 0, 0, 0, 1, 1, 1, 1, 1])
    }
}
