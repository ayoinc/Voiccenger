import Foundation
import VCIntelligence
import VCModels
import VCTranscription

/// What this Mac can run, why the rest can't, and the defaults that follow from it.
///
/// Tiers: every Mac on macOS 14.4+ (Apple silicon or Intel) records, transcribes on-device with Whisper
/// (Cohere on Apple silicon), identifies speakers and writes reports; macOS 26 adds Apple Speech's instant
/// preview; Apple Intelligence (macOS 26, Apple silicon, turned on) adds on-device AI summaries and live
/// insights. Without it, reports come from Claude (own API key) or a transcript outline (no AI).
public struct PlatformCapabilities: Sendable, Hashable, Codable {
    public var machine: MachineInfo
    /// macOS 26's streaming recognizer (instant live preview).
    public var appleSpeechAvailable: Bool
    /// The classic recognizer (`SFSpeechRecognizer`) is the Apple Speech engine here.
    public var classicSpeech: Bool
    /// Classic recognition of this Mac's language runs on the Mac rather than on Apple's servers.
    public var classicOnDevice: Bool
    public var appleIntelligence: AppleIntelligenceStatus
    public var hasClaudeKey: Bool
    public var hasDeepgramKey: Bool

    /// The macOS version this build requires (`LSMinimumSystemVersion`); older Macs can't open it.
    public static let minimumMacOS = "14.4"

    public init(
        machine: MachineInfo, appleSpeechAvailable: Bool, classicSpeech: Bool = false, classicOnDevice: Bool = true,
        appleIntelligence: AppleIntelligenceStatus, hasClaudeKey: Bool, hasDeepgramKey: Bool = false
    ) {
        self.machine = machine
        self.appleSpeechAvailable = appleSpeechAvailable
        self.classicSpeech = classicSpeech
        self.classicOnDevice = classicOnDevice
        self.appleIntelligence = appleIntelligence
        self.hasClaudeKey = hasClaudeKey
        self.hasDeepgramKey = hasDeepgramKey
    }

    public static func current() -> PlatformCapabilities {
        PlatformCapabilities(
            machine: .current, appleSpeechAvailable: AppleSpeech.isAvailable, classicSpeech: AppleSpeech.usesClassic,
            classicOnDevice: ClassicSpeech.isOnDevice(localeID: AppSettings.systemLocaleID),
            appleIntelligence: AppleIntelligenceStatus.current,
            hasClaudeKey: IntelligenceFactory.anthropicAPIKey() != nil,
            hasDeepgramKey: SpeechModelLibrary.shared.isDownloaded(.deepgram))
    }

    // MARK: Defaults

    /// Voice model for new installs: Cohere on Apple silicon (Neural Engine); on Intel, where neither on-device
    /// model runs, Deepgram with a key, else Apple Speech (classic).
    public var defaultSpeechEngine: SpeechEngineKind {
        if let model = EngineSupport.onDeviceModels(machine: machine).first { return model }
        return hasDeepgramKey ? .deepgram : .apple
    }

    /// Report and insight engine: Apple Intelligence when it runs here, else Claude with a key, else the
    /// transcript outline (no AI), which runs everywhere.
    public var defaultIntelligence: IntelligenceEngineKind {
        if appleIntelligence.isAvailable { return .apple }
        return hasClaudeKey ? .claude : .transcriptOutline
    }

    /// `kind` when it runs here, otherwise the default voice model.
    public func usableSpeechEngine(_ kind: SpeechEngineKind) -> SpeechEngineKind {
        speechUnavailableReason(kind) == nil ? kind : defaultSpeechEngine
    }

    /// Short reason a voice model can't run on this Mac ("Needs Apple silicon"), nil when it can.
    public func speechUnavailableReason(_ kind: SpeechEngineKind) -> String? {
        switch kind {
        case .apple:
            return appleSpeechAvailable || classicSpeech ? nil : "Not available on this Mac"
        case .cohere, .whisper, .deepgram:
            return EngineSupport.unsupportedReason(kind, machine: machine)
        }
    }

    /// Short reason an intelligence engine can't run ("Needs Apple silicon", "Add an Anthropic API key"), nil when it can.
    public func intelligenceUnavailableReason(_ kind: IntelligenceEngineKind) -> String? {
        switch kind {
        case .apple: appleIntelligence.shortReason
        case .claude: hasClaudeKey ? nil : "Add an Anthropic API key"
        case .transcriptOutline: nil
        }
    }

    // MARK: Feature table

    public struct Feature: Sendable, Hashable, Codable, Identifiable {
        public var id: String
        public var name: String
        /// What it does on this Mac (available) or what you get instead (unavailable).
        public var detail: String
        public var isAvailable: Bool
        /// Why it's unavailable, e.g. "Needs macOS 26"; nil when available.
        public var reason: String?
    }

    /// One row per feature, in the order the "What this Mac can do" screen shows them.
    public var features: [Feature] {
        let preview = appleSpeechAvailable
            ? "Words appear as they're spoken, then your voice model replaces them with its more accurate text."
            : classicSpeech
                ? "Instead, Apple Speech (classic) shows live text every couple of seconds while someone speaks."
                : "Instead, your voice model shows live text every couple of seconds while someone speaks."
        return [
            Feature(
                id: "recording", name: "Record meetings",
                detail: "Microphone and meeting-app audio (Zoom, Teams, FaceTime, browsers) on separate channels; meetings detected automatically.",
                isAvailable: true),
            Feature(
                id: "cohere", name: "Cohere Transcribe (most accurate on accents)",
                detail: speechUnavailableReason(.cohere) == nil
                    ? "Runs on the Neural Engine. The default voice model."
                    : "Doesn't run on Intel: measured far too slow and garbled.",
                isAvailable: speechUnavailableReason(.cohere) == nil, reason: speechUnavailableReason(.cohere)),
            Feature(
                id: "whisper", name: "Whisper Large v3 Turbo (99 languages)",
                detail: speechUnavailableReason(.whisper) == nil
                    ? "Runs on the Neural Engine and graphics card."
                    : "Doesn't run on Intel: its engine (WhisperKit) crashes in Intel builds.",
                isAvailable: speechUnavailableReason(.whisper) == nil, reason: speechUnavailableReason(.whisper)),
            Feature(
                id: "appleClassic", name: "Apple Speech (classic)",
                detail: classicSpeech
                    ? "Built-in recognizer, nothing to download; less accurate than Cohere or Whisper, especially on accents. "
                        + (classicOnDevice ? "Runs on this Mac." : "For this Mac's language it runs on Apple's servers: audio is sent to Apple.")
                    : "Not needed: macOS 26's Apple Speech is used instead.",
                isAvailable: classicSpeech, reason: classicSpeech ? nil : "Replaced by Apple Speech"),
            Feature(
                id: "applePreview", name: "Instant live text (Apple Speech)",
                detail: preview,
                isAvailable: appleSpeechAvailable, reason: AppleSpeech.unavailableReason),
            Feature(
                id: "deepgram", name: "Deepgram Nova-3 (cloud)",
                detail: "Fastest live text, streamed over the internet. Needs your own Deepgram API key; audio leaves this Mac.",
                isAvailable: true),
            Feature(
                id: "speakers", name: "Who's speaking",
                detail: "Enrolled voices are recognised on this Mac\(machine.isAppleSilicon ? "" : " (on the processor; slower than on Apple silicon)").",
                isAvailable: true),
            Feature(
                id: "appleIntelligence", name: "Apple Intelligence summaries and live insights",
                detail: appleIntelligence.isAvailable
                    ? "Detailed on-device summaries, decisions, action items and corrections; nothing leaves this Mac."
                    : "Instead, use Claude (your Anthropic API key) or the transcript outline.",
                isAvailable: appleIntelligence.isAvailable, reason: appleIntelligence.shortReason),
            Feature(
                id: "claude", name: "Claude summaries and live insights",
                detail: "Detailed reports through Anthropic's API; the transcript is sent to Anthropic.",
                isAvailable: hasClaudeKey, reason: hasClaudeKey ? nil : "Add an Anthropic API key in Settings › Intelligence"),
            Feature(
                id: "outline", name: "Transcript outline (no AI)",
                detail: "A report built on this Mac without a language model: the conversation split into sections, each speaker's key sentences, questions asked and possible action items, all quoted from the transcript.",
                isAvailable: true),
            Feature(
                id: "seat", name: "Seat direction",
                detail: "Where each person sits, with a USB microphone array (ReSpeaker, miniDSP UMA-8).",
                isAvailable: true),
        ]
    }

    /// One line for the top of the capability screen, e.g. "macOS 15.6 · Intel · 16 GB".
    public var summary: String {
        "macOS \(machine.osVersionString) · \(machine.chipDescription) · \(Int(machine.memoryGigabytes.rounded())) GB"
    }

    /// Which of the three tiers this Mac is in.
    public var tierName: String {
        if appleIntelligence.isAvailable { return "Full: on-device voice models, instant live text and Apple Intelligence" }
        if appleSpeechAvailable { return "Standard: on-device voice models and instant live text; reports from Claude or the transcript outline" }
        if EngineSupport.onDeviceModels(machine: machine).isEmpty {
            return "Basic: Apple Speech (classic) or Deepgram with live text every few seconds; reports from Claude or the transcript outline"
        }
        return "Essential: on-device voice models with live text every few seconds; reports from Claude or the transcript outline"
    }
}
