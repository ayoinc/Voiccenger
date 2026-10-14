import Foundation
import Testing
import VCModels
@testable import VCTranscription

/// Real Deepgram round trips (billed, ~48 s of audio each); run only with `VOICCENGER_DEEPGRAM_LIVE=1` and a key
/// in the Keychain, `DEEPGRAM_API_KEY` or `~/.deepgram_secret`.
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["VOICCENGER_DEEPGRAM_LIVE"] == "1" && Fixtures.url("meeting.wav") != nil),
    .serialized)
struct DeepgramLiveTests {
    @Test func streamsTheFixtureMeetingInRealTime() async throws {
        let library = SpeechModelLibrary(root: FileManager.default.temporaryDirectory.appendingPathComponent("vc-dg-live"))
        let (samples, rate) = try Fixtures.samples("meeting.wav")
        let truth = try Fixtures.meetingTruth()
        let live = DeepgramLiveTranscriber(
            channel: .microphone, localeID: "en-GB", languageCode: "en", prompt: ["Daniel", "Samantha", "Rishi", "Karen"],
            library: library)
        let received = TimedEvents()
        let events = live.events
        let collecting = Task { for await event in events { await received.append(event) } }
        try await live.start()
        #expect(await live.fallbackReason == nil)

        let chunk = Int(rate / 10)
        let start = ContinuousClock.now
        await received.setStart(start)
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunk, samples.count)
            await live.append(
                AudioChunk(channel: .microphone, startTime: Double(offset) / rate, sampleRate: rate, samples: Array(samples[offset..<end])))
            offset = end
            try await Task.sleep(until: start + .milliseconds(Int(Double(offset) / rate * 1000)), clock: .continuous)
        }
        await live.finish()
        await collecting.value

        let log = await received.log
        let finals = log.compactMap { item -> (TranscriptUpdate, Double)? in
            if case .final(let u) = item.event { (u, item.at) } else { nil }
        }
        let firstInterim = try #require(log.first { if case .volatile = $0.event { true } else { false } })
        let firstSpeech = truth[0].start
        print(String(format: "First interim %.2f s after the first speech was fed (%.2f s after streaming began)", firstInterim.at - firstSpeech, firstInterim.at))

        for turn in truth {
            guard let closing = finals.first(where: { ($0.0.words.last?.range.end ?? $0.0.range.end) >= turn.end - 0.5 }) else { continue }
            print(String(format: "Turn ending %6.2f s (%@): final after %.2f s", turn.end, turn.speaker, closing.1 - turn.end))
        }
        let lags = finals.map { $0.1 - $0.0.range.end }
        print(String(format: "Final latency after the last word: mean %.2f s, max %.2f s over %d finals", lags.reduce(0, +) / Double(max(lags.count, 1)), lags.max() ?? 0, lags.count))

        let text = finals.map(\.0.text).joined(separator: " ")
        let wer = WordErrorRate.compute(reference: truth.map(\.text).joined(separator: " "), hypothesis: text)
        print(String(format: "Streaming WER %.3f: %@", wer, text))
        #expect(wer < 0.1)

        let words = finals.flatMap(\.0.words)
        let starts = words.map(\.range.start)
        #expect(starts == starts.sorted(), "word times are monotonic")
        for turn in truth {
            let nearest = starts.map { abs($0 - turn.start) }.min() ?? .infinity
            print(String(format: "Turn %@ at %.2f s: nearest word starts %.2f s away", turn.speaker, turn.start, nearest))
            #expect(nearest <= 1.0, "\(turn.speaker) at \(turn.start)")
        }
        print(String(format: "Audio streamed: %.1f s", Double(samples.count) / rate))
    }
}

/// Events with the seconds since `start` they arrived.
private actor TimedEvents {
    private(set) var log: [(event: TranscriptEvent, at: Double)] = []
    private var start = ContinuousClock.now

    func setStart(_ instant: ContinuousClock.Instant) { start = instant }

    func append(_ event: TranscriptEvent) {
        let elapsed = ContinuousClock.now - start
        log.append((event, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18))
    }
}
