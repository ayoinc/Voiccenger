import Foundation
import Testing
import VCModels
@testable import VCTranscription

/// Writes "words" proportional to the audio length and counts calls, like a voice model would.
private actor ScriptedModel {
    private(set) var calls: [(seconds: Double, at: Int)] = []
    private var counter = 0

    func record(_ seconds: Double) {
        counter += 1
        calls.append((seconds, counter))
    }
}

private struct LengthTranscriber: AccurateTranscriber {
    let kind = SpeechEngineKind.whisper
    let log: ScriptedModel

    func transcribe(samples16k: [Float], languageCode: String, prompt: [String]) async throws -> EngineTranscript {
        let seconds = Double(samples16k.count) / PCM.recognitionRate
        await log.record(seconds)
        return EngineTranscript(text: "heard \(String(format: "%.1f", seconds)) seconds", words: nil, engine: .whisper, languageCode: languageCode)
    }
}

/// 16 kHz audio: a 220 Hz tone at -14 dBFS during `bursts` (start, end seconds), low noise elsewhere.
private func signal(seconds: Double, bursts: [(Double, Double)]) -> [Float] {
    let rate = PCM.recognitionRate
    var samples = (0..<Int(seconds * rate)).map { i in Float(sin(Double(i) * 1.7)) * 0.0005 }
    for (start, end) in bursts {
        for i in Int(start * rate)..<min(Int(end * rate), samples.count) {
            samples[i] = Float(sin(2 * Double.pi * 220 * Double(i) / rate)) * 0.3
        }
    }
    return samples
}

private func run(
    _ samples: [Float], ready: Bool = true, startTime: TimeInterval = 0
) async throws -> (events: [TranscriptEvent], calls: [(seconds: Double, at: Int)]) {
    let log = ScriptedModel()
    let transcriber = LengthTranscriber(log: log)
    let model = ModelPreviewTranscriber.PreviewModel(
        isReady: { ready }, isDownloading: { false }, transcriber: { transcriber })
    let preview = ModelPreviewTranscriber(
        channel: .microphone, engine: .whisper, localeID: "en-GB", languageCode: "en", prompt: [], model: model,
        waitForEngine: false)
    try await preview.start()
    let collector = Task {
        var events: [TranscriptEvent] = []
        for await event in preview.events { events.append(event) }
        return events
    }
    // 100 ms chunks, as capture delivers them.
    let step = Int(PCM.recognitionRate / 10)
    for start in stride(from: 0, to: samples.count, by: step) {
        let piece = Array(samples[start..<min(start + step, samples.count)])
        let frame = Int64((startTime * PCM.recognitionRate).rounded()) + Int64(start)
        let chunk = AudioChunk(
            channel: .microphone, startTime: startTime + Double(start) / PCM.recognitionRate,
            sampleRate: PCM.recognitionRate, samples: piece)
        await preview.append(chunk, spans: [RecognitionTimeline.Span(samples: piece, startFrame: frame)])
        // Let the worker run between chunks, as real time would.
        await Task.yield()
    }
    await preview.finish(remaining: [])
    return (await collector.value, await log.calls)
}

private func finals(_ events: [TranscriptEvent]) -> [TranscriptUpdate] {
    events.compactMap { if case .final(let u) = $0 { u } else { nil } }
}

private func volatiles(_ events: [TranscriptEvent]) -> [TranscriptUpdate] {
    events.compactMap { if case .volatile(let u) = $0 { u } else { nil } }
}

@Suite struct ModelPreviewTests {
    @Test func pausesSplitUtterancesIntoFinalsOnTheSessionClock() async throws {
        let audio = signal(seconds: 8, bursts: [(1, 3), (4.5, 6)])
        let (events, _) = try await run(audio, startTime: 100)
        let lines = finals(events)
        #expect(lines.count == 2)
        // Padded by up to 0.3 s around the voiced audio, on the caller's clock.
        #expect(abs(lines[0].range.start - 100.7) < 0.1)
        #expect(abs(lines[0].range.end - 103.3) < 0.1)
        #expect(abs(lines[1].range.start - 104.2) < 0.1)
        #expect(abs(lines[1].range.end - 106.3) < 0.1)
        for line in lines {
            #expect(line.engine == .whisper)
            #expect(line.localeID == "en-GB")
            #expect(!line.words.isEmpty)
        }
        #expect(lines[0].words.first!.range.start >= lines[0].range.start)
        #expect(lines[0].words.last!.range.end <= lines[0].range.end + 1e-6)
    }

    @Test func longSpeechShowsVolatileTextBeforeItsFinal() async throws {
        let audio = signal(seconds: 7, bursts: [(0.5, 5.5)])
        let (events, calls) = try await run(audio)
        let firstFinal = try #require(events.firstIndex { if case .final = $0 { true } else { false } })
        #expect(volatiles(Array(events[..<firstFinal])).count >= 1)
        // No preview of an utterance after its final.
        #expect(volatiles(Array(events[firstFinal...])).isEmpty)
        // At most: one preview after 1 s of speech, then one every 2 s, plus the final.
        #expect(calls.count <= 4)
        #expect(finals(events).count == 1)
    }

    @Test func continuousSpeechIsCutBeforeTheMaximumLength() async throws {
        let audio = signal(seconds: 40, bursts: [(0.5, 39)])
        let (events, _) = try await run(audio)
        let lines = finals(events)
        #expect(lines.count >= 3)
        for line in lines {
            #expect(line.range.end - line.range.start <= ModelPreviewTranscriber.maximumUtteranceSeconds + 0.5)
        }
        // Consecutive finals neither overlap nor leave speech out.
        for (a, b) in zip(lines, lines.dropFirst()) {
            #expect(b.range.start >= a.range.end - 1e-6)
            #expect(b.range.start - a.range.end < 0.1)
        }
    }

    @Test func clicksAndSilenceProduceNothing() async throws {
        let audio = signal(seconds: 5, bursts: [(1, 1.1), (3, 3.15)])
        let (events, calls) = try await run(audio)
        #expect(events.isEmpty)
        #expect(calls.isEmpty)
    }

    @Test func modelNotReadyStillWritesFinalsButNoPreview() async throws {
        let audio = signal(seconds: 6, bursts: [(0.5, 4.5)])
        let (events, _) = try await run(audio, ready: false)
        #expect(volatiles(events).isEmpty)
        #expect(finals(events).count == 1)
    }

    @Test func refiningTranscriberPassesModelPreviewFinalsThrough() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vc-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let log = ScriptedModel()
        let transcriber = LengthTranscriber(log: log)
        let refining = RefiningTranscriber(
            channel: .system, appleLocaleID: "en-GB", engine: .whisper, languageCode: "en", prompt: [],
            customization: nil, library: SpeechModelLibrary(root: root), autoLanguage: false, waitForEngine: false,
            modelPreview: .init(isReady: { true }, isDownloading: { false }, transcriber: { transcriber }))
        #expect(refining.previewEngineKind == .whisper)
        try await refining.start()
        let collector = Task {
            var events: [TranscriptEvent] = []
            for await event in refining.events { events.append(event) }
            return events
        }
        let audio = signal(seconds: 6, bursts: [(1, 2.5)])
        let step = Int(PCM.recognitionRate / 10)
        for start in stride(from: 0, to: audio.count, by: step) {
            await refining.append(
                AudioChunk(
                    channel: .system, startTime: Double(start) / PCM.recognitionRate, sampleRate: PCM.recognitionRate,
                    samples: Array(audio[start..<min(start + step, audio.count)])))
            await Task.yield()
        }
        await refining.finish()
        let lines = finals(await collector.value)
        #expect(lines.count == 1)
        #expect(lines.first?.engine == .whisper)
        #expect(lines.first?.text.hasPrefix("heard") == true)
    }
}

@Suite struct VoiceActivityDetectorTests {
    @Test func adaptsToTheNoiseFloorAndKeepsLoudSpeechVoiced() {
        var vad = VoiceActivityDetector()
        let quiet = (0..<100).map { _ in vad.isVoiced(level: -62) }
        #expect(!quiet.contains(true))
        let speech = vad.isVoiced(level: -45)
        #expect(speech)
        // A long loud stretch never stops counting: above -40 dBFS is always voice.
        let loud = (0..<5_000).map { _ in vad.isVoiced(level: -30) }
        #expect(!loud.contains(false))
    }
}

@Suite struct EngineSupportTests {
    @Test func defaultsFollowTheChip() {
        let intel = MachineInfo(osMajor: 15, osMinor: 6, isAppleSilicon: false, processArchitecture: "x86_64", physicalMemory: 1 << 34)
        let silicon = MachineInfo(osMajor: 14, osMinor: 4, isAppleSilicon: true, processArchitecture: "arm64", physicalMemory: 1 << 34)
        // Intel: neither on-device model runs; Apple Speech (classic) is the default.
        #expect(EngineSupport.defaultEngine(machine: intel) == .apple)
        #expect(EngineSupport.onDeviceModels(machine: intel).isEmpty)
        #expect(EngineSupport.defaultEngine(machine: silicon) == .cohere)
        #expect(EngineSupport.unsupportedReason(.apple, machine: intel) == nil)
        #expect(EngineSupport.unsupportedReason(.whisper, machine: intel) == "Needs Apple silicon")
        #expect(EngineSupport.unsupportedReason(.cohere, machine: silicon) == nil)
    }
}
