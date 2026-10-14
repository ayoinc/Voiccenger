import Foundation
import VCModels
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether this Mac can run the on-device Apple Intelligence engine, and why not. Safe to query on any macOS.
public enum AppleIntelligenceStatus: String, Sendable, Hashable, Codable {
    case available
    /// Foundation Models first shipped in macOS 26.
    case needsNewerMacOS
    /// Intel Macs (and Apple silicon Macs Apple doesn't support) can't run Apple Intelligence.
    case needsAppleSilicon
    case deviceNotEligible
    case notEnabled
    case modelNotReady
    case unavailable

    public static var current: AppleIntelligenceStatus { status(machine: .current) }

    static func status(machine: MachineInfo) -> AppleIntelligenceStatus {
        guard machine.osAtLeast(26) else { return machine.isAppleSilicon ? .needsNewerMacOS : .needsAppleSilicon }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(.deviceNotEligible):
                return machine.isAppleSilicon ? .deviceNotEligible : .needsAppleSilicon
            case .unavailable(.appleIntelligenceNotEnabled):
                return .notEnabled
            case .unavailable(.modelNotReady):
                return .modelNotReady
            case .unavailable:
                return .unavailable
            }
        }
        #endif
        return .needsNewerMacOS
    }

    /// True when this Mac can never run Apple Intelligence as it stands (old macOS, Intel, ineligible);
    /// false when it's only switched off or still preparing.
    public var isPermanentlyUnavailable: Bool {
        switch self {
        case .needsNewerMacOS, .needsAppleSilicon, .deviceNotEligible: true
        case .available, .notEnabled, .modelNotReady, .unavailable: false
        }
    }

    public var isAvailable: Bool { self == .available }

    /// Short label for settings rows and the capability table.
    public var shortReason: String? {
        switch self {
        case .available: nil
        case .needsNewerMacOS: "Needs macOS 26"
        case .needsAppleSilicon: "Needs Apple silicon"
        case .deviceNotEligible: "Not supported on this Mac"
        case .notEnabled: "Turn on Apple Intelligence in System Settings"
        case .modelNotReady: "Model still downloading"
        case .unavailable: "Not available right now"
        }
    }

    /// Full sentence explaining why the engine can't run.
    public var reason: String? {
        switch self {
        case .available:
            nil
        case .needsNewerMacOS:
            "Apple Intelligence needs macOS 26 or later on Apple silicon."
        case .needsAppleSilicon:
            "Apple Intelligence needs a Mac with Apple silicon; this Mac has an Intel processor."
        case .deviceNotEligible:
            "This Mac does not support Apple Intelligence."
        case .notEnabled:
            "Apple Intelligence is turned off. Turn it on in System Settings › Apple Intelligence & Siri."
        case .modelNotReady:
            "The Apple Intelligence model is still downloading or preparing. Try again later."
        case .unavailable:
            "Apple Intelligence is not available right now."
        }
    }
}
