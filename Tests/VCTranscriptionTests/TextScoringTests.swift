import Foundation
import Testing
import VCModels
@testable import VCTranscription

@Suite struct WordErrorRateTests {
    @Test func perfectTranscriptScoresZeroDespitePunctuationAndCase() {
        #expect(WordErrorRate.compute(reference: "Please call Stella.", hypothesis: "please, call STELLA") == 0)
    }

    @Test func countsSubstitutionsDeletionsAndInsertionsOverReferenceLength() {
        // 1 substitution (slabs→slaps) + 1 deletion (thick) + 1 insertion (very) over 6 reference words.
        let wer = WordErrorRate.compute(
            reference: "five thick slabs of blue cheese", hypothesis: "five slaps of very blue cheese")
        #expect(abs(wer - 3.0 / 6.0) < 1e-9)
    }

    @Test func hypothesisFarLongerThanReferenceExceedsOne() {
        #expect(WordErrorRate.compute(reference: "yes", hypothesis: "no no no") > 1)
    }

    @Test func emptyReference() {
        #expect(WordErrorRate.compute(reference: "", hypothesis: "") == 0)
        #expect(WordErrorRate.compute(reference: " ", hypothesis: "something") == 1)
    }

    @Test func digitsAreReadAsWords() {
        #expect(WordErrorRate.normalize("6 spoons, 5 slabs and 3 bags") == [
            "six", "spoons", "five", "slabs", "and", "three", "bags",
        ])
        #expect(WordErrorRate.normalize("1,250 people") == ["one", "thousand", "two", "hundred", "fifty", "people"])
        #expect(WordErrorRate.compute(reference: "six spoons", hypothesis: "6 spoons") == 0)
    }

    @Test func apostrophesJoinHyphensSplitDiacriticsFold() {
        #expect(WordErrorRate.normalize("We'll meet Adé’s brother at the snow-pea stand & go")
            == ["well", "meet", "ades", "brother", "at", "the", "snow", "pea", "stand", "and", "go"])
    }
}

@Suite struct TimingTransferTests {
    private func word(_ text: String, _ start: Double, _ end: Double, _ confidence: Double? = 0.9) -> TimedWord {
        TimedWord(text: text, range: TimeRange(start: start, end: end), confidence: confidence)
    }

    @Test func identicalWordsKeepReferenceTimesAndConfidence() {
        let reference = [word("Please", 10, 10.4), word("call", 10.5, 10.8), word("Stella.", 10.9, 11.5)]
        let words = TimingTransfer.align(
            text: "Please call Stella.", reference: reference, range: TimeRange(start: 10, end: 12))
        #expect(words.map(\.text) == ["Please", "call", "Stella."])
        #expect(words.map(\.range) == reference.map(\.range))
        #expect(words.map(\.confidence) == [0.9, 0.9, 0.9])
    }

    @Test func correctedWordTakesTheTimeOfWhatAppleMisheard() {
        // Apple heard "Stellar"; the engine wrote "Stella". The word lands where Apple heard it, without
        // Apple's confidence (the text differs).
        let reference = [word("call", 1, 1.3), word("Stellar", 1.4, 2.0), word("today", 2.1, 2.5)]
        let words = TimingTransfer.align(
            text: "call Stella today", reference: reference, range: TimeRange(start: 1, end: 2.5))
        #expect(words[1].text == "Stella")
        #expect(words[1].range == TimeRange(start: 1.4, end: 2.0))
        #expect(words[1].confidence == nil)
    }

    @Test func extraWordsAreInterpolatedBetweenNeighbours() {
        let reference = [word("ask", 0, 0.3), word("bring", 1.3, 1.6)]
        let words = TimingTransfer.align(
            text: "ask her to bring", reference: reference, range: TimeRange(start: 0, end: 2))
        #expect(words.count == 4)
        #expect(words[1].range.start >= 0.3 && words[2].range.end <= 1.3)
        #expect(words[1].range.duration > 0 && words[2].range.duration > 0)
    }

    @Test func noReferenceSpreadsWordsByLengthAcrossTheRange() {
        let words = TimingTransfer.align(text: "a bbbbbbb", reference: [], range: TimeRange(start: 5, end: 7))
        #expect(words.first?.range.start == 5)
        #expect(words.last?.range.end == 7)
        #expect(words[1].range.duration > 3 * words[0].range.duration)
    }

    @Test func outputIsMonotonicAndInsideTheRangeEvenWithMessyReference() {
        let reference = [
            word("snow", 3.0, 3.4), word("fresh", 2.0, 2.5), word("peas", 3.5, 9.0), word("six", -1, 0.4),
        ]
        let range = TimeRange(start: 0, end: 4)
        let words = TimingTransfer.align(
            text: "Six spoons of fresh snow peas, five thick slabs", reference: reference, range: range)
        #expect(words.count == 9)
        var cursor = range.start
        for w in words {
            #expect(w.range.start >= cursor - 1e-9)
            #expect(w.range.end >= w.range.start)
            #expect(w.range.end <= range.end + 1e-9)
            cursor = w.range.end
        }
    }

    @Test func emptyTextHasNoWords() {
        #expect(TimingTransfer.align(text: "  ", reference: [], range: TimeRange(start: 0, end: 1)).isEmpty)
    }
}
