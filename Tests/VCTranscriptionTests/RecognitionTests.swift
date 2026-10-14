import Foundation
import Testing
import VCModels
@testable import VCTranscription

/// End-to-end recognition on the generated fixtures with the real on-device models.
/// Skipped when the fixtures or the locale assets are missing so the suite stays deterministic offline.
@Suite(.serialized) struct RecognitionTests {
    static func englishReady() async -> Bool {
        await Fixtures.ready(files: ["meeting.wav", "meeting.truth.json"], locales: ["en-GB"])
    }
    static func switchReady() async -> Bool {
        await Fixtures.ready(files: ["meeting.wav", "meeting.truth.json"], locales: ["en-GB", "en-US"])
    }
    static func frenchReady() async -> Bool {
        await Fixtures.ready(files: ["french.wav"], locales: ["en-GB", "fr-FR"])
    }

    @Test func supportedAndInstalledLocalesAreBCP47() async {
        let supported = await SpeechAssets.supportedLocaleIDs()
        let installed = await SpeechAssets.installedLocaleIDs()
        guard !supported.isEmpty else { return }  // SpeechTranscriber unavailable on this machine
        #expect(supported.contains("en-US"))
        #expect(supported.allSatisfy { !$0.contains("_") })
        #expect(Set(installed).isSubset(of: Set(supported)))
    }

    @Test func unsupportedLocaleIsRejected() async {
        await #expect(throws: TranscriptionError.self) {
            try await SpeechAssets.ensureInstalled(localeIDs: ["xx-QQ"])
        }
    }

    @Test(.enabled { await RecognitionTests.englishReady() })
    func fileTranscriptionMatchesTheScriptWithWordTiming() async throws {
        let url = try #require(Fixtures.url("meeting.wav"))
        let truth = try Fixtures.meetingTruth()
        let finals = try await FileTranscriber.transcribe(url: url, localeID: "en-GB")
        let text = finals.map(\.text).joined(separator: " ")
        let wer = WordErrorRate.compute(reference: truth.map(\.text).joined(separator: " "), hypothesis: text)
        print("FileTranscriber en-GB meeting.wav WER \(String(format: "%.3f", wer)) over \(finals.count) finals")
        #expect(wer < 0.2)

        let words = finals.flatMap(\.words)
        #expect(words.count >= 100)
        #expect(finals.allSatisfy { $0.localeID == "en-GB" && $0.channel == .microphone })
        #expect(finals.compactMap(\.confidence).allSatisfy { (0...1).contains($0) })
        for (a, b) in zip(words, words.dropFirst()) { #expect(b.range.start >= a.range.start - 0.01) }
        // Every word lies inside a scripted turn (generous 0.4 s for model timing granularity).
        let outside = words.filter { word in
            let mid = (word.range.start + word.range.end) / 2
            return !truth.contains { mid >= $0.start - 0.4 && mid <= $0.end + 0.4 }
        }
        #expect(Double(outside.count) / Double(words.count) < 0.05)
        // Ranges are file seconds: the first word starts near the first turn, the last ends near the last.
        #expect(abs((words.first?.range.start ?? -10) - truth[0].start) < 0.6)
        #expect(abs((words.last?.range.end ?? -10) - truth[truth.count - 1].end) < 1.0)
    }

    @available(macOS 26.0, *)
    @Test(.enabled { await RecognitionTests.englishReady() })
    func liveTranscriptionUsesTheSessionClockAndFinishesTheStream() async throws {
        let (samples, rate) = try Fixtures.samples("meeting.wav")
        let truth = try Fixtures.meetingTruth()
        let origin: TimeInterval = 100
        let transcriber = LiveTranscriber(
            channel: .system, localeID: "en-GB", contextualStrings: ["Rishi", "Samantha"], autoLanguage: false)
        let (log, collector) = EventLog.collecting(transcriber.events)
        try await transcriber.start()
        let chunk = Int(rate / 10)
        for start in stride(from: 0, to: samples.count, by: chunk) {
            await transcriber.append(
                AudioChunk(
                    channel: .system, startTime: origin + Double(start) / rate, sampleRate: rate,
                    samples: Array(samples[start..<min(start + chunk, samples.count)])))
        }
        await transcriber.finish()
        await collector.value  // stream must end after finish()

        let finals = await log.finals
        let words = finals.flatMap(\.words)
        let wer = WordErrorRate.compute(
            reference: truth.map(\.text).joined(separator: " "), hypothesis: finals.map(\.text).joined(separator: " "))
        print("LiveTranscriber en-GB meeting.wav WER \(String(format: "%.3f", wer)), \(await log.volatileCount) volatile, \(finals.count) finals")
        #expect(wer < 0.2)
        #expect(await log.volatileCount > 0)
        #expect(finals.allSatisfy { $0.channel == .system })
        #expect(abs((words.first?.range.start ?? 0) - (origin + truth[0].start)) < 0.6)
        #expect(abs((words.last?.range.end ?? 0) - (origin + truth[truth.count - 1].end)) < 1.0)
        await #expect(throws: TranscriptionError.notRunning) { try await transcriber.start() }
    }

    @available(macOS 26.0, *)
    @Test(.enabled { await RecognitionTests.englishReady() })
    func gapInAudioKeepsLaterWordsOnTheSessionClock() async throws {
        let (samples, rate) = try Fixtures.samples("meeting.wav")
        let truth = try Fixtures.meetingTruth()
        let firstTurn = Array(samples[0..<Int(truth[0].end * rate + 0.3 * rate)])
        let secondTurn = Array(samples[Int(truth[1].start * rate - 0.3 * rate)..<Int(truth[1].end * rate + 0.3 * rate)])
        let transcriber = LiveTranscriber(channel: .microphone, localeID: "en-GB", autoLanguage: false)
        let (log, collector) = EventLog.collecting(transcriber.events)
        try await transcriber.start()
        await transcriber.append(AudioChunk(channel: .microphone, startTime: 0, sampleRate: rate, samples: firstTurn))
        // 30 s of nothing (e.g. capture paused), then the second turn arrives.
        let resume: TimeInterval = 40
        await transcriber.append(
            AudioChunk(channel: .microphone, startTime: resume, sampleRate: rate, samples: secondTurn))
        await transcriber.finish()
        await collector.value

        let words = await log.finals.flatMap(\.words)
        let late = words.filter { $0.range.start >= resume - 0.1 }
        let early = words.filter { $0.range.end <= truth[0].end + 1 }
        #expect(early.count >= 8)
        #expect(late.count >= 8)
        #expect(early.count + late.count == words.count)
        #expect(late.allSatisfy { $0.range.end <= resume + Double(secondTurn.count) / rate + 0.3 })
    }

    @available(macOS 26.0, *)
    @Test(.enabled { await RecognitionTests.switchReady() })
    func explicitLocaleChangeLosesNoSpeechAndTagsResults() async throws {
        let (samples, rate) = try Fixtures.samples("meeting.wav")
        let truth = try Fixtures.meetingTruth()
        let transcriber = LiveTranscriber(channel: .microphone, localeID: "en-GB", autoLanguage: false)
        let (log, collector) = EventLog.collecting(transcriber.events)
        try await transcriber.start()
        // Switch in the silence between turn 3 and turn 4.
        let switchSample = Int((truth[2].end + 0.3) * rate)
        let chunk = Int(rate / 5)
        var switched = false
        for start in stride(from: 0, to: samples.count, by: chunk) {
            if !switched, start >= switchSample {
                try await transcriber.setLocale("en-US", reason: "test")
                switched = true
            }
            await transcriber.append(
                AudioChunk(
                    channel: .microphone, startTime: Double(start) / rate, sampleRate: rate,
                    samples: Array(samples[start..<min(start + chunk, samples.count)])))
        }
        #expect(await transcriber.currentLocaleID == "en-US")
        await transcriber.finish()
        await collector.value

        let changes = await log.localeChanges
        #expect(changes.count == 1)
        #expect(changes.first?.from == "en-GB" && changes.first?.to == "en-US")
        let finals = await log.finals
        let boundary = Double(switchSample) / rate
        #expect(finals.filter { $0.range.end <= boundary }.allSatisfy { $0.localeID == "en-GB" })
        #expect(finals.filter { $0.range.start >= boundary }.allSatisfy { $0.localeID == "en-US" })
        #expect(finals.contains { $0.localeID == "en-US" })
        let wer = WordErrorRate.compute(
            reference: truth.map(\.text).joined(separator: " "),
            hypothesis: finals.sorted { $0.range.start < $1.range.start }.map(\.text).joined(separator: " "))
        print("LiveTranscriber with en-GB→en-US switch WER \(String(format: "%.3f", wer))")
        #expect(wer < 0.2)
    }

    @Test(.enabled { await RecognitionTests.frenchReady() })
    func accentDetectorRanksTheSpokenLanguageFirst() async throws {
        let (samples, rate) = try Fixtures.samples("french.wav")
        let scores = try await AccentDetector().rank(
            samples: samples, sampleRate: rate, candidateLocaleIDs: ["en-GB", "fr-FR", "xx-QQ"])
        print("AccentDetector french.wav: " + scores.map { "\($0.localeID)=\(String(format: "%.3f", $0.meanConfidence))" }.joined(separator: " "))
        #expect(scores.map(\.localeID) == ["fr-FR", "en-GB"])
        #expect(scores[0].meanConfidence - scores[1].meanConfidence >= 0.2)
        #expect(scores[0].wordCount >= 5)
    }

    @Test func accentDetectorWithoutUsableCandidatesThrows() async {
        await #expect(throws: (any Error).self) {
            _ = try await AccentDetector().rank(
                samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000, candidateLocaleIDs: ["xx-QQ"])
        }
    }

    @available(macOS 26.0, *)
    @Test(.enabled { await RecognitionTests.frenchReady() })
    func liveTranscriberSwitchesToTheSpokenLanguageAutomatically() async throws {
        let (french, rate) = try Fixtures.samples("french.wav")
        let transcriber = LiveTranscriber(
            channel: .system, localeID: "en-GB", autoLanguage: true, candidateLocaleIDs: ["fr-FR"])
        let (log, collector) = EventLog.collecting(transcriber.events)
        try await transcriber.start()
        let chunk = Int(rate / 10)
        var clock: TimeInterval = 0
        func feed(_ samples: [Float]) async {
            for start in stride(from: 0, to: samples.count, by: chunk) {
                let piece = Array(samples[start..<min(start + chunk, samples.count)])
                await transcriber.append(AudioChunk(channel: .system, startTime: clock, sampleRate: rate, samples: piece))
                clock += Double(piece.count) / rate
            }
        }
        await feed(french)
        // Keep the meeting going with silence (paced loosely) until the check completes or 90 s pass.
        let silence = [Float](repeating: 0, count: Int(rate))
        let deadline = ContinuousClock.now + .seconds(90)
        while await transcriber.currentLocaleID == "en-GB", ContinuousClock.now < deadline {
            await feed(silence)
            try await Task.sleep(for: .milliseconds(250))
        }
        #expect(await transcriber.currentLocaleID == "fr-FR")
        await feed(french)
        await transcriber.finish()
        await collector.value

        let changes = await log.localeChanges
        #expect(changes.map(\.to) == ["fr-FR"])
        let frenchFinals = await log.finals.filter { $0.localeID == "fr-FR" }
        let confidence = frenchFinals.flatMap(\.words).compactMap(\.confidence)
        #expect(!confidence.isEmpty)
        #expect(confidence.reduce(0, +) / Double(max(confidence.count, 1)) > 0.7)
    }
}
