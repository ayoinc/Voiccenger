import Foundation
import VCModels
import VCSpeakers
import VCTranscription

/// Where a segment should be re-transcribed: by another engine and/or in the speaker's own language.
public struct EngineRoute: Sendable, Hashable {
    public var engine: SpeechEngineKind
    public var languageCode: String

    public init(engine: SpeechEngineKind, languageCode: String) {
        self.engine = engine
        self.languageCode = languageCode
    }
}

/// Per-speaker voice decisions for one meeting: the recognition prompt, text customization of each line,
/// and which engine (and language) an enrolled speaker's lines should be transcribed with.
public struct SessionVoices: Sendable {
    public let contextualStrings: [String]
    /// Spelling for speakers without a preference of their own.
    public let sessionSpelling: SpellingVariant
    public private(set) var profiles: [UUID: SpeakerProfile]
    /// Names, terms and places the engines are biased toward.
    public private(set) var prompt: [String]

    public init(profiles: [SpeakerProfile], contextualStrings: [String], sessionSpelling: SpellingVariant) {
        self.contextualStrings = contextualStrings
        self.sessionSpelling = sessionSpelling
        self.profiles = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        self.prompt = Self.prompt(contextualStrings: contextualStrings, profiles: profiles)
    }

    /// Adds or replaces a profile (a voice enrolled during the meeting).
    public mutating func upsert(_ profile: SpeakerProfile) {
        profiles[profile.id] = profile
        prompt = Self.prompt(contextualStrings: contextualStrings, profiles: Array(profiles.values).sorted { $0.createdAt < $1.createdAt })
    }

    public func profile(forSpeakerKey key: String) -> SpeakerProfile? {
        ParticipantRoster.profileID(fromKey: key).flatMap { profiles[$0] }
    }

    // MARK: - Prompt

    /// Session vocabulary, then each person's name and vocabulary, then common names and places of their
    /// accent and home regions (when they opted in). Case-insensitive duplicates and blanks are dropped; the
    /// most specific terms come first because engines may truncate long prompts.
    public static func prompt(contextualStrings: [String], profiles: [SpeakerProfile]) -> [String] {
        var terms = contextualStrings
        terms += profiles.map(\.name)
        terms += profiles.flatMap(\.voice.vocabulary)
        terms += profiles.flatMap { AccentRegions.vocabulary(for: $0.voice) }
        return unique(terms)
    }

    // MARK: - Customization

    /// An enrolled speaker's text gets their replacements, vocabulary and spelling (their spelling falls back
    /// to the session's when unset); anyone else gets the session spelling only.
    public func customize(_ text: String, speakerKey: String) -> String {
        guard let profile = profile(forSpeakerKey: speakerKey) else {
            return TranscriptCustomizer.applySpelling(text, sessionSpelling)
        }
        var settings = profile.voice
        if settings.spelling == .unchanged { settings.spelling = sessionSpelling }
        return TranscriptCustomizer.apply(text, settings: settings, extraVocabulary: Self.unique(contextualStrings + [profile.name]))
    }

    // MARK: - Routing

    /// The engine and language an enrolled speaker's line should be re-transcribed with, or nil to keep it.
    ///
    /// The speaker's engine is their manual choice, else their calibration's best. A line is re-transcribed
    /// when that engine differs from the one that produced it, or when the speaker talks in another language
    /// than the line was recognized in. Only engines in `available` that support the language are used;
    /// for a language change the line's own engine, then Whisper, Cohere and Apple are tried in turn.
    public func route(
        speakerKey: String, segmentEngine: SpeechEngineKind?, segmentLanguage: String,
        available: Set<SpeechEngineKind>
    ) -> EngineRoute? {
        guard let profile = profile(forSpeakerKey: speakerKey) else { return nil }
        let voice = profile.voice
        let current = segmentEngine ?? .apple
        let language = voice.languageCode.isEmpty ? segmentLanguage : voice.languageCode
        let languageDiffers = language != segmentLanguage
        let wanted = voice.preferredEngine ?? voice.calibration?.best?.engine
        guard languageDiffers || (wanted != nil && wanted != current) else { return nil }

        var candidates: [SpeechEngineKind] = wanted.map { [$0] } ?? []
        if languageDiffers { candidates += [current, .whisper, .cohere, .apple] }
        guard
            let engine = candidates.first(where: {
                available.contains($0) && SpeechModelLibrary.info($0).languageCodes.contains(language)
            })
        else { return nil }
        return EngineRoute(engine: engine, languageCode: language)
    }

    /// Whether any enrolled speaker could have lines re-transcribed: they have an engine of their own (manual
    /// or calibrated) or speak another language than the meeting's.
    public func mayReroute(sessionLanguage: String) -> Bool {
        profiles.values.contains { p in
            p.voice.preferredEngine != nil || p.voice.calibration?.best != nil
                || (!p.voice.languageCode.isEmpty && p.voice.languageCode != sessionLanguage)
        }
    }

    /// Engines that can transcribe now or after loading: Apple always, others once downloaded.
    public static func availableEngines(_ statuses: [SpeechEngineKind: ModelStatus]) -> Set<SpeechEngineKind> {
        var available: Set<SpeechEngineKind> = [.apple]
        for (kind, status) in statuses {
            switch status {
            case .downloaded, .loading, .ready: available.insert(kind)
            case .notDownloaded, .downloading, .failed: break
            }
        }
        return available
    }

    /// ISO 639-1 language of a BCP-47 locale ("en-GB" → "en").
    public static func languageCode(ofLocale localeID: String) -> String {
        Locale(identifier: localeID).language.languageCode?.identifier
            ?? String(localeID.prefix { $0 != "-" && $0 != "_" }).lowercased()
    }

    static func unique(_ items: [String]) -> [String] {
        var seen: Set<String> = []
        return items.compactMap { item -> String? in
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return nil }
            return trimmed
        }
    }
}
