@preconcurrency import AVFAudio
import Foundation
import Speech
import VCModels

/// Convenience offline transcription of a file (CLI/tests).
public enum FileTranscriber {
    /// Transcribes the whole file (any format AVAudioFile reads) and returns the final results in order;
    /// ranges are seconds from the start of the file. Installs the locale's assets first if needed.
    public static func transcribe(url: URL, localeID: String, channel: AudioChannel = .microphone) async throws
        -> [TranscriptUpdate]
    {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.speechTranscriberUnavailable }
        try await SpeechAssets.ensureInstalled(localeIDs: [localeID])
        let locale = try await SpeechAssets.resolveInstalledLocale(localeID)
        return try await OfflineRecognizer.transcribe(url: url, locale: locale, channel: channel)
    }

    /// Transcribes the file with a voice model: the audio is split at pauses into chunks of at most 30 s, each
    /// chunk becomes one final update (ranges in seconds from the start of the file) with word timings —
    /// the engine's own (Whisper, Apple) or spread across the chunk by length (Cohere).
    /// `customization` (when given) is applied to each chunk's text, with `prompt` as extra vocabulary.
    /// Loads the engine if needed; throws `TranscriptionError.modelNotDownloaded` when its files are missing.
    public static func transcribe(
        url: URL, engine: SpeechEngineKind, languageCode: String, prompt: [String] = [],
        customization: VoiceSettings? = nil, channel: AudioChannel = .microphone,
        library: SpeechModelLibrary = .shared
    ) async throws -> [TranscriptUpdate] {
        let transcriber = try await library.transcriber(engine)
        let samples = try AudioFileReader.read16k(url: url)
        var updates: [TranscriptUpdate] = []
        for chunk in SpeechChunker.split(samples) {
            try Task.checkCancellation()
            let result = try await transcriber.transcribe(
                samples16k: Array(samples[chunk]), languageCode: languageCode, prompt: prompt)
            let range = TimeRange(
                start: Double(chunk.lowerBound) / PCM.recognitionRate, end: Double(chunk.upperBound) / PCM.recognitionRate)
            if let update = makeUpdate(
                result, range: range, channel: channel, customization: customization, extraVocabulary: prompt)
            {
                updates.append(update)
            }
        }
        return updates
    }

    /// Final update for one utterance transcribed by an engine; `range` is where its samples sit on the
    /// caller's clock. Engine word times are shifted onto that clock; text changed by customization, or text
    /// without engine words, gets times by `TimingTransfer`. Nil when the engine heard nothing.
    static func makeUpdate(
        _ result: EngineTranscript, range: TimeRange, channel: AudioChannel, customization: VoiceSettings?,
        extraVocabulary: [String], localeID: String? = nil
    ) -> TranscriptUpdate? {
        let raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let text = customization.map { TranscriptCustomizer.apply(raw, settings: $0, extraVocabulary: extraVocabulary) } ?? raw
        let engineWords = (result.words ?? []).map { word in
            TimedWord(
                text: word.text,
                range: TimeRange(start: range.start + word.range.start, end: range.start + word.range.end),
                confidence: word.confidence)
        }
        let words = TimingTransfer.align(text: text, reference: engineWords, range: range)
        let confidences = words.compactMap(\.confidence)
        return TranscriptUpdate(
            channel: channel, text: text, range: range,
            confidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count),
            localeID: localeID ?? result.languageCode, words: words, engine: result.engine)
    }
}

/// Reads any AVAudioFile-readable file as 16 kHz mono Float32 (channels averaged), block by block.
enum AudioFileReader {
    static let blockFrames: AVAudioFrameCount = 65_536

    static func read16k(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else {
            throw TranscriptionError.audioConversionFailed("cannot allocate read buffer")
        }
        let resampler: PCMStreamConverter? =
            format.sampleRate == PCM.recognitionRate
            ? nil
            : try PCMStreamConverter(
                from: PCM.monoFloatFormat(sampleRate: format.sampleRate),
                to: PCM.monoFloatFormat(sampleRate: PCM.recognitionRate))
        var output: [Float] = []
        output.reserveCapacity(Int(Double(file.length) * PCM.recognitionRate / format.sampleRate) + 1024)
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: blockFrames)
            guard buffer.frameLength > 0 else { break }
            let mono = mixdown(buffer)
            if let resampler {
                output += PCM.floatSamples(try resampler.convert(PCM.monoFloatBuffer(mono, format: resampler.inputFormat)))
            } else {
                output += mono
            }
        }
        if let resampler { output += PCM.floatSamples(try resampler.flush()) }
        return output
    }

    private static func mixdown(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard let data = buffer.floatChannelData, channels > 0 else { return [] }
        if channels == 1 { return Array(UnsafeBufferPointer(start: data[0], count: frames)) }
        var mono = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channels)
        for channel in 0..<channels {
            let samples = data[channel]
            for i in 0..<frames { mono[i] += samples[i] * scale }
        }
        return mono
    }
}

/// Energy-based splitting of 16 kHz audio into utterance chunks at pauses.
enum SpeechChunker {
    static let frameSamples = 480  // 30 ms
    /// A quiet stretch at least this long separates utterances.
    static let minimumPauseSeconds = 0.3
    /// Utterances separated by a shorter pause are transcribed together, up to `maximumSeconds`: the engines
    /// are markedly more accurate with a whole passage of context than with sentence-sized pieces.
    static let joinPauseSeconds = 3.0
    static let maximumSeconds = 30.0
    /// Silence kept around speech (at most half the pause to the neighbouring chunk), so soft word onsets and
    /// endings below the energy threshold aren't clipped.
    static let paddingSeconds = 0.5

    /// Sample ranges, in order and non-overlapping, each ≤ `maximumSeconds`, covering every voiced region.
    static func split(_ samples: [Float], maximumSeconds: Double = maximumSeconds) -> [Range<Int>] {
        let frameCount = samples.count / frameSamples + (samples.count % frameSamples == 0 ? 0 : 1)
        guard frameCount > 0 else { return [] }
        let levels = (0..<frameCount).map { frame -> Float in
            let start = frame * frameSamples
            let end = min(start + frameSamples, samples.count)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            return 10 * log10(max(sum / Float(end - start), 1e-12))
        }
        let sorted = levels.sorted()
        let floor = sorted[sorted.count / 10]
        // 10 dB over the noise floor, at least -55 dBFS; anything above -40 dBFS counts as voice even when the
        // "floor" is speech (no pauses in the recording).
        let threshold = min(max(floor + 10, -55), -40)
        let voiced = levels.map { $0 > threshold }

        // Voiced regions separated by pauses of at least `minimumPauseSeconds`.
        let pauseFrames = Int((minimumPauseSeconds * PCM.recognitionRate / Double(frameSamples)).rounded(.up))
        var regions: [Range<Int>] = []
        var frame = 0
        while frame < frameCount {
            guard voiced[frame] else {
                frame += 1
                continue
            }
            let start = frame
            var lastVoiced = frame
            while frame < frameCount, frame - lastVoiced < pauseFrames {
                if voiced[frame] { lastVoiced = frame }
                frame += 1
            }
            regions.append(start..<(lastVoiced + 1))
        }

        let maximumFrames = Int(maximumSeconds * PCM.recognitionRate) / frameSamples
        let joinFrames = Int(joinPauseSeconds * PCM.recognitionRate) / frameSamples
        let padFrames = Int((paddingSeconds * PCM.recognitionRate / Double(frameSamples)).rounded())
        var chunks: [Range<Int>] = []
        let pieces = regions.flatMap { split($0, levels: levels, maximumFrames: maximumFrames - 2 * padFrames) }
        for region in pieces {
            if let last = chunks.last, region.lowerBound - last.upperBound < joinFrames,
                region.upperBound - last.lowerBound <= maximumFrames - 2 * padFrames
            {
                chunks[chunks.count - 1] = last.lowerBound..<region.upperBound
            } else {
                chunks.append(region)
            }
        }
        // Pad into the pauses — up to the middle of the gap to a neighbour — and convert to samples.
        var ranges: [Range<Int>] = []
        for (index, chunk) in chunks.enumerated() {
            var lower = max(chunk.lowerBound - padFrames, 0)
            if index > 0 { lower = max(lower, (chunks[index - 1].upperBound + chunk.lowerBound) / 2) }
            var upper = chunk.upperBound + padFrames
            if index + 1 < chunks.count { upper = min(upper, (chunk.upperBound + chunks[index + 1].lowerBound) / 2) }
            let start = max(lower * frameSamples, ranges.last?.upperBound ?? 0)
            let end = min(upper * frameSamples, samples.count)
            if end > start { ranges.append(start..<end) }
        }
        return ranges
    }

    /// Cuts a region longer than `maximumFrames` at its quietest frame within the last third of each window.
    private static func split(_ region: Range<Int>, levels: [Float], maximumFrames: Int) -> [Range<Int>] {
        var pieces: [Range<Int>] = []
        var start = region.lowerBound
        while region.upperBound - start > maximumFrames {
            let window = (start + maximumFrames * 2 / 3)..<(start + maximumFrames)
            // Quietest frame; among equals the latest, so chunks stay as long as allowed.
            let cut = window.reversed().min { levels[$0] < levels[$1] } ?? window.upperBound
            pieces.append(start..<cut)
            start = cut
        }
        pieces.append(start..<region.upperBound)
        return pieces
    }
}
