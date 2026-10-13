import Foundation
import VCModels

/// Tunables for `LiveTranscriber`'s automatic language / accent switching.
public struct AutoLanguagePolicy: Sendable, Hashable {
    /// A check is triggered when the word-weighted mean confidence of recent finals falls below this.
    public var confidenceThreshold: Double = 0.5
    /// Minimum words across the recent finals before their confidence is trusted.
    public var minimumWords: Int = 4
    /// Number of most recent final results considered.
    public var recentFinalCount: Int = 3
    /// The winning locale must beat the current locale's score by at least this much.
    public var minimumImprovement: Double = 0.1
    /// Minimum session-clock seconds between two checks (each check transcribes the buffer once per candidate).
    public var checkInterval: TimeInterval = 20
    /// Length of the rolling audio buffer that candidates are scored on.
    public var bufferSeconds: TimeInterval = 10
    /// Don't check with less buffered audio than this.
    public var minimumBufferSeconds: TimeInterval = 3
    /// Upper bound on candidates per check, for cost.
    public var maximumCandidates: Int = 6

    public init() {}
}

/// Tracks recent final-result confidence and decides when a language check is due. Pure value type.
struct ConfidenceMonitor: Sendable {
    let policy: AutoLanguagePolicy
    private var recent: [(sum: Double, words: Int)] = []
    private var lastCheckTime: TimeInterval?

    init(policy: AutoLanguagePolicy) {
        self.policy = policy
    }

    /// Records a final result's word confidences.
    mutating func record(_ update: TranscriptUpdate) {
        let confidences = update.words.compactMap(\.confidence)
        guard !confidences.isEmpty else { return }
        recent.append((confidences.reduce(0, +), confidences.count))
        let keep = max(policy.recentFinalCount, 1)
        if recent.count > keep { recent.removeFirst(recent.count - keep) }
    }

    var wordCount: Int { recent.reduce(0) { $0 + $1.words } }

    /// Word-weighted mean confidence over the recent finals; nil before any confident words arrive.
    var meanConfidence: Double? {
        let words = wordCount
        guard words > 0 else { return nil }
        return recent.reduce(0) { $0 + $1.sum } / Double(words)
    }

    /// True when confidence is low enough, enough words were heard and the rate limit allows a check.
    /// Marks the check as performed at `time` (session clock).
    mutating func shouldCheck(at time: TimeInterval) -> Bool {
        guard wordCount >= policy.minimumWords, let mean = meanConfidence, mean < policy.confidenceThreshold
        else { return false }
        if let last = lastCheckTime, time - last < policy.checkInterval { return false }
        lastCheckTime = time
        return true
    }

    /// Forget confidence history (after the locale changed); the rate limit keeps running.
    mutating func resetHistory() {
        recent.removeAll()
    }
}

/// Fixed-capacity ring buffer of the most recent 16 kHz samples.
struct RollingAudioBuffer: Sendable {
    let capacity: Int
    private var storage: [Float]
    private var writeIndex = 0
    private(set) var count = 0

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
        storage = [Float](repeating: 0, count: self.capacity)
    }

    mutating func append(_ samples: [Float]) {
        if samples.count >= capacity {
            storage = Array(samples.suffix(capacity))
            writeIndex = 0
            count = capacity
            return
        }
        let firstPart = min(samples.count, capacity - writeIndex)
        storage.replaceSubrange(writeIndex..<(writeIndex + firstPart), with: samples[0..<firstPart])
        let rest = samples.count - firstPart
        if rest > 0 { storage.replaceSubrange(0..<rest, with: samples[firstPart...]) }
        writeIndex = (writeIndex + samples.count) % capacity
        count = min(capacity, count + samples.count)
    }

    /// Oldest-to-newest copy of the buffered samples.
    func snapshot() -> [Float] {
        guard count == capacity else { return Array(storage[0..<count]) }
        return Array(storage[writeIndex...] + storage[..<writeIndex])
    }

    mutating func removeAll() {
        writeIndex = 0
        count = 0
    }
}

enum CandidateSelection {
    /// Candidate locales for a language check, current locale first, at most `limit`.
    /// With explicit candidates, those are used (deduplicated). Otherwise: one representative per other
    /// installed language family (its default region, e.g. fr → fr-FR, when installed), then installed
    /// regional variants of the current language (accents). Only installed locales are offered because
    /// scoring an uninstalled locale would require downloading its model mid-meeting.
    static func candidates(
        current: String, explicit: [String], installed: [String], limit: Int
    ) -> [String] {
        let limit = max(limit, 1)
        var result = [current]
        func add(_ id: String) {
            if result.count < limit, !result.contains(id) { result.append(id) }
        }
        if !explicit.isEmpty {
            explicit.forEach(add)
            return result
        }
        let currentLanguage = languageCode(current)
        let installedSorted = installed.sorted()
        var families: [String: [String]] = [:]
        for id in installedSorted {
            families[languageCode(id), default: []].append(id)
        }
        for language in families.keys.sorted() where language != currentLanguage {
            let members = families[language] ?? []
            let preferredRegion = defaultRegion(language)
            let representative =
                members.first { regionCode($0) == preferredRegion } ?? members.first
            if let representative { add(representative) }
        }
        for id in families[currentLanguage] ?? [] { add(id) }
        return result
    }

    static func languageCode(_ id: String) -> String {
        Locale(identifier: id).language.languageCode?.identifier ?? id
    }

    static func regionCode(_ id: String) -> String? {
        Locale(identifier: id).region?.identifier
    }

    /// Likely region for a bare language ("fr" → "FR", "pt" → "BR"), via CLDR likely subtags.
    static func defaultRegion(_ language: String) -> String? {
        Locale.Language(identifier: language).maximalIdentifier
            .split(separator: "-").last { $0.count == 2 && $0.uppercased() == $0 }
            .map(String.init)
    }
}
