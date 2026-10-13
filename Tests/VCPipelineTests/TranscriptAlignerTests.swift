import Foundation
import Testing
import VCModels

@testable import VCPipeline

private func r(_ start: Double, _ end: Double) -> TimeRange { TimeRange(start: start, end: end) }

private func turn(_ key: String, _ start: Double, _ end: Double, channel: AudioChannel = .microphone) -> SpeakerTurn {
    SpeakerTurn(channel: channel, range: r(start, end), speakerKey: key, profileID: nil, confidence: 0.9)
}

private func update(
    _ text: String, _ start: Double, _ end: Double, words: [TimedWord] = [], channel: AudioChannel = .microphone
) -> TranscriptUpdate {
    TranscriptUpdate(channel: channel, text: text, range: r(start, end), confidence: 0.8, localeID: "en-GB", words: words)
}

/// Words with consecutive half-second slots starting at `start`.
private func words(_ text: String, from start: Double, step: Double = 0.5) -> [TimedWord] {
    text.split(separator: " ").enumerated().map { i, w in
        TimedWord(text: String(w), range: r(start + Double(i) * step, start + Double(i + 1) * step), confidence: 0.9)
    }
}

@Suite("TranscriptAligner")
struct TranscriptAlignerTests {
    @Test("Words spanning a speaker change split into one piece per speaker, in order")
    func splitsAcrossTwoTurns() {
        // Words occupy 0–3 s; the speaker changes at 1.5 s.
        let u = update("Thanks Daniel. Engineering is on track.", 0, 3, words: words("Thanks Daniel. Engineering is on track.", from: 0))
        let pieces = TranscriptAligner.align(update: u, turns: [turn("mic:1", 0, 1.5), turn("mic:2", 1.5, 4)])

        #expect(pieces.map(\.speakerKey) == ["mic:1", "mic:2"])
        #expect(pieces.map(\.text) == ["Thanks Daniel. Engineering", "is on track."])
        #expect(pieces[0].range == r(0, 1.5))
        #expect(pieces[1].range == r(1.5, 3))
        // Pieces tile the update without overlapping.
        #expect(pieces[0].range.end <= pieces[1].range.start)
    }

    @Test("A word straddling a boundary goes to the turn it overlaps most")
    func straddlingWordUsesMaxOverlap() {
        let ws = [
            TimedWord(text: "alpha", range: r(0, 0.9)),
            TimedWord(text: "beta", range: r(0.9, 1.6)),  // 0.1 s in turn 1, 0.6 s in turn 2
            TimedWord(text: "gamma", range: r(1.6, 2.2)),
        ]
        let pieces = TranscriptAligner.align(update: update("alpha beta gamma", 0, 2.2, words: ws), turns: [turn("a", 0, 1.0), turn("b", 1.0, 3)])
        #expect(pieces.map(\.speakerKey) == ["a", "b"])
        #expect(pieces.map(\.text) == ["alpha", "beta gamma"])
    }

    @Test("Interleaved speakers keep separate pieces even when a speaker returns")
    func speakerReturnsMakesNewPiece() {
        let u = update("one two three four five six", 0, 3, words: words("one two three four five six", from: 0))
        let pieces = TranscriptAligner.align(
            update: u, turns: [turn("a", 0, 1), turn("b", 1, 2), turn("a", 2, 3)])
        #expect(pieces.map(\.speakerKey) == ["a", "b", "a"])
        #expect(pieces.map(\.text) == ["one two", "three four", "five six"])
    }

    @Test("A single-speaker update keeps the recognizer's full formatted text and range")
    func singleSpeakerKeepsText() {
        let u = update("Good morning, everyone!", 0.5, 2.5, words: words("Good morning everyone", from: 0.5))
        let pieces = TranscriptAligner.align(update: u, turns: [turn("mic:1", 0, 5)])
        #expect(pieces.count == 1)
        #expect(pieces[0].text == "Good morning, everyone!")
        #expect(pieces[0].range == r(0.5, 2.5))
        #expect(pieces[0].confidence == 0.8)
    }

    @Test("Without word timings the whole update goes to the turn with the most overlap")
    func noWordsUsesMaxOverlapTurn() {
        let pieces = TranscriptAligner.align(
            update: update("We finished the payment integration.", 4, 8), turns: [turn("a", 0, 5), turn("b", 5, 10)])
        #expect(pieces.count == 1)
        #expect(pieces[0].speakerKey == "b")  // 3 s of overlap vs 1 s
        #expect(pieces[0].text == "We finished the payment integration.")
        #expect(pieces[0].range == r(4, 8))
    }

    @Test("With no overlapping turn, the nearest turn within 1.5 s is used")
    func nearestTurnFallback() {
        let turns = [turn("early", 0, 2), turn("late", 6, 8)]
        // Gap to "early" is 1.0 s, to "late" 3.0 s.
        let pieces = TranscriptAligner.align(update: update("Right.", 3, 5), turns: turns)
        #expect(pieces.map(\.speakerKey) == ["early"])

        let justInside = TranscriptAligner.align(update: update("Okay.", 3.4, 3.6), turns: [turn("a", 0, 2)])
        #expect(justInside.map(\.speakerKey) == ["a"])  // gap 1.4 s
    }

    @Test("Beyond 1.5 s from every turn the speaker is the channel's unknown key")
    func unknownWhenTooFar() {
        let mic = TranscriptAligner.align(update: update("Hello?", 10, 11), turns: [turn("a", 0, 8)])
        #expect(mic.map(\.speakerKey) == ["mic:unknown"])

        let remote = TranscriptAligner.align(update: update("Can you hear me?", 0, 2, channel: .system), turns: [])
        #expect(remote.map(\.speakerKey) == ["sys:unknown"])
    }

    @Test("Turns from the other channel are ignored")
    func otherChannelIgnored() {
        let pieces = TranscriptAligner.align(
            update: update("Remote speaking.", 0, 2, channel: .system), turns: [turn("mic:1", 0, 2, channel: .microphone)])
        #expect(pieces.map(\.speakerKey) == ["sys:unknown"])
    }

    @Test("Words far from any turn become unknown pieces between attributed ones")
    func unknownWordsSplitOut() {
        let ws = [
            TimedWord(text: "first", range: r(0, 1)),
            TimedWord(text: "orphan", range: r(5, 6)),
            TimedWord(text: "last", range: r(10, 11)),
        ]
        let pieces = TranscriptAligner.align(
            update: update("first orphan last", 0, 11, words: ws), turns: [turn("a", 0, 1.5), turn("b", 9.5, 12)])
        #expect(pieces.map(\.speakerKey) == ["a", "mic:unknown", "b"])
    }

    @Test("Blank results produce nothing")
    func blankProducesNothing() {
        #expect(TranscriptAligner.align(update: update("   ", 0, 1), turns: [turn("a", 0, 1)]).isEmpty)
    }

    @Test("Punctuation tokens attach to the preceding word when pieces are re-joined")
    func punctuationJoin() {
        let ws = [
            TimedWord(text: "Yes", range: r(0, 0.4)),
            TimedWord(text: ",", range: r(0.4, 0.45)),
            TimedWord(text: "agreed", range: r(0.5, 1.0)),
            TimedWord(text: "No", range: r(2, 2.4)),
            TimedWord(text: ".", range: r(2.4, 2.45)),
        ]
        let pieces = TranscriptAligner.align(update: update("Yes, agreed No.", 0, 2.45, words: ws), turns: [turn("a", 0, 1.5), turn("b", 1.5, 3)])
        #expect(pieces.map(\.text) == ["Yes, agreed", "No."])
    }
}
