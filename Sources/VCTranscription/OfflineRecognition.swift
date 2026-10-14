@preconcurrency import AVFAudio
import CoreMedia
import Foundation
import Speech
import VCModels

/// One-shot recognition of in-memory samples or a file with a non-volatile transcriber.
@available(macOS 26.0, *)
enum OfflineRecognizer {
    /// Transcribes `samples` (mono Float32 at `sampleRate`, time 0 = first sample) and returns final results.
    /// `contextualStrings` bias recognition toward names and jargon.
    static func transcribe(
        samples: [Float], sampleRate: Double, locale: Locale, channel: AudioChannel,
        timeOffset: TimeInterval = 0, contextualStrings: [String] = []
    ) async throws -> [TranscriptUpdate] {
        let transcriber = TranscriberFactory.make(locale: locale, volatile: false)
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        else { throw TranscriptionError.noCompatibleAudioFormat }
        let inputs = try analyzerInputs(
            samples: samples, sampleRate: sampleRate, analyzerFormat: analyzerFormat, timeOffset: timeOffset)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        for input in inputs { continuation.yield(input) }
        continuation.finish()

        let localeID = locale.identifier(.bcp47)
        let collector = Task { try await collectFinals(transcriber, channel: channel, localeID: localeID) }
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: analyzerOptions)
        do {
            try await analyzer.prepareToAnalyze(in: analyzerFormat)
            if !contextualStrings.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = contextualStrings
                try await analyzer.setContext(context)
            }
            try await analyzer.start(inputSequence: stream)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }
        return try await collector.value
    }

    /// Transcribes an audio file; result ranges are seconds from the start of the file.
    static func transcribe(url: URL, locale: Locale, channel: AudioChannel) async throws -> [TranscriptUpdate] {
        let file = try AVAudioFile(forReading: url)
        let transcriber = TranscriberFactory.make(locale: locale, volatile: false)
        let localeID = locale.identifier(.bcp47)
        let collector = Task { try await collectFinals(transcriber, channel: channel, localeID: localeID) }
        do {
            let analyzer = try await SpeechAnalyzer(
                inputAudioFile: file, modules: [transcriber], options: analyzerOptions, finishAfterFile: true)
            let updates = try await collector.value
            withExtendedLifetime(analyzer) {}
            return updates
        } catch {
            collector.cancel()
            throw error
        }
    }

    /// Lingering retention keeps a locale's model warm between back-to-back checks.
    static let analyzerOptions = SpeechAnalyzer.Options(priority: .utility, modelRetention: .lingering)

    private static func collectFinals(
        _ transcriber: SpeechTranscriber, channel: AudioChannel, localeID: String
    ) async throws -> [TranscriptUpdate] {
        var updates: [TranscriptUpdate] = []
        for try await result in transcriber.results where result.isFinal {
            if let update = ResultMapper.update(from: result, channel: channel, localeID: localeID) {
                updates.append(update)
            }
        }
        return updates
    }

    /// Splits samples into 1 s buffers in the analyzer format; the first carries the start time.
    static func analyzerInputs(
        samples: [Float], sampleRate: Double, analyzerFormat: AVAudioFormat, timeOffset: TimeInterval
    ) throws -> [AnalyzerInput] {
        guard sampleRate > 0 else { throw TranscriptionError.audioConversionFailed("invalid sample rate \(sampleRate)") }
        let converter = try PCMStreamConverter(
            from: PCM.monoFloatFormat(sampleRate: sampleRate), to: analyzerFormat)
        let step = max(Int(sampleRate), 1)
        var buffers: [AVAudioPCMBuffer] = []
        var index = 0
        while index < samples.count {
            let end = min(index + step, samples.count)
            buffers += try converter.convert(
                PCM.monoFloatBuffer(Array(samples[index..<end]), format: converter.inputFormat))
            index = end
        }
        buffers += try converter.flush()
        let start = CMTime(seconds: timeOffset, preferredTimescale: CMTimeScale(analyzerFormat.sampleRate))
        return buffers.enumerated().map { offset, buffer in
            AnalyzerInput(buffer: buffer, bufferStartTime: offset == 0 ? start : nil)
        }
    }
}
