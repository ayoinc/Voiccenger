import Foundation
import Testing
import VCModels
@testable import VCTranscription

@Suite struct SpeechChunkerTests {
    /// Tone bursts (speech stand-ins) at the given second ranges over faint noise.
    static func signal(seconds: Double, bursts: [(Double, Double)]) -> [Float] {
        var state: UInt32 = 1
        var samples = (0..<Int(seconds * 16_000)).map { _ -> Float in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Float(state >> 8) / Float(1 << 24) - 0.5) * 0.0005
        }
        for (start, end) in bursts {
            for i in Int(start * 16_000)..<min(Int(end * 16_000), samples.count) {
                samples[i] += 0.3 * sin(Float(i) * 2 * .pi * 220 / 16_000)
            }
        }
        return samples
    }

    @Test func splitsAtLongPausesAndJoinsShortOnes() {
        let samples = Self.signal(seconds: 12, bursts: [(1, 2), (2.5, 3.5), (7.5, 9)])
        let chunks = SpeechChunker.split(samples)
        #expect(chunks.count == 2)
        // First chunk spans both bursts separated by a 0.5 s pause, padded by 0.5 s into the silence.
        #expect(abs(Double(chunks[0].lowerBound) / 16_000 - 0.5) < 0.06)
        #expect(abs(Double(chunks[0].upperBound) / 16_000 - 4.0) < 0.06)
        #expect(abs(Double(chunks[1].lowerBound) / 16_000 - 7.0) < 0.06)
        #expect(abs(Double(chunks[1].upperBound) / 16_000 - 9.5) < 0.06)
    }

    @Test func closeNeighboursShareThePauseWithoutOverlap() {
        // A 0.6 s pause, but together they'd exceed the length limit: the pause is split in the middle.
        let samples = Self.signal(seconds: 31, bursts: [(0.5, 27), (27.6, 29.8)])
        let chunks = SpeechChunker.split(samples)
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { $0.count <= 30 * 16_000 })
        #expect(chunks[0].upperBound == chunks[1].lowerBound)
        #expect(abs(Double(chunks[0].upperBound) / 16_000 - 27.3) < 0.06)
    }

    @Test func longSpeechIsCutIntoChunksOfAtMostThirtySeconds() {
        let samples = Self.signal(seconds: 75, bursts: [(0.5, 74.5)])
        let chunks = SpeechChunker.split(samples)
        #expect((3...4).contains(chunks.count))
        #expect(chunks.allSatisfy { $0.count <= 30 * 16_000 })
        for (a, b) in zip(chunks, chunks.dropFirst()) { #expect(a.upperBound <= b.lowerBound) }
        #expect(chunks.first!.lowerBound <= 8_000 && chunks.last!.upperBound >= 74 * 16_000)
    }

    @Test func silenceHasNoChunks() {
        #expect(SpeechChunker.split(Self.signal(seconds: 5, bursts: [])).isEmpty)
        #expect(SpeechChunker.split([]).isEmpty)
    }
}

@Suite struct SessionAudioTests {
    private func span(_ start: Int64, _ count: Int, _ value: Float) -> RecognitionTimeline.Span {
        RecognitionTimeline.Span(samples: [Float](repeating: value, count: count), startFrame: start)
    }

    @Test func slicesBySessionTimeAndFillsGapsWithSilence() {
        var audio = SessionAudio(capacitySeconds: 60)
        audio.append(span(16_000, 16_000, 1))  // 1 s ... 2 s
        audio.append(span(48_000, 16_000, 2))  // 3 s ... 4 s, gap 2–3 s
        let slice = audio.samples(from: 1.5, to: 3.5)
        #expect(slice.count == 32_000)
        #expect(slice[0] == 1 && slice[16_000] == 0 && slice[31_999] == 2)
        #expect(audio.samples(from: 0, to: 1).isEmpty)
        #expect(audio.samples(from: 3.5, to: 10).count == 8_000)
    }

    @Test func discardsOldAudioOnlyInLargeSteps() {
        var audio = SessionAudio(capacitySeconds: 60)
        audio.append(span(0, 30 * 16_000, 1))
        audio.discard(before: 5)
        #expect(audio.startFrame == 0)
        audio.discard(before: 12)
        #expect(audio.startFrame == 12 * 16_000)
        #expect(audio.samples(from: 0, to: 13).count == 16_000)
    }

    @Test func staysWithinCapacity() {
        var audio = SessionAudio(capacitySeconds: 10)
        for second in 0..<40 { audio.append(span(Int64(second * 16_000), 16_000, Float(second))) }
        #expect(audio.samples.count <= 10 * 16_000 + 10 * 16_000 / 4)
        #expect(audio.samples.last == 39)
    }
}

@Suite(.serialized) struct SpeechModelLibraryTests {
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vc-models-\(UUID().uuidString)", isDirectory: true)
    }

    /// Lays out empty stand-ins for every file the engine loads.
    private func placeFiles(_ kind: SpeechEngineKind, root: URL) throws {
        let fm = FileManager.default
        switch kind {
        case .cohere:
            let dir = SpeechModelLibrary.cohereDirectory(root: root)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for name in CohereTranscriber.requiredFiles {
                try fm.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
            }
        case .whisper:
            let base = SpeechModelLibrary.whisperBase(root: root)
            let model = WhisperTranscriber.modelFolder(base: base)
            for name in WhisperTranscriber.requiredModels {
                try fm.createDirectory(at: model.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            let tokenizer = WhisperTranscriber.tokenizerFolder(base: base)
            try fm.createDirectory(at: tokenizer, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: tokenizer.appendingPathComponent("tokenizer.json"))
        case .apple, .deepgram:
            break
        }
    }

    @Test func statusReflectsFilesOnDisk() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try placeFiles(.whisper, root: root)
        let library = SpeechModelLibrary(root: root)
        #expect(await library.status(.cohere) == .notDownloaded)
        #expect(await library.status(.whisper) == .downloaded)
        #expect(library.isDownloaded(.whisper) && !library.isDownloaded(.cohere))
        #expect(await library.isReady(.whisper) == false)
    }

    @Test func missingModelThrowsWithoutChangingStatus() async {
        let root = temporaryRoot()
        let library = SpeechModelLibrary(root: root)
        await #expect(throws: TranscriptionError.modelNotDownloaded(.cohere)) {
            _ = try await library.transcriber(.cohere)
        }
        await #expect(throws: TranscriptionError.modelNotDownloaded(.whisper)) {
            try await library.prewarm(.whisper)
        }
        #expect(await library.status(.cohere) == .notDownloaded)
    }

    @Test func downloadOfPresentFilesIsANoOp() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try placeFiles(.cohere, root: root)
        let library = SpeechModelLibrary(root: root)
        try await library.download(.cohere)
        try await library.download(.apple)
        #expect(await library.status(.cohere) == .downloaded)
    }

    @Test func deleteRemovesFilesAndEveryStreamSeesIt() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try placeFiles(.cohere, root: root)
        try placeFiles(.whisper, root: root)
        let library = SpeechModelLibrary(root: root)
        let first = library.statusUpdates
        let second = library.statusUpdates

        try await library.delete(.cohere)
        #expect(!FileManager.default.fileExists(atPath: SpeechModelLibrary.cohereDirectory(root: root).path))
        #expect(library.isDownloaded(.whisper))

        for stream in [first, second] {
            var seen: [(SpeechEngineKind, ModelStatus)] = []
            for await update in stream {
                seen.append(update)
                if seen.count == SpeechEngineKind.allCases.count + 1 { break }
            }
            // Current statuses first, then the change.
            #expect(Set(seen.prefix(SpeechEngineKind.allCases.count).map(\.0)) == Set(SpeechEngineKind.allCases))
            #expect(seen.prefix(3).contains { $0 == (.cohere, .downloaded) })
            #expect(seen.last! == (.cohere, .notDownloaded))
        }
        #expect(await library.status(.cohere) == .notDownloaded)
    }

    @Test func catalogueDescribesEveryEngine() {
        #expect(SpeechModelLibrary.allInfo.map(\.kind) == [.cohere, .whisper, .deepgram, .apple])
        #expect(SpeechModelLibrary.allInfo.filter(\.isCloud).map(\.kind) == [.deepgram])
        #expect(SpeechModelLibrary.info(.deepgram).downloadBytes == 0)
        let whisper = SpeechModelLibrary.info(.whisper)
        #expect(whisper.languageCodes.count >= 99)
        #expect(["sw", "yo", "ha", "am"].allSatisfy(whisper.languageCodes.contains))
        #expect(SpeechModelLibrary.info(.cohere).languageCodes.count == 14)
        #expect(SpeechModelLibrary.info(.apple).downloadBytes == 0)
        let rates = SpeechModelLibrary.allInfo.compactMap(\.africanWordErrorRate)
        #expect(rates == rates.sorted())
    }
}

/// Real models from the default library root; skipped unless downloaded on this Mac.
@Suite(.serialized) struct EngineAccuracyTests {
    static func ready(_ kind: SpeechEngineKind) -> Bool {
        SpeechModelLibrary.shared.isDownloaded(kind) && Fixtures.url("meeting.wav") != nil
    }

    /// First 15 s of the fixture meeting and its script.
    static func excerpt() throws -> (samples: [Float], text: String) {
        let samples = try AudioFileReader.read16k(url: try #require(Fixtures.url("meeting.wav")))
        let truth = try Fixtures.meetingTruth().filter { $0.end <= 15 }
        let end = Int((truth.last?.end ?? 15) * 16_000) + 8_000
        return (Array(samples.prefix(end)), truth.map(\.text).joined(separator: " "))
    }

    @Test(.enabled(if: EngineAccuracyTests.ready(.whisper)))
    func whisperTranscribesWithOrderedWordTimes() async throws {
        let (samples, text) = try Self.excerpt()
        let engine = try await SpeechModelLibrary.shared.transcriber(.whisper)
        let result = try await engine.transcribe(samples16k: samples, languageCode: "en", prompt: ["Daniel", "Samantha", "Rishi"])
        let wer = WordErrorRate.compute(reference: text, hypothesis: result.text)
        print("Whisper excerpt WER \(String(format: "%.3f", wer)): \(result.text)")
        #expect(wer < 0.15)
        let words = try #require(result.words)
        #expect(!words.isEmpty)
        for (a, b) in zip(words, words.dropFirst()) { #expect(a.range.start <= b.range.start) }
        #expect(words.last!.range.end <= Double(samples.count) / 16_000 + 0.5)
        await #expect(throws: TranscriptionError.unsupportedLanguage("xx", .whisper)) {
            _ = try await engine.transcribe(samples16k: samples, languageCode: "xx", prompt: [])
        }
    }

    @Test(.enabled(if: EngineAccuracyTests.ready(.cohere)))
    func cohereTranscribesAccurately() async throws {
        let (samples, text) = try Self.excerpt()
        let engine = try await SpeechModelLibrary.shared.transcriber(.cohere)
        #expect(await SpeechModelLibrary.shared.status(.cohere) == .ready)
        let result = try await engine.transcribe(samples16k: samples, languageCode: "en-GB", prompt: [])
        let wer = WordErrorRate.compute(reference: text, hypothesis: result.text)
        print("Cohere excerpt WER \(String(format: "%.3f", wer)): \(result.text)")
        #expect(wer < 0.15)
        #expect(result.languageCode == "en")
        await #expect(throws: TranscriptionError.unsupportedLanguage("sw", .cohere)) {
            _ = try await engine.transcribe(samples16k: samples, languageCode: "sw", prompt: [])
        }
    }
}

/// Returns fixed text, as an engine would for one window.
private struct FixedTranscriber: AccurateTranscriber {
    let kind = SpeechEngineKind.cohere
    let text: String

    func transcribe(samples16k: [Float], languageCode: String, prompt: [String]) async throws -> EngineTranscript {
        EngineTranscript(text: text, words: nil, engine: .cohere, languageCode: languageCode)
    }
}

@Suite struct WindowOverlapTests {
    /// One Apple final with evenly spaced words.
    private func appleFinal(_ text: String, start: Double, end: Double) -> TranscriptUpdate {
        TranscriptUpdate(
            channel: .microphone, text: text, range: TimeRange(start: start, end: end), confidence: 0.9,
            localeID: "en-GB", words: TimingTransfer.align(text: text, reference: [], range: TimeRange(start: start, end: end)),
            engine: .apple)
    }

    private func refine(_ engineText: String, apple: TranscriptUpdate, after previous: String) async throws
        -> RefiningTranscriber.WindowResult
    {
        try await RefiningTranscriber.refineWindow(
            [apple], samples: [Float](repeating: 0, count: 16_000), with: FixedTranscriber(text: engineText),
            languageCode: "en", prompt: [], customization: nil, previousText: previous)
    }

    @Test func repeatOfThePreviousWindowIsDroppedWithItsTimings() async throws {
        // Window 1 ran past its audio into the next sentence, slightly differently worded.
        let previous = "Maybe a snack for her brother Bob. We also need a small plastic of snake."
        let apple = appleFinal("We also need a small plastic snake and a big toy frog for the kids.", start: 23.2, end: 31.9)
        let result = try await refine(
            "We also need a small plastic snake and a big toy frog for the kids.", apple: apple, after: previous)
        guard case .final(let final) = result else {
            Issue.record("expected a final, got \(result)")
            return
        }
        #expect(final.text == "And a big toy frog for the kids.")
        #expect(final.engine == .cohere)
        #expect(final.words.map(\.text) == TextTokens.split(final.text))
        #expect(final.range.start == final.words[0].range.start && final.range.start > 23.2)
        #expect(final.range.end == 31.9)
    }

    @Test func windowThatOnlyRepeatsIsDropped() async throws {
        let apple = appleFinal("the train station", start: 40, end: 41)
        let result = try await refine(
            "at the train station.", apple: apple, after: "We will go meet her Wednesday at the train station.")
        #expect(result == .duplicate)
    }

    @Test func shortOrUnrelatedOpeningsAreKept() async throws {
        let apple = appleFinal("and the kids came too", start: 0, end: 2)
        // Two shared words are a natural repeat, not an overlap.
        guard case .final(let kept) = try await refine("And the kids came too.", apple: apple, after: "Ask Bob and the")
        else {
            Issue.record("expected a final")
            return
        }
        #expect(kept.text == "And the kids came too.")
        guard case .final(let fresh) = try await refine("She can scoop these things.", apple: apple, after: "for the kids.")
        else {
            Issue.record("expected a final")
            return
        }
        #expect(fresh.text == "She can scoop these things.")
        #expect(try await refine("  ", apple: apple, after: "") == .heardNothing)
    }
}

@Suite(.serialized) struct RefiningTranscriberTests {
    static func appleReady() async -> Bool {
        await Fixtures.ready(files: ["meeting.wav", "meeting.truth.json"], locales: ["en-GB"])
    }

    private func run(_ transcriber: RefiningTranscriber, samples: [Float]) async throws -> [TranscriptEvent] {
        let (log, collector) = EventLog.collecting(transcriber.events)
        try await transcriber.start()
        var offset = 0
        while offset < samples.count {
            let end = min(offset + 1_600, samples.count)
            await transcriber.append(
                AudioChunk(channel: .microphone, startTime: Double(offset) / 16_000, sampleRate: 16_000,
                           samples: Array(samples[offset..<end])))
            offset = end
        }
        await transcriber.finish()
        await collector.value
        return await log.events
    }

    @Test(.enabled { await RefiningTranscriberTests.appleReady() })
    func appleFinalsPassThroughWhenTheEngineIsNotAvailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let samples = try AudioFileReader.read16k(url: try #require(Fixtures.url("meeting.wav")))
        let transcriber = RefiningTranscriber(
            channel: .microphone, appleLocaleID: "en-GB", engine: .cohere, languageCode: "en", prompt: [],
            customization: VoiceSettings(spelling: .american, useRegionalVocabulary: false),
            library: SpeechModelLibrary(root: root), autoLanguage: false, waitForEngine: true)
        let events = try await run(transcriber, samples: Array(samples.prefix(16_000 * 20)))
        let finals = events.compactMap { if case .final(let u) = $0 { u } else { nil } }
        #expect(!finals.isEmpty)
        #expect(finals.allSatisfy { $0.engine == .apple })
        #expect(events.contains { if case .volatile(let u) = $0 { u.engine == .apple } else { false } })
    }

    @Test(.enabled { await RefiningTranscriberTests.appleReady() && EngineAccuracyTests.ready(.whisper) })
    func readyEngineReplacesFinalsWithTimedWordsInsideTheUtterance() async throws {
        try await SpeechModelLibrary.shared.prewarm(.whisper)
        let samples = try AudioFileReader.read16k(url: try #require(Fixtures.url("meeting.wav")))
        let transcriber = RefiningTranscriber(
            channel: .microphone, appleLocaleID: "en-GB", engine: .whisper, languageCode: "en",
            prompt: ["Daniel", "Samantha", "Rishi"], customization: nil, autoLanguage: false)
        let events = try await run(transcriber, samples: Array(samples.prefix(16_000 * 20)))
        let finals = events.compactMap { if case .final(let u) = $0 { u } else { nil } }
        #expect(!finals.isEmpty)
        #expect(finals.allSatisfy { $0.engine == .whisper }, "\(finals.map { "\($0.engine?.rawValue ?? "nil"): \($0.text)" })")
        for final in finals {
            var cursor = final.range.start
            for word in final.words {
                #expect(word.range.start >= cursor - 1e-9 && word.range.end <= final.range.end + 1e-9)
                cursor = word.range.end
            }
            #expect(final.words.map(\.text).joined(separator: " ") == final.text)
        }
        for (a, b) in zip(finals, finals.dropFirst()) { #expect(a.range.start <= b.range.start) }
    }
}
