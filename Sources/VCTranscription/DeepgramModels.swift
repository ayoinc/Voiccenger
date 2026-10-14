import Foundation
import VCModels

/// One Deepgram speech-to-text model the user's key can use, merged across the versions and languages Deepgram
/// lists for it. Streaming and pre-recorded support is per language: a model can stream English but only
/// transcribe recordings in Galician.
public struct DeepgramModel: Codable, Sendable, Hashable, Identifiable {
    /// Deepgram's `canonical_name`, sent as `model=`: "nova-3-general", "nova-2-meeting", "whisper-large".
    public var name: String
    /// "nova-3", "nova-2", "polaris" (Enhanced), "base", "whisper"…
    public var architecture: String
    /// Newest version Deepgram lists.
    public var version: String
    /// Language codes Deepgram streams live, as it lists them (regional variants included); "multi" when it
    /// streams code-switched speech.
    public var streamingLanguages: [String]
    /// Language codes Deepgram transcribes in recordings (pre-recorded API), as above.
    public var batchLanguages: [String]

    public init(name: String, architecture: String, version: String, streamingLanguages: [String], batchLanguages: [String]) {
        self.name = name
        self.architecture = architecture
        self.version = version
        self.streamingLanguages = streamingLanguages
        self.batchLanguages = batchLanguages
    }

    public var id: String { name }

    public var displayName: String {
        let name = Deepgram.modelDisplayName(self.name)
        return architecture == "base" ? "Base \(name)" : name
    }

    /// "Nova-3", "Nova-2", "Nova", "Enhanced", "Whisper", "Base" or "Other": how pickers group models, newest first.
    public var family: String { Self.families[familyRank] }

    /// Every `family`, in catalog order.
    public static let families = ["Nova-3", "Nova-2", "Nova", "Enhanced", "Whisper", "Base", "Other"]

    var familyRank: Int {
        if name.hasPrefix("nova-3") { return 0 }
        if name.hasPrefix("nova-2") { return 1 }
        if name.hasPrefix("nova") { return 2 }
        if architecture == "polaris" || name.hasPrefix("enhanced") { return 3 }
        if name.hasPrefix("whisper") { return 4 }
        if architecture == "base" { return 5 }
        return 6
    }

    /// False when no language streams: the model only transcribes recordings (files, calibration, re-transcribed lines).
    public var canStream: Bool { !streamingLanguages.isEmpty }

    /// ISO 639-1 codes (plus "multi") the model transcribes either way, sorted.
    public var languageCodes: [String] { Self.bases(streamingLanguages + batchLanguages) }
    public var streamingLanguageCodes: [String] { Self.bases(streamingLanguages) }
    public var batchLanguageCodes: [String] { Self.bases(batchLanguages) }

    /// Whether the model transcribes `languageCode` ("en-GB", "en", "multi"): live when `live`, else in recordings.
    public func transcribes(_ languageCode: String, live: Bool) -> Bool {
        requestLanguage(languageCode, live: live) != nil
    }

    /// Whether the model transcribes `languageCode` live or in recordings.
    public func transcribes(_ languageCode: String) -> Bool {
        transcribes(languageCode, live: true) || transcribes(languageCode, live: false)
    }

    /// The `language` value to send: the base code when listed ("en-GB" → "en"), else the code itself, else
    /// the first listed variant of its language; nil when the model doesn't transcribe it that way.
    func requestLanguage(_ languageCode: String, live: Bool) -> String? {
        let listed = live ? streamingLanguages : batchLanguages
        let base = Deepgram.normalizedLanguage(languageCode)
        if let exact = listed.first(where: { $0.lowercased() == base }) { return exact }
        if let exact = listed.first(where: { $0.caseInsensitiveCompare(languageCode) == .orderedSame }) { return exact }
        return listed.first { Deepgram.normalizedLanguage($0) == base }
    }

    private static func bases(_ codes: [String]) -> [String] {
        Array(Set(codes.map(Deepgram.normalizedLanguage))).sorted()
    }
}

/// The Deepgram models a key can use, as fetched from Deepgram, with when and where from.
public struct DeepgramModelCatalog: Codable, Sendable, Hashable {
    public enum Source: String, Codable, Sendable {
        /// `GET /v1/projects/{id}/models`: the models the key's project can use.
        case project
        /// `GET /v1/models`: Deepgram's public list, used when the key can't read its project's models.
        case publicList
    }

    /// Speech-to-text models, newest families first (Nova-3, Nova-2, Nova, Enhanced, Whisper, Base).
    public var models: [DeepgramModel]
    public var fetchedAt: Date
    public var source: Source

    public init(models: [DeepgramModel], fetchedAt: Date, source: Source) {
        self.models = models
        self.fetchedAt = fetchedAt
        self.source = source
    }

    /// The model named `name`; a family name alone means its general model ("nova-3" → "nova-3-general").
    public func model(named name: String) -> DeepgramModel? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return models.first { $0.name == name } ?? models.first { $0.name == "\(name)-general" }
    }

    /// Models that transcribe `languageCode`: live when `live` is true, in recordings when false, either when nil.
    public func models(transcribing languageCode: String, live: Bool? = nil) -> [DeepgramModel] {
        models.filter { model in live.map { model.transcribes(languageCode, live: $0) } ?? model.transcribes(languageCode) }
    }

    /// Decodes a `{"stt": [...], "tts": [...]}` models response: speech-to-text only, one model per
    /// `canonical_name`. Deepgram's internal test models (mixed-case names) and its phoneme model (which writes
    /// phonemes, not words) are left out. Entries flagged `multilingual` add "multi".
    static func decode(_ data: Data, source: Source, fetchedAt: Date) throws -> DeepgramModelCatalog {
        struct Response: Decodable {
            let stt: [Entry]?
        }
        struct Entry: Decodable {
            let canonicalName: String?
            let name: String?
            let architecture: String?
            let languages: [String]?
            let version: String?
            let batch: Bool?
            let streaming: Bool?
            let multilingual: Bool?

            enum CodingKeys: String, CodingKey {
                case name, architecture, languages, version, batch, streaming, multilingual
                case canonicalName = "canonical_name"
            }
        }
        struct Group {
            var architecture = ""
            var version = ""
            var streaming: Set<String> = []
            var batch: Set<String> = []
        }
        let entries = try JSONDecoder().decode(Response.self, from: data).stt ?? []
        var groups: [String: Group] = [:]
        for entry in entries {
            guard let name = entry.canonicalName ?? entry.name, !name.isEmpty, name == name.lowercased(),
                !excludedModels.contains(name)
            else { continue }
            var languages = Set(entry.languages ?? [])
            if entry.multilingual == true { languages.insert("multi") }
            var group = groups[name] ?? Group()
            if let version = entry.version, version > group.version {
                group.version = version
                group.architecture = entry.architecture ?? group.architecture
            } else if group.architecture.isEmpty {
                group.architecture = entry.architecture ?? ""
            }
            if entry.streaming == true { group.streaming.formUnion(languages) }
            if entry.batch == true { group.batch.formUnion(languages) }
            groups[name] = group
        }
        let models = groups.map { name, group in
            DeepgramModel(
                name: name, architecture: group.architecture, version: group.version,
                streamingLanguages: group.streaming.sorted(), batchLanguages: group.batch.sorted())
        }
        .filter { !($0.streamingLanguages.isEmpty && $0.batchLanguages.isEmpty) }
        .sorted { lhs, rhs in
            let (l, r) = (lhs.familyRank, rhs.familyRank)
            if l != r { return l < r }
            let (lg, rg) = (lhs.name.hasSuffix("general"), rhs.name.hasSuffix("general"))
            if lg != rg { return lg }
            return lhs.name < rhs.name
        }
        return DeepgramModelCatalog(models: models, fetchedAt: fetchedAt, source: source)
    }

    static let excludedModels: Set<String> = ["phoneme"]
}

extension Deepgram {
    /// The model used unless the user picks another: Nova-3's general model (`model=nova-3`).
    public static let defaultModel = "nova-3"

    /// True for the default model under either of its names ("nova-3", "nova-3-general") or no name.
    public static func isDefaultModel(_ name: String?) -> Bool {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !name.isEmpty else { return true }
        return name == defaultModel || name == "\(defaultModel)-general"
    }

    /// Whether two model names mean the same model (nil = the default).
    public static func sameModel(_ a: String?, _ b: String?) -> Bool {
        if isDefaultModel(a) || isDefaultModel(b) { return isDefaultModel(a) && isDefaultModel(b) }
        return a?.lowercased() == b?.lowercased()
    }

    /// "nova-3-general" → "Nova-3 General", "nova-2-conversationalai" → "Nova-2 Conversational AI",
    /// "whisper-large" → "Whisper Large", "nova-3" → "Nova-3".
    public static func modelDisplayName(_ name: String) -> String {
        let words: [String: String] = [
            "conversationalai": "Conversational AI", "drivethru": "Drive-thru", "atc": "ATC", "ea": "Early Access",
            "phonecall": "Phone Call",
        ]
        var parts: [String] = []
        for token in name.lowercased().split(separator: "-").map(String.init) {
            if let last = parts.last, last == "Nova", token.allSatisfy(\.isNumber) {
                parts[parts.count - 1] = "\(last)-\(token)"
            } else {
                parts.append(words[token] ?? token.prefix(1).uppercased() + token.dropFirst())
            }
        }
        return parts.joined(separator: " ")
    }

    /// ISO 639-1 base of a Deepgram language ("en-GB" → "en", "nb"/"nn" → "no"); "multi" stays.
    static func normalizedLanguage(_ code: String) -> String {
        let base = baseLanguageCode(code)
        return base == "nb" || base == "nn" ? "no" : base
    }

    /// The model and `language` a request uses, and why the requested model isn't used when it isn't.
    public struct ModelChoice: Sendable, Equatable {
        /// Sent as `model=`.
        public var model: String
        /// Sent as `language=`; nil when the model used doesn't transcribe the language at all.
        public var language: String?
        /// Set when the requested model was replaced by Nova-3, e.g. "Nova-2 Meeting doesn't transcribe Swahili,
        /// so Nova-3 is used instead".
        public var fallbackReason: String?

        public init(model: String, language: String?, fallbackReason: String? = nil) {
            self.model = model
            self.language = language
            self.fallbackReason = fallbackReason
        }

        public var usesDefaultModel: Bool { Deepgram.isDefaultModel(model) }
    }

    /// Decides which model transcribes `languageCode`, live (`live`) or a recording. The default model uses
    /// Nova-3's languages (`requestLanguage`). Another model is checked against `catalog`: when the key can't
    /// use it, or it doesn't transcribe the language that way, Nova-3 is used instead with a reason. Without
    /// a catalog the requested model is trusted (Deepgram rejects what it can't do).
    public static func chooseModel(
        _ requested: String?, languageCode: String, live: Bool, catalog: DeepgramModelCatalog?
    ) -> ModelChoice {
        let nova3 = ModelChoice(model: defaultModel, language: requestLanguage(languageCode))
        guard let requested = requested?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !isDefaultModel(requested)
        else { return nova3 }
        guard let catalog else {
            return ModelChoice(model: requested, language: normalizedLanguage(languageCode))
        }
        func fallback(_ reason: String) -> ModelChoice {
            var choice = nova3
            choice.fallbackReason = "\(reason), so Nova-3 is used instead"
            return choice
        }
        guard let model = catalog.model(named: requested) else {
            return fallback("\(modelDisplayName(requested)) isn't available to this Deepgram key")
        }
        if let language = model.requestLanguage(languageCode, live: live) {
            return ModelChoice(model: model.name, language: language)
        }
        let languageName = languageDisplayName(languageCode)
        if model.transcribes(languageCode) {
            return fallback(
                live
                    ? "\(model.displayName) can't stream \(languageName) live"
                    : "\(model.displayName) can't transcribe \(languageName) recordings")
        }
        return fallback("\(model.displayName) doesn't transcribe \(languageName)")
    }

    /// "English", "Swahili", "several languages" (multi).
    public static func languageDisplayName(_ code: String) -> String {
        let base = normalizedLanguage(code)
        if base == "multi" { return "several languages" }
        return Locale(identifier: "en").localizedString(forLanguageCode: base) ?? code
    }
}
