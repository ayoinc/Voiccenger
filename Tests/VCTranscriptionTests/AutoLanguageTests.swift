import Foundation
import Testing
import VCModels
@testable import VCTranscription

/// `shouldCheck` is mutating (it records the check time), which `#expect` cannot evaluate in place.
private func expectCheck(
    _ monitor: inout ConfidenceMonitor, at time: TimeInterval, _ expected: Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let result = monitor.shouldCheck(at: time)
    #expect(result == expected, "shouldCheck(at: \(time))", sourceLocation: sourceLocation)
}

@Suite struct ConfidenceMonitorTests {
    private func final(confidences: [Double], end: TimeInterval = 0) -> TranscriptUpdate {
        let words = confidences.enumerated().map { index, confidence in
            TimedWord(
                text: "w\(index)", range: TimeRange(start: end - 0.1, end: end), confidence: confidence)
        }
        return TranscriptUpdate(
            channel: .microphone, text: words.map(\.text).joined(separator: " "),
            range: TimeRange(start: end - 1, end: end), confidence: nil, localeID: "en-GB", words: words)
    }

    @Test func lowConfidenceNeedsEnoughWordsBeforeTriggering() {
        var monitor = ConfidenceMonitor(policy: AutoLanguagePolicy())
        monitor.record(final(confidences: [0.2, 0.3, 0.2]))
        expectCheck(&monitor, at: 1, false)
        monitor.record(final(confidences: [0.3]))
        expectCheck(&monitor, at: 2, true)
    }

    @Test func confidentSpeechNeverTriggers() {
        var monitor = ConfidenceMonitor(policy: AutoLanguagePolicy())
        for i in 0..<10 { monitor.record(final(confidences: [0.9, 0.95, 0.85, 0.9], end: Double(i))) }
        expectCheck(&monitor, at: 100, false)
    }

    @Test func thresholdIsWordWeightedAcrossRecentFinals() {
        var monitor = ConfidenceMonitor(policy: AutoLanguagePolicy())
        // One long confident final outweighs a short unconfident one: (6×0.8 + 2×0.1) / 8 = 0.625.
        monitor.record(final(confidences: Array(repeating: 0.8, count: 6)))
        monitor.record(final(confidences: [0.1, 0.1]))
        #expect(abs(monitor.meanConfidence! - 0.625) < 1e-9)
        expectCheck(&monitor, at: 5, false)
    }

    @Test func onlyTheMostRecentFinalsCount() {
        var policy = AutoLanguagePolicy()
        policy.recentFinalCount = 2
        var monitor = ConfidenceMonitor(policy: policy)
        monitor.record(final(confidences: [0.95, 0.95, 0.95, 0.95, 0.95, 0.95]))
        monitor.record(final(confidences: [0.2, 0.2]))
        monitor.record(final(confidences: [0.3, 0.3]))
        #expect(monitor.wordCount == 4)
        #expect(abs(monitor.meanConfidence! - 0.25) < 1e-9)
        expectCheck(&monitor, at: 1, true)
    }

    @Test func checksAreRateLimitedOnTheSessionClock() {
        var monitor = ConfidenceMonitor(policy: AutoLanguagePolicy())
        monitor.record(final(confidences: [0.2, 0.2, 0.2, 0.2]))
        expectCheck(&monitor, at: 10, true)
        expectCheck(&monitor, at: 29.9, false)
        expectCheck(&monitor, at: 30, true)
    }

    @Test func historyResetAfterSwitchKeepsRateLimit() {
        var monitor = ConfidenceMonitor(policy: AutoLanguagePolicy())
        monitor.record(final(confidences: [0.2, 0.2, 0.2, 0.2]))
        expectCheck(&monitor, at: 10, true)
        monitor.resetHistory()
        #expect(monitor.meanConfidence == nil)
        monitor.record(final(confidences: [0.1, 0.1, 0.1, 0.1]))
        expectCheck(&monitor, at: 15, false)
        expectCheck(&monitor, at: 31, true)
    }

    @Test func wordsWithoutConfidenceAreIgnored() {
        var monitor = ConfidenceMonitor(policy: AutoLanguagePolicy())
        let words = (0..<8).map { TimedWord(text: "w\($0)", range: TimeRange(start: 0, end: 0.1)) }
        monitor.record(
            TranscriptUpdate(
                channel: .system, text: "", range: TimeRange(start: 0, end: 1), confidence: nil,
                localeID: "en-GB", words: words))
        #expect(monitor.wordCount == 0)
        expectCheck(&monitor, at: 1, false)
    }
}

@Suite struct CandidateSelectionTests {
    private let installed = [
        "en-AU", "en-CA", "en-GB", "en-IE", "en-IN", "en-NZ", "en-SG", "en-US", "en-ZA",
        "fr-BE", "fr-CA", "fr-CH", "fr-FR", "de-AT", "de-DE",
    ]

    @Test func explicitCandidatesAreUsedInOrderAfterCurrentWithoutDuplicates() {
        let result = CandidateSelection.candidates(
            current: "en-GB", explicit: ["fr-FR", "en-GB", "en-US", "fr-FR"], installed: installed, limit: 6)
        #expect(result == ["en-GB", "fr-FR", "en-US"])
    }

    @Test func derivedCandidatesCoverOtherLanguagesFirstThenAccents() {
        let result = CandidateSelection.candidates(current: "en-GB", explicit: [], installed: installed, limit: 6)
        #expect(result.count == 6)
        #expect(result.first == "en-GB")
        // One representative per other language family, at its likely region.
        #expect(result[1] == "de-DE")
        #expect(result[2] == "fr-FR")
        #expect(result.filter { $0.hasPrefix("fr") }.count == 1)
        #expect(result.dropFirst(3).allSatisfy { $0.hasPrefix("en-") })
    }

    @Test func limitIsAlwaysRespectedAndCurrentIsKept() {
        for limit in [0, 1, 2, 3] {
            let result = CandidateSelection.candidates(
                current: "fr-CA", explicit: [], installed: installed, limit: limit)
            #expect(result.count == max(limit, 1))
            #expect(result.first == "fr-CA")
        }
    }

    @Test func singleInstalledLanguageYieldsItsAccents() {
        let result = CandidateSelection.candidates(
            current: "en-US", explicit: [], installed: ["en-US", "en-GB", "en-IN"], limit: 6)
        #expect(Set(result) == ["en-US", "en-GB", "en-IN"])
        #expect(result.first == "en-US")
    }

    @Test func likelyRegionComesFromCLDR() {
        #expect(CandidateSelection.defaultRegion("fr") == "FR")
        #expect(CandidateSelection.defaultRegion("pt") == "BR")
        #expect(CandidateSelection.defaultRegion("en") == "US")
    }
}

@Suite struct LocaleDecisionTests {
    private func score(_ id: String, _ confidence: Double, words: Int = 10) -> LocaleScore {
        LocaleScore(localeID: id, meanConfidence: confidence, wordCount: words, transcript: "")
    }

    @Test func switchesWhenWinnerBeatsCurrentByTheMargin() {
        let decision = LiveTranscriber.decide(
            scores: [score("fr-FR", 0.92), score("en-GB", 0.41)], current: "en-GB", observed: 0.4,
            policy: AutoLanguagePolicy())
        #expect(decision?.localeID == "fr-FR")
        #expect(decision?.reason.contains("fr-FR") == true)
    }

    @Test func smallAccentDifferencesDoNotCauseFlapping() {
        let decision = LiveTranscriber.decide(
            scores: [score("en-US", 0.47), score("en-GB", 0.45)], current: "en-GB", observed: 0.3,
            policy: AutoLanguagePolicy())
        #expect(decision == nil)
    }

    @Test func currentLocaleWinningKeepsIt() {
        let decision = LiveTranscriber.decide(
            scores: [score("en-GB", 0.6), score("fr-FR", 0.2)], current: "en-GB", observed: 0.45,
            policy: AutoLanguagePolicy())
        #expect(decision == nil)
    }

    @Test func observedConfidenceIsTheBaselineWhenCurrentWasNotScored() {
        let policy = AutoLanguagePolicy()
        #expect(
            LiveTranscriber.decide(scores: [score("fr-FR", 0.55)], current: "en-GB", observed: 0.4, policy: policy)?
                .localeID == "fr-FR")
        #expect(
            LiveTranscriber.decide(scores: [score("fr-FR", 0.45)], current: "en-GB", observed: 0.4, policy: policy)
                == nil)
    }

    @Test func winnerThatHeardNothingIsRejected() {
        let decision = LiveTranscriber.decide(
            scores: [score("fr-FR", 0.9, words: 0)], current: "en-GB", observed: 0.1, policy: AutoLanguagePolicy())
        #expect(decision == nil)
    }

    @Test func scoreIsWordWeightedAcrossFinalsAndZeroWhenNothingRecognised() {
        func update(_ confidences: [Double?]) -> TranscriptUpdate {
            TranscriptUpdate(
                channel: .microphone, text: "x", range: TimeRange(start: 0, end: 1), confidence: nil,
                localeID: "fr-FR",
                words: confidences.map { TimedWord(text: "x", range: TimeRange(start: 0, end: 1), confidence: $0) })
        }
        let s = AccentDetector.score(localeID: "fr-FR", updates: [update([1, 1, 1]), update([0.2, nil])])
        #expect(abs(s.meanConfidence - 3.2 / 4) < 1e-9)
        #expect(s.wordCount == 5)
        #expect(AccentDetector.score(localeID: "fr-FR", updates: []).meanConfidence == 0)
    }

    @Test func rankingOrdersByConfidenceThenWordsThenIdentifier() {
        let sorted = AccentDetector.sorted([
            score("b", 0.5, words: 3), score("a", 0.5, words: 3), score("c", 0.5, words: 9), score("d", 0.9),
        ])
        #expect(sorted.map(\.localeID) == ["d", "c", "a", "b"])
    }
}
