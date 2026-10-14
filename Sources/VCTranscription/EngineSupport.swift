import Foundation
import VCModels

/// Which voice models can run on a given Mac, and which on-device model stands in for one that can't.
public enum EngineSupport {
    /// Why `kind` can't run on `machine`, nil when it can. Apple Speech runs everywhere: macOS 26's
    /// `SpeechTranscriber` where it exists, the classic `SFSpeechRecognizer` elsewhere.
    public static func unsupportedReason(_ kind: SpeechEngineKind, machine: MachineInfo = .current) -> String? {
        switch kind {
        case .apple:
            guard machine == .current else { return nil }
            return AppleSpeech.engineAvailable ? nil : "Not available on this Mac"
        case .cohere, .whisper:
            // Neither runs as an x86_64 (Intel) build. Cohere, measured under Rosetta: 75 s to load, 272 s for a
            // 48 s meeting and garbled text (91.6% word errors). Whisper: WhisperKit (argmax-oss-swift 1.1.1) fills
            // its float16 Core ML buffers through `FloatType`, which is 4-byte `Float` on x86_64, and crashes
            // writing past them before the first transcription.
            return machine.processArchitecture == "arm64" ? nil : "Needs Apple silicon"
        case .deepgram:
            return nil
        }
    }

    public static func isSupported(_ kind: SpeechEngineKind, machine: MachineInfo = .current) -> Bool {
        unsupportedReason(kind, machine: machine) == nil
    }

    /// On-device models in order of preference: Cohere is the most accurate on accents, then Whisper.
    public static func onDeviceModels(machine: MachineInfo = .current) -> [SpeechEngineKind] {
        [.cohere, .whisper].filter { isSupported($0, machine: machine) }
    }

    /// The engine a new install starts with on `machine`: the best on-device model, else (Intel) Apple Speech.
    /// `PlatformCapabilities` prefers Deepgram over Apple Speech when a Deepgram key exists.
    public static func defaultEngine(machine: MachineInfo = .current) -> SpeechEngineKind {
        onDeviceModels(machine: machine).first ?? .apple
    }
}

extension SpeechModelLibrary {
    /// The on-device model that makes the live preview where Apple Speech is unavailable: `preferred` when it's
    /// an on-device model that's downloaded (or nothing better is); otherwise the first downloaded model that
    /// speaks `languageCode`, then any downloaded model, then the platform default (finals load it once it's
    /// downloaded).
    public nonisolated func previewEngine(preferring preferred: SpeechEngineKind, languageCode: String) -> SpeechEngineKind {
        let models = EngineSupport.onDeviceModels().filter { EngineSupport.isSupported($0) }
        if models.contains(preferred), isDownloaded(preferred) { return preferred }
        let downloaded = models.filter { isDownloaded($0) }
        let language = baseLanguageCode(languageCode)
        if let match = downloaded.first(where: { Self.info($0).languageCodes.contains(language) }) { return match }
        if let any = downloaded.first { return any }
        return models.contains(preferred) ? preferred : EngineSupport.defaultEngine()
    }
}
