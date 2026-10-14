import Foundation
import Testing
import VCModels

@testable import VCIntelligence

/// The conversation outline: grounding of model points, coverage of the whole meeting, and the outline built
/// without a language model.
@Suite struct OutlineGroundingTests {
    let t = TeamSync.transcript

    private func report(_ raw: RawReport, _ transcript: [ContextLine]? = nil) -> MeetingReport {
        let transcript = transcript ?? t
        return ResultAssembler.report(
            from: raw, transcript: transcript, participants: [], meetingTitle: "Weekly team sync", generatedBy: "test")
    }

    private func point(_ speaker: String?, _ text: String, _ lines: Int...) -> RawOutlinePoint {
        RawOutlinePoint(speaker: speaker, text: text, lines: lines)
    }

    /// 1-based line numbers of the transcript lines every point cites.
    private func citedLines(_ outline: [OutlineSegment], in transcript: [ContextLine]) -> [Int] {
        outline.flatMap(\.points).flatMap(\.segmentIDs).compactMap { id in transcript.firstIndex { $0.segmentID == id }.map { $0 + 1 } }
    }

    // MARK: Grounding

    @Test func pointsMustBeTheSpeakersOwnSupportedAndNotOverstated() {
        let raw = RawReport(outline: [
            RawOutlineSegment(heading: "Billing bug", points: [
                point("Tom", "Double charge hit about forty customers on annual plans", 4),
                // Cites Maya's line, but Tom did not say it.
                point("Tom", "Refunds need the list of affected accounts", 10),
                // Tom only promised to send it.
                point("Tom", "Sent finance the list of affected accounts", 11),
                // Nothing in common with the cited line.
                point("Leo", "Database migration finished ahead of schedule", 7),
                // Cites nothing.
                point("Priya", "Proposed a discount for affected customers"),
                // Unknown speaker.
                point("Anna", "Support is short-staffed in December", 36),
                // The speaker is the cited line's when not given; "Name:" in the text is the attribution.
                point(nil, "Retry job fired twice when the card processor timed out", 7),
                point(nil, "Leo: duplicate-charge alert to catch it within an hour", 17),
                // Small talk is no point, even when cited.
                point("Leo", "Sorry, late", 2),
            ]),
        ])
        // Quotes fill the stretches nobody covered; the model's own points are the others.
        let points = report(raw).outline.flatMap(\.points).filter { !$0.isQuote }
        #expect(points.map(\.speaker) == ["Tom", "Leo", "Leo"])
        #expect(points.map(\.text) == [
            "Double charge hit about forty customers on annual plans",
            "Retry job fired twice when the card processor timed out",
            "duplicate-charge alert to catch it within an hour",
        ])
        #expect(points.first?.time == t[3].time && points.first?.segmentIDs == [t[3].segmentID])
    }

    @Test func aPointCopiedFromItsLineIsAQuote() {
        let raw = RawReport(outline: [
            RawOutlineSegment(heading: "Billing", points: [
                point("Tom", "Finance needs the list of affected accounts before they can issue refunds.", 9),
            ]),
        ])
        #expect(report(raw).outline.first?.points.first?.isQuote == true)
    }

    // MARK: Coverage

    @Test func segmentsCoverTheWholeMeetingInOrder() throws {
        let raw = RawReport(outline: [
            // Out of order on purpose.
            RawOutlineSegment(heading: "Conference in Lisbon", points: [
                point("Priya", "Early-bird passes end on the twentieth and cost four hundred euros instead of six hundred", 21),
                point("Tom", "Travel budget is about six thousand euros, to double-check with finance", 25),
                point("Priya", "Talk on offline sync was accepted, Leo presents it", 29),
            ]),
            RawOutlineSegment(heading: "Billing bug", points: [
                point("Tom", "Double charge hit about forty customers on annual plans", 4),
                point("Tom", "Twenty-six open tickets and two customers asked to cancel", 5),
                point("Leo", "Retry job fired twice when the card processor timed out; fix shipped Monday", 7),
                point("Priya", "Proposes one month free on the next renewal, roughly two thousand euros", 14),
                point("Leo", "Wants an alert on duplicate charges to catch it within an hour", 17),
            ]),
        ])
        let outline = report(raw).outline
        try #require(!outline.isEmpty)
        #expect(outline.first?.start == t.first?.time)
        #expect(outline.last?.end == t.last?.end)
        for (a, b) in zip(outline, outline.dropFirst()) {
            #expect(a.start < b.start)
            #expect(a.end <= b.start)
        }
        #expect(outline.map(\.heading).prefix(2) == ["Billing bug", "Conference in Lisbon"])
        Self.expectCoverage(outline, of: t)
    }

    /// The model skipped the release estimate (lines 31-37) and the stretch inside the billing segment.
    @Test func stretchesTheModelSkippedAreFilledFromTheTranscript() throws {
        let raw = RawReport(outline: [
            RawOutlineSegment(heading: "Billing bug", points: [
                point("Tom", "Double charge hit about forty customers on annual plans", 4),
                point("Leo", "Wants an alert on duplicate charges to catch it within an hour", 17),
            ]),
            RawOutlineSegment(heading: "Conference in Lisbon", points: [
                point("Priya", "Early-bird passes end on the twentieth and cost four hundred euros instead of six hundred", 21),
                point("Priya", "Talk on offline sync was accepted, Leo presents it", 29),
            ]),
        ])
        let outline = report(raw).outline
        Self.expectCoverage(outline, of: t)
        // Filled points are the speakers' own sentences, quoted from the lines they cite.
        let quotes = outline.flatMap(\.points).filter(\.isQuote)
        #expect(!quotes.isEmpty)
        for point in quotes {
            let line = try #require(t.first { $0.segmentID == point.segmentIDs.first })
            #expect(line.speaker == point.speaker)
            #expect(ResultAssembler.comparable(line.text).contains(ResultAssembler.comparable(point.text.replacingOccurrences(of: "…", with: ""))))
        }
        // The release estimate is quoted, attached to an existing segment; a four-minute meeting keeps two
        // segments with the model's headings.
        let estimate = Set(t[30..<37].map(\.segmentID))
        #expect(quotes.contains { $0.speaker == "Leo" && estimate.contains($0.segmentIDs[0]) })
        #expect(outline.map(\.heading) == ["Billing bug", "Conference in Lisbon"])
        #expect(outline.allSatisfy { !$0.isExtracted })
    }

    /// Thin segments join their closer neighbour, then the closest neighbours merge until there is about one
    /// segment per three minutes (at most twelve).
    @Test func segmentsMergeToAboutOnePerThreeMinutes() {
        // Lines 20-21 (the conference opening) alone are thin; a four-minute meeting gets two segments.
        let groups = TranscriptOutliner.mergeGroups([0..<19, 19..<21, 21..<30, 30..<40], weak: [false, false, false, false], transcript: t)
        #expect(groups == [[0], [1, 2, 3]] || groups == [[0, 1], [2, 3]] || groups == [[0, 1, 2], [3]])
        #expect(groups.count == 2)
        #expect(TranscriptOutliner.segmentLimit(duration: 48) == 1)
        #expect(TranscriptOutliner.segmentLimit(duration: 26 * 60) == 9)
        #expect(TranscriptOutliner.segmentLimit(duration: 3 * 3_600) == 12)
        // A segment of quotes only (weak) is merged however long it is.
        let weak = TranscriptOutliner.mergeGroups([0..<19, 19..<40], weak: [false, true], transcript: Array(t.prefix(40)))
        #expect(weak == [[0, 1]])
    }

    @Test func thinMeetingKeepsOneShortSegmentAndFillsNothing() {
        let raw = RawReport(outline: [
            RawOutlineSegment(heading: "Introduction", points: [
                point("Ayo", "Ayo opened a meeting about a crucial matter that touches every subject", 2),
                point("Ayo", "Thanked attendees", 3),
                point("Speaker 1", "Introduced themselves", 6),
                point("Ayo", "Asked for introductions", 6),
                point("Ayo", "Said he doesn't know who he is", 7),
            ]),
            RawOutlineSegment(heading: "Discussion", points: [point("Ayo", "Discussed what it takes to put this together", 8)]),
        ])
        let outline = report(raw, Regression.transcript).outline
        #expect(outline.count <= 1)
        #expect(outline.flatMap(\.points).count <= 2)
        #expect(outline.flatMap(\.points).allSatisfy { !$0.isQuote })
        #expect(outline.flatMap(\.points).map(\.text) == ["Ayo opened a meeting about a crucial matter that touches every subject"])
    }

    /// Every substantive line lies within `outlineReach` lines of a cited line, and every line within a segment.
    static func expectCoverage(_ outline: [OutlineSegment], of transcript: [ContextLine], sourceLocation: SourceLocation = #_sourceLocation) {
        let cited = Set(outline.flatMap(\.points).flatMap(\.segmentIDs).compactMap { id in transcript.firstIndex { $0.segmentID == id } })
        for (index, line) in transcript.enumerated() where TranscriptOutliner.isSubstantive(line.text) {
            #expect(
                cited.contains { abs($0 - index) <= ResultAssembler.outlineReach }, "line \(index + 1) not covered: \(line.text)",
                sourceLocation: sourceLocation)
        }
        for line in transcript {
            #expect(outline.contains { $0.start <= line.time && line.time <= $0.end }, "line at \(line.time) outside every segment", sourceLocation: sourceLocation)
        }
    }

    // MARK: Overview

    @Test func overviewKeepsParagraphsAndDropsOverstatedSentences() {
        let raw = RawReport(overview: """
            The team reviewed the billing bug that double-charged about forty customers. Leo explained the retry fix.

            Tom sent finance the list of affected accounts. Priya will draft an apology email offering one month free.

            Priya booked the early-bird passes for Lisbon, and Leo needs the slides reviewed two weeks before.
            """)
        #expect(report(raw).overview == """
            The team reviewed the billing bug that double-charged about forty customers. Leo explained the retry fix.

            Priya will draft an apology email offering one month free.
            """)
        // A thin meeting keeps two sentences in one paragraph.
        let thin = RawReport(overview: "Ayo opened a meeting.\n\nHe thanked everyone. He asked for introductions.")
        #expect(report(thin, Regression.transcript).overview == "Ayo opened a meeting. He thanked everyone.")
    }

    // MARK: Decoding

    @Test func outlineDecodesLeniently() throws {
        let json = """
            {"outline": [{"heading": "Billing", "points": [{"speaker": "Tom", "text": "Forty customers hit", "lines": ["L4"]}, "junk", {"text": null}]}, 7]}
            """
        let raw = try JSONDecoder().decode(RawReport.self, from: Data(json.utf8))
        #expect(raw.outline == [RawOutlineSegment(heading: "Billing", points: [
            RawOutlinePoint(speaker: "Tom", text: "Forty customers hit", lines: [4]), RawOutlinePoint(speaker: nil, text: nil, lines: []),
        ])])
    }

    @Test func reportsSavedBeforeTheOutlineStillDecode() throws {
        let json = """
            {"title": "T", "overview": "O", "topics": [], "decisions": [], "actionItems": [], "notesToRemember": [],
             "missedOpportunities": [], "openQuestions": [], "corrections": [], "participantSummaries": [],
             "generatedBy": "Claude", "generatedAt": 0}
            """
        let report = try JSONDecoder().decode(MeetingReport.self, from: Data(json.utf8))
        #expect(report.outline.isEmpty && report.kind == .languageModel)
        let roundTrip = try JSONDecoder().decode(MeetingReport.self, from: JSONEncoder().encode(report))
        #expect(roundTrip == report)
    }
}

/// The report without a language model.
@Suite struct TranscriptOutlineTests {
    let t = TeamSync.transcript

    private func outline(_ transcript: [ContextLine]) -> MeetingReport {
        TranscriptOutliner.report(
            transcript: transcript, participants: [], meetingTitle: "Weekly team sync", generatedAt: Date(timeIntervalSinceReferenceDate: 0))
    }

    @Test func isDeterministicAndLabelledAsNotAI() async throws {
        let first = outline(t)
        #expect(first == outline(t))
        #expect(first.kind == .transcriptOutline)
        #expect(first.generatedBy == "Transcript outline (no AI)")
        let engine = TranscriptOutlineEngine()
        #expect(engine.engineName == "Transcript outline (no AI)")
        var viaEngine = try await engine.report(transcript: t, participants: [], meetingTitle: "Weekly team sync")
        viaEngine.generatedAt = first.generatedAt
        #expect(viaEngine == first)
        #expect(first.topics.isEmpty && first.decisions.isEmpty && first.participantSummaries.isEmpty)
    }

    @Test func segmentsSplitWhereTheSubjectChanges() {
        let ranges = TranscriptOutliner.segments(t, vocabulary: TranscriptOutliner.Vocabulary(t))
        // "Next topic, the developer conference…" (line 20) and "Last thing, the mobile release estimate…" (line 31).
        #expect(ranges == [0..<19, 19..<30, 30..<40])
        // The report then merges to about one segment per three minutes: two for this four-minute meeting.
        let report = outline(t)
        #expect(report.outline.count == 2)
        #expect(report.outline.first?.start == t.first?.time && report.outline.last?.end == t.last?.end)
        for line in t {
            #expect(report.outline.contains { $0.start <= line.time && line.time <= $0.end })
        }
    }

    @Test func pointsAreEachSpeakersOwnInformativeSentences() throws {
        let report = outline(t)
        for segment in report.outline {
            #expect((2...6).contains(segment.points.count))
            #expect(segment.isExtracted)
            for point in segment.points {
                let line = try #require(t.first { $0.segmentID == point.segmentIDs.first })
                #expect(point.isQuote && point.speaker == line.speaker && point.time == line.time)
                #expect(line.text.contains(point.text.trimmingCharacters(in: .punctuationCharacters)) || ResultAssembler.comparable(line.text).contains(ResultAssembler.comparable(point.text)))
            }
        }
        let points = report.outline.flatMap(\.points).map(\.text)
        // Facts with numbers win; an aside ("the train was stuck") and greetings never do.
        #expect(points.contains("The double-charge bug hit about forty customers on annual plans, all of them renewed between the third and the fifth."))
        #expect(!points.contains { $0.localizedCaseInsensitiveContains("train") || $0.localizedCaseInsensitiveContains("morning") })
    }

    @Test func questionsAndPossibleActionItems() {
        let report = outline(t)
        #expect(report.openQuestions.contains("Maya: What's the travel budget for this quarter?"))
        // A request phrased as a question is an action item, not a question.
        #expect(!report.openQuestions.contains { $0.contains("could you book") })
        let items = report.actionItems.map { "\($0.task) | \($0.owner ?? "-") | \($0.due ?? "-")" }
        #expect(items.contains("Tom, please send finance the list of affected accounts today. | Tom | today"))
        #expect(items.contains("I'll draft the apology email by Thursday and share it with Tom before it goes out. | Priya | Thursday"))
        #expect(items.contains("Priya, could you book the early-bird passes before the twentieth? | Priya | before the twentieth"))
        // "Sure, I'll send it to finance this afternoon" accepts Tom's request; "I can, but…" takes nothing on.
        #expect(!items.contains { $0.hasPrefix("Sure, I'll send it") || $0.hasPrefix("I can, but") })
        #expect(report.actionItems.allSatisfy { item in t.contains { $0.segmentID == item.sourceSegmentID } })
    }

    @Test func thinMeetingStaysThin() {
        let report = outline(Regression.transcript)
        #expect(report.outline.count <= 1)
        #expect(report.outline.flatMap(\.points).count <= 2)
        #expect(report.actionItems.isEmpty)
        #expect(report.openQuestions.isEmpty)
        // The last line's end is estimated from its length (about 2.5 words a second).
        #expect(report.overview == "Ayo spoke 8 lines over 48 seconds.")
    }

    @Test func emptyTranscript() {
        let report = outline([])
        #expect(report.overview == "No speech was transcribed." && report.outline.isEmpty && report.kind == .transcriptOutline)
    }
}
