import Foundation
import VCModels

/// Where `RefiningTranscriber` gets its instant preview and the finals it refines: Apple's streaming
/// `LiveTranscriber` on macOS 26, `ModelPreviewTranscriber` (a voice model on short windows) before it.
protocol PreviewSource: Actor {
    nonisolated var events: AsyncStream<TranscriptEvent> { get }
    func start() async throws
    /// `chunk` as captured; `spans` is the same audio already on the 16 kHz session timeline.
    func append(_ chunk: AudioChunk, spans: [RecognitionTimeline.Span]) async
    func setContextualStrings(_ strings: [String]) async
    /// `remaining`: audio the caller's resampler still held at the end of input.
    func finish(remaining: [RecognitionTimeline.Span]) async
}

@available(macOS 26.0, *)
extension LiveTranscriber: PreviewSource {
    func append(_ chunk: AudioChunk, spans _: [RecognitionTimeline.Span]) async {
        await append(chunk)
    }

    func finish(remaining _: [RecognitionTimeline.Span]) async {
        await finish()
    }
}

/// Live preview without Apple Speech (macOS before 26): an energy voice-activity detector cuts each
/// channel into utterances, and the voice model transcribes them on the fly.
///
/// While someone speaks, the utterance so far is transcribed after its first `firstPreviewSeconds` of
/// voiced audio and then after every further `previewIntervalSeconds`, as volatile text. Volatile requests
/// are coalesced: when the model is still busy only the newest one runs, so a slow Mac shows fewer updates
/// instead of falling behind. An utterance ends after `endPauseSeconds` without voice, or is cut at its
/// quietest recent frame once it reaches `maximumUtteranceSeconds`; its audio is then transcribed once more
/// as the final. Finals are never dropped and come out in order. No language switching happens here.
actor ModelPreviewTranscriber: PreviewSource {
    nonisolated let events: AsyncStream<TranscriptEvent>

    static let frameSamples = 480  // 30 ms at 16 kHz
    static let firstPreviewSeconds = 1.0
    static let previewIntervalSeconds = 2.0
    static let endPauseSeconds = 0.7
    static let maximumUtteranceSeconds = 15.0
    /// Utterances with less voiced audio than this (clicks, coughs) are dropped.
    static let minimumVoicedSeconds = 0.3
    /// Audio kept before the first and after the last voiced frame.
    static let paddingSeconds = 0.3

    private let channel: AudioChannel
    private let engine: SpeechEngineKind
    private let model: PreviewModel
    private let localeID: String
    private let languageCode: String
    private let waitForEngine: Bool
    private var prompt: [String]

    private let eventContinuation: AsyncStream<TranscriptEvent>.Continuation
    private let wake: AsyncStream<Void>
    private let wakeContinuation: AsyncStream<Void>.Continuation
    private var worker: Task<Void, Never>?
    private var isStarted = false
    private var isFinished = false

    private var audio = SessionAudio(capacitySeconds: 60)
    private var detector = VoiceActivityDetector()
    /// Session frame of the next unprocessed sample, and samples short of a whole frame.
    private var frameCursor: Int64?
    private var partialFrame: [Float] = []
    private var open: Utterance?
    private var nextUtteranceID = 0
    /// End of the audio already given to a final; the next utterance never reaches back before it.
    private var consumedEnd: TimeInterval = 0

    private var finals: [Request] = []
    private var latestVolatile: Request?
    private var loggedEngineFailure = false

    private struct Utterance {
        let id: Int
        var start: TimeInterval
        var lastVoiceEnd: TimeInterval
        var voicedSeconds: Double = 0
        var voicedAtLastPreview: Double = 0
        var hasPreview = false
        /// (end time, level) of every frame since `start`, to find where to cut a long utterance.
        var levels: [(end: TimeInterval, level: Float)] = []
    }

    private struct Request: Sendable {
        let utteranceID: Int
        let range: TimeRange
        let samples: [Float]
        let prompt: [String]
        let isFinal: Bool
    }

    /// The voice model behind the preview; tests substitute a scripted one.
    struct PreviewModel: Sendable {
        var isReady: @Sendable () async -> Bool
        var isDownloading: @Sendable () async -> Bool
        /// The loaded model (loads it if needed); throws `TranscriptionError.modelNotDownloaded` when missing.
        var transcriber: @Sendable () async throws -> any AccurateTranscriber

        static func library(_ library: SpeechModelLibrary, engine: SpeechEngineKind) -> PreviewModel {
            PreviewModel(
                isReady: { await library.isReady(engine) },
                isDownloading: {
                    if case .downloading = await library.status(engine) { return true }
                    return false
                },
                transcriber: { try await library.transcriber(engine) })
        }
    }

    /// - Parameter waitForEngine: offline processing — every request waits for the model to load.
    ///   Live, volatile previews are skipped until the model is ready (finals still load it).
    init(
        channel: AudioChannel, engine: SpeechEngineKind, localeID: String, languageCode: String, prompt: [String],
        library: SpeechModelLibrary, waitForEngine: Bool
    ) {
        self.init(
            channel: channel, engine: engine, localeID: localeID, languageCode: languageCode, prompt: prompt,
            model: .library(library, engine: engine), waitForEngine: waitForEngine)
    }

    init(
        channel: AudioChannel, engine: SpeechEngineKind, localeID: String, languageCode: String, prompt: [String],
        model: PreviewModel, waitForEngine: Bool
    ) {
        self.channel = channel
        self.engine = engine
        self.localeID = localeID
        self.languageCode = baseLanguageCode(languageCode)
        self.prompt = prompt
        self.model = model
        self.waitForEngine = waitForEngine
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (wake, wakeContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func start() async throws {
        guard !isFinished else { throw TranscriptionError.notRunning }
        guard !isStarted else { return }
        isStarted = true
        let wake = wake
        worker = Task { [weak self] in
            for await _ in wake {
                while let self, let request = await self.takeRequest() {
                    await self.run(request)
                }
            }
        }
        // Load the model while the meeting starts rather than on the first sentence.
        let model = model
        Task.detached(priority: .utility) { _ = try? await model.transcriber() }
    }

    func append(_ chunk: AudioChunk, spans: [RecognitionTimeline.Span]) async {
        guard isStarted, !isFinished else { return }
        for span in spans { process(span) }
    }

    func setContextualStrings(_ strings: [String]) async {
        prompt = strings
    }

    func finish(remaining: [RecognitionTimeline.Span]) async {
        guard !isFinished else { return }
        if isStarted {
            for span in remaining { process(span) }
            closeUtterance(end: open.map { $0.lastVoiceEnd + Self.paddingSeconds } ?? 0)
        }
        isFinished = true
        latestVolatile = nil
        wakeContinuation.finish()
        await worker?.value
        eventContinuation.finish()
    }

    // MARK: - Voice activity

    private func process(_ span: RecognitionTimeline.Span) {
        audio.append(span)
        if let cursor = frameCursor, span.startFrame != cursor + Int64(partialFrame.count) {
            // A gap in the input: whatever was pending is dropped, and the gap counts as silence.
            partialFrame = []
            noteSilence(until: Double(span.startFrame) / PCM.recognitionRate)
            frameCursor = nil
        }
        if frameCursor == nil { frameCursor = span.startFrame }
        partialFrame += span.samples
        let frameCount = partialFrame.count / Self.frameSamples
        guard frameCount > 0 else { return }
        for index in 0..<frameCount {
            let frame = partialFrame[(index * Self.frameSamples)..<((index + 1) * Self.frameSamples)]
            let start = Double(frameCursor! + Int64(index * Self.frameSamples)) / PCM.recognitionRate
            handleFrame(frame, start: start, end: start + Double(Self.frameSamples) / PCM.recognitionRate)
        }
        partialFrame.removeFirst(frameCount * Self.frameSamples)
        frameCursor! += Int64(frameCount * Self.frameSamples)
    }

    private func handleFrame(_ frame: ArraySlice<Float>, start: TimeInterval, end: TimeInterval) {
        let level = VoiceActivityDetector.level(frame)
        let voiced = detector.isVoiced(level: level)
        if voiced {
            if open == nil {
                nextUtteranceID += 1
                open = Utterance(id: nextUtteranceID, start: max(start - Self.paddingSeconds, consumedEnd), lastVoiceEnd: end)
            }
            open!.lastVoiceEnd = end
            open!.voicedSeconds += end - start
        }
        guard var utterance = open else { return }
        utterance.levels.append((end, level))
        open = utterance
        if !voiced, end - utterance.lastVoiceEnd >= Self.endPauseSeconds {
            closeUtterance(end: min(end, utterance.lastVoiceEnd + Self.paddingSeconds))
        } else if end - utterance.start >= Self.maximumUtteranceSeconds {
            cutLongUtterance(at: end)
        } else if voiced {
            let interval = utterance.hasPreview ? Self.previewIntervalSeconds : Self.firstPreviewSeconds
            if utterance.voicedSeconds - utterance.voicedAtLastPreview >= interval { requestPreview(until: end) }
        }
    }

    private func noteSilence(until time: TimeInterval) {
        guard let utterance = open, time - utterance.lastVoiceEnd >= Self.endPauseSeconds else { return }
        closeUtterance(end: utterance.lastVoiceEnd + Self.paddingSeconds)
    }

    /// Ends the open utterance at its quietest frame in the last third, then carries on with the rest as a
    /// new utterance (refinement later re-transcribes neighbouring finals together, repairing a cut word).
    private func cutLongUtterance(at time: TimeInterval) {
        guard let utterance = open else { return }
        let earliest = utterance.start + Self.maximumUtteranceSeconds * 2 / 3
        let candidates = utterance.levels.filter { $0.end >= earliest }
        let cut = candidates.reversed().min { $0.level < $1.level }?.end ?? time
        closeUtterance(end: cut)
        let rest = utterance.levels.filter { $0.end > cut }
        let voicedRest = rest.filter { detector.wasVoiced(level: $0.level) }
        guard let lastVoiced = voicedRest.last else { return }
        nextUtteranceID += 1
        var next = Utterance(id: nextUtteranceID, start: cut, lastVoiceEnd: lastVoiced.end)
        next.voicedSeconds = Double(voicedRest.count * Self.frameSamples) / PCM.recognitionRate
        next.levels = rest
        open = next
    }

    private func closeUtterance(end: TimeInterval) {
        guard let utterance = open else { return }
        open = nil
        guard utterance.voicedSeconds >= Self.minimumVoicedSeconds, end > utterance.start else { return }
        let range = TimeRange(start: utterance.start, end: end)
        finals.append(
            Request(
                utteranceID: utterance.id, range: range, samples: audio.samples(from: range.start, to: range.end),
                prompt: prompt, isFinal: true))
        consumedEnd = max(consumedEnd, end)
        audio.discard(before: consumedEnd - Self.paddingSeconds)
        // A pending preview of this utterance would only flash text the final replaces.
        if latestVolatile?.utteranceID == utterance.id { latestVolatile = nil }
        wakeContinuation.yield()
    }

    private func requestPreview(until end: TimeInterval) {
        guard var utterance = open else { return }
        utterance.voicedAtLastPreview = utterance.voicedSeconds
        utterance.hasPreview = true
        open = utterance
        let range = TimeRange(start: utterance.start, end: end)
        latestVolatile = Request(
            utteranceID: utterance.id, range: range, samples: audio.samples(from: range.start, to: range.end),
            prompt: prompt, isFinal: false)
        wakeContinuation.yield()
    }

    // MARK: - Transcription

    /// Finals first, in order; then the newest preview.
    private func takeRequest() -> Request? {
        if !finals.isEmpty { return finals.removeFirst() }
        defer { latestVolatile = nil }
        return latestVolatile
    }

    private func run(_ request: Request) async {
        guard !request.samples.isEmpty else { return }
        if !request.isFinal, !waitForEngine {
            guard await model.isReady() else { return }
        }
        do {
            let transcriber = try await transcriber(waitingForDownload: request.isFinal)
            let result = try await transcriber.transcribe(
                samples16k: request.samples, languageCode: languageCode, prompt: request.prompt)
            guard
                let update = FileTranscriber.makeUpdate(
                    result, range: request.range, channel: channel, customization: nil, extraVocabulary: request.prompt,
                    localeID: localeID)
            else { return }
            if request.isFinal {
                eventContinuation.yield(.final(update))
            } else if open?.id == request.utteranceID {
                eventContinuation.yield(.volatile(update))
            }
        } catch {
            guard !loggedEngineFailure else { return }
            loggedEngineFailure = true
            transcriptionLog.error(
                "\(self.engine.rawValue, privacy: .public) live preview failed on \(self.channel.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The loaded engine. With `waitingForDownload`, a model that's still downloading is waited for while the
    /// meeting goes on (finals queue up meanwhile and come out once it's there) instead of failing.
    private func transcriber(waitingForDownload: Bool) async throws -> any AccurateTranscriber {
        while true {
            do {
                return try await model.transcriber()
            } catch TranscriptionError.modelNotDownloaded(let kind) where waitingForDownload && !isFinished {
                guard await model.isDownloading() else { throw TranscriptionError.modelNotDownloaded(kind) }
                try await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// Energy voice-activity detection on 30 ms frames with an adaptive noise floor: a frame is voiced 10 dB
/// above the floor (and above -55 dBFS); anything over -40 dBFS always counts, as in `SpeechChunker`.
struct VoiceActivityDetector {
    /// dB the floor creeps up per frame while the input stays above it (~0.3 dB/s), so it follows a
    /// rising noise level without mistaking a long stretch of speech for noise.
    static let floorRisePerFrame: Float = 0.01

    private(set) var floor: Float?

    static func level(_ frame: ArraySlice<Float>) -> Float {
        guard !frame.isEmpty else { return -120 }
        var sum: Float = 0
        for sample in frame { sum += sample * sample }
        return 10 * log10(max(sum / Float(frame.count), 1e-12))
    }

    var threshold: Float {
        min(max((floor ?? -60) + 10, -55), -40)
    }

    mutating func isVoiced(level: Float) -> Bool {
        if let current = floor {
            floor = level < current ? level : current + Self.floorRisePerFrame
        } else {
            floor = level
        }
        return level > threshold
    }

    /// Classifies an earlier frame against the current threshold without updating the floor.
    func wasVoiced(level: Float) -> Bool {
        level > threshold
    }
}
