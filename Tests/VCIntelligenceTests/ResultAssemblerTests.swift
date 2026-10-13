import Foundation
import Testing
import VCModels
@testable import VCIntelligence

@Suite struct ResultAssemblerTests {
    let utterance = ContextLine(
        segmentID: UUID(), speaker: "Rishi", time: 30.7, text: "Agreed. I will send the updated budget to everyone by Friday.")

    @Test func offSchemaInsightStillYieldsUsableFields() throws {
        // Wrong intent casing, a number where a string belongs, an unknown key and a stray null.
        let json = """
            {"intent": "Commitment.", "correctedText": null, "correctionReason": 7, "suggestion": "Confirm: budget owner",
             "actionItem": {"task": "Send the updated budget", "owner": "I", "due": "Friday", "extra": true}, "bogus": [1]}
            """
        let raw = try JSONDecoder().decode(RawInsight.self, from: Data(json.utf8))
        let insight = ResultAssembler.insight(from: raw, utterance: utterance)

        #expect(insight.intent == .commitment)
        #expect(insight.correctedText == nil)
        #expect(insight.correctionReason == nil)
        #expect(insight.suggestion == "Confirm: budget owner")
        #expect(insight.actionItem?.task == "Send the updated budget")
        #expect(insight.actionItem?.owner == "Rishi")
        #expect(insight.actionItem?.due == "Friday")
        #expect(insight.actionItem?.sourceSegmentID == utterance.segmentID)
        #expect(insight.needsAttention)
    }

    @Test func unknownIntentFallsBackToStatement() {
        let raw = RawInsight(intent: "musing", correctedText: nil, correctionReason: nil, suggestion: nil, actionItem: nil)
        let insight = ResultAssembler.insight(from: raw, utterance: utterance)
        #expect(insight.intent == .statement)
        #expect(!insight.needsAttention)
    }

    @Test(arguments: [
        "Agreed. I will send the updated budget to everyone by Friday.",
        "\"agreed, i will send the updated budget to everyone by friday\"",
        "  ",
    ])
    func correctionEqualToUtteranceIsDropped(corrected: String) {
        let raw = RawInsight(intent: "commitment", correctedText: corrected, correctionReason: "none", suggestion: nil, actionItem: nil)
        let insight = ResultAssembler.insight(from: raw, utterance: utterance)
        #expect(insight.correctedText == nil)
        #expect(insight.correctionReason == nil)
    }

    @Test func realCorrectionIsKeptUnquotedWithReason() {
        let raw = RawInsight(
            intent: "correction", correctedText: "“Wednesday the fifteenth”", correctionReason: "Self-correction.",
            suggestion: nil, actionItem: nil)
        let insight = ResultAssembler.insight(from: raw, utterance: utterance)
        #expect(insight.correctedText == "Wednesday the fifteenth")
        #expect(insight.correctionReason == "Self-correction.")
    }

    // What the on-device model returned for correct fixture lines: a stretch of the speaker's own words.
    @Test(arguments: [
        ("Thanks Daniel. The main item today is the launch date for the mobile app.", "The main item today is the launch date for the mobile app."),
        ("Great. Decision made, we launch on Wednesday the fifteenth. Thanks all.", "Decision made, we launch on Wednesday the fifteenth."),
        ("No problem, I can take that.", "I can take that."),
    ])
    func echoedSpeechIsNotACorrection(said: String, echoed: String) {
        #expect(!ResultAssembler.isGenuineCorrection(echoed, of: said))
    }

    @Test(arguments: [
        ("So let's target the launch for Tuesday the fourteenth, sorry, I mean Wednesday the fifteenth.", "Wednesday the fifteenth"),
        ("We need five, no, six engineers.", "six engineers"),
        ("The budget is forty thousand.", "The budget is fourteen thousand."),
        ("Ship it on Friday.", "Ship it on Monday, as agreed earlier."),
    ])
    func repairsAndChangedWordingAreCorrections(said: String, corrected: String) {
        #expect(ResultAssembler.isGenuineCorrection(corrected, of: said))
    }

    @Test func inventedDueDatesAndEmptySuggestionsAreDropped() {
        let context = [ContextLine(segmentID: UUID(), speaker: "Karen", time: 20, text: "Can we have it by next Tuesday?")]
        let invented = RawInsight(
            intent: "commitment", correctedText: nil, correctionReason: nil, suggestion: "Confirm:",
            actionItem: RawActionItem(task: "Send the budget", owner: "I", due: "Today at 10:00 AM."))
        let insight = ResultAssembler.insight(from: invented, utterance: utterance, context: context)
        #expect(insight.actionItem?.due == nil)
        #expect(insight.suggestion == nil)

        let fromContext = RawInsight(
            intent: "commitment", correctedText: nil, correctionReason: nil, suggestion: "Ask: does Friday suit Karen?",
            actionItem: RawActionItem(task: "Send the budget", owner: "I", due: "next Tuesday"))
        let grounded = ResultAssembler.insight(from: fromContext, utterance: utterance, context: context)
        #expect(grounded.actionItem?.due == "next Tuesday")
        #expect(grounded.suggestion == "Ask: does Friday suit Karen?")
    }

    @Test func repeatedActionItemKeepsTheMajorityOwner() throws {
        let transcript = try Fixture.transcript()
        let task = "Share the press kit with the marketing team"
        let raw = RawReport(
            title: nil, overview: nil, topics: [], decisions: [],
            actionItems: [
                RawActionItem(task: task, owner: "Karen", due: "Monday", timestamp: "00:39"),
                RawActionItem(task: "Send the updated budget", owner: "Rishi", due: "Friday", timestamp: "00:30"),
                RawActionItem(task: task, owner: "Samantha", due: "Monday", timestamp: "00:39"),
                RawActionItem(task: task + ".", owner: "Samantha", due: nil, timestamp: nil),
            ],
            notesToRemember: [], missedOpportunities: [], openQuestions: [], corrections: [], participantSummaries: [])
        let report = ResultAssembler.report(from: raw, transcript: transcript, participants: [], meetingTitle: nil, generatedBy: "test")
        #expect(report.actionItems.map(\.task) == [task, "Send the updated budget"])
        #expect(report.actionItems[0].owner == "Samantha")
        #expect(report.actionItems[0].due == "Monday")
        #expect(report.actionItems[0].sourceSegmentID == Fixture.segmentID(8))
    }

    // Live on-device outputs for fixture lines 5, 7 and 9.
    @Test func liveActionItemsAreGatedCleanedAndOwnedByTheAddressee() throws {
        let t = try Fixture.transcript()
        let thanks = RawInsight(
            intent: "decision", correctedText: nil, correctionReason: nil, suggestion: nil,
            actionItem: RawActionItem(task: "Thank all.", owner: "Daniel", due: nil))
        #expect(ResultAssembler.insight(from: thanks, utterance: t[9], context: Array(t[..<9])).actionItem == nil)

        let labelOnly = RawInsight(
            intent: "proposal", correctedText: nil, correctionReason: nil, suggestion: nil,
            actionItem: RawActionItem(task: "Propose:", owner: "Samantha", due: "Wednesday the fifteenth"))
        #expect(ResultAssembler.insight(from: labelOnly, utterance: t[5], context: Array(t[..<5])).actionItem == nil)

        let request = RawInsight(
            intent: "request", correctedText: nil, correctionReason: nil, suggestion: nil,
            actionItem: RawActionItem(task: "Share the press kit before the freeze", owner: "Karen", due: nil))
        let asked = ResultAssembler.insight(from: request, utterance: t[7], context: Array(t[..<7]))
        #expect(asked.actionItem?.owner == "Samantha")
        #expect(asked.actionItem?.task == "Share the press kit before the freeze")
    }

    @Test(arguments: [
        ("Propose: Confirm: Marketing should share the notice timeline.", "Confirm: Marketing should share the notice timeline."),
        ("Confirm the freeze date with engineering.", "Confirm the freeze date with engineering."),
        ("Ask: ", nil),
        ("Propose: Confirm:", nil),
    ] as [(String, String?)])
    func suggestionLabels(raw: String, expected: String?) {
        #expect(ResultAssembler.meaningfulSuggestion(raw) == expected)
    }

    // From a live Apple-engine report on meeting.wav: line times copied into `due`.
    @Test func reportDropsTimestampAndInventedDueDates() throws {
        let transcript = try Fixture.transcript()
        let raw = RawReport(
            title: nil, overview: nil, topics: [], decisions: [],
            actionItems: [
                RawActionItem(task: "Send the updated budget", owner: "Rishi", due: "00:34", timestamp: "00:30"),
                RawActionItem(task: "Share the press kit", owner: "Samantha", due: "[00:41]", timestamp: "00:39"),
                RawActionItem(task: "Book the venue", owner: "Karen", due: "End of quarter", timestamp: nil),
                RawActionItem(task: "Send the updated budget", owner: "Rishi", due: "Friday", timestamp: "00:30"),
            ],
            notesToRemember: [], missedOpportunities: [], openQuestions: [], corrections: [], participantSummaries: [])
        let report = ResultAssembler.report(from: raw, transcript: transcript, participants: [], meetingTitle: nil, generatedBy: "test")
        #expect(report.actionItems.map(\.due) == ["Friday", nil, nil])
    }

    @Test(arguments: [("me", "Rishi"), ("Samantha", "Samantha"), ("we", nil), ("The team", nil), ("", nil)] as [(String, String?)])
    func actionItemOwnerResolution(owner: String, expected: String?) {
        let raw = RawInsight(
            intent: "commitment", correctedText: nil, correctionReason: nil, suggestion: nil,
            actionItem: RawActionItem(task: "Send the budget", owner: owner, due: nil))
        #expect(ResultAssembler.insight(from: raw, utterance: utterance).actionItem?.owner == expected)
    }

    @Test func reportLinksActionItemsToTranscriptAndCleansLists() throws {
        let transcript = try Fixture.transcript()
        let raw = RawReport(
            title: "Model title",
            overview: "Launch planning.",
            topics: [RawTopic(title: "Launch date", summary: nil, speakers: ["Daniel", "daniel", "Karen"]), RawTopic(title: nil, summary: "x", speakers: [])],
            decisions: ["Launch on Wednesday the fifteenth.", "launch on wednesday the fifteenth", ""],
            actionItems: [
                // 00:39 is Samantha's line; the owner matches the speaker there.
                RawActionItem(task: "Share the press kit", owner: "Samantha", due: "Monday", timestamp: "[0:39]"),
                RawActionItem(task: "share the press kit.", owner: "Samantha", due: nil, timestamp: nil),
                // Rishi speaks at 00:30; "I" resolves to him.
                RawActionItem(task: "Send the updated budget", owner: "I", due: "Friday", timestamp: "00:30"),
                RawActionItem(task: "Book a venue", owner: "someone", due: nil, timestamp: "99:99"),
                RawActionItem(task: nil, owner: "Karen", due: nil, timestamp: nil),
            ],
            notesToRemember: ["Marketing needs three weeks' notice."],
            missedOpportunities: ["Nobody checked the three-week notice against the date."],
            openQuestions: [],
            corrections: [
                RawCorrection(speaker: "Daniel", original: "Tuesday the fourteenth", corrected: "Wednesday the fifteenth", reason: "Self-correction"),
                RawCorrection(speaker: "Karen", original: "Same text", corrected: "same text", reason: nil),
            ],
            participantSummaries: [
                RawParticipant(name: "karen", keyPoints: ["Needs three weeks of notice"]),
                RawParticipant(name: "Guest", keyPoints: ["Listened"]),
                RawParticipant(name: "Daniel", keyPoints: ["Chaired", "chaired"]),
            ])

        let report = ResultAssembler.report(
            from: raw, transcript: transcript, participants: ["Daniel", "Samantha", "Rishi", "Karen"],
            meetingTitle: "  Quarterly planning ", generatedBy: "Test")

        #expect(report.title == "Quarterly planning")
        #expect(report.topics == [TopicSummary(title: "Launch date", summary: "", speakers: ["Daniel", "Karen"])])
        #expect(report.decisions == ["Launch on Wednesday the fifteenth."])
        #expect(report.actionItems.map(\.task) == ["Share the press kit", "Send the updated budget", "Book a venue"])
        #expect(report.actionItems[0].owner == "Samantha")
        #expect(report.actionItems[0].sourceSegmentID == Fixture.segmentID(8))
        #expect(report.actionItems[1].owner == "Rishi")
        #expect(report.actionItems[1].sourceSegmentID == Fixture.segmentID(6))
        #expect(report.actionItems[2].owner == nil)
        #expect(report.actionItems[2].sourceSegmentID == nil)
        #expect(report.corrections.count == 1)
        #expect(report.corrections.first?.corrected == "Wednesday the fifteenth")
        // Given participants first in their order, unknown names after, names merged case-insensitively.
        #expect(report.participantSummaries.map(\.name) == ["Daniel", "Karen", "Guest"])
        #expect(report.participantSummaries[0].keyPoints == ["Chaired"])
        #expect(report.generatedBy == "Test")
    }

    @Test func reportTitleFallsBackToModelTitleThenGeneric() {
        let empty = RawReport(
            title: nil, overview: nil, topics: [], decisions: [], actionItems: [], notesToRemember: [],
            missedOpportunities: [], openQuestions: [], corrections: [], participantSummaries: [])
        var titled = empty
        titled.title = "Launch review"
        #expect(ResultAssembler.report(from: titled, transcript: [], participants: [], meetingTitle: " ", generatedBy: "T").title == "Launch review")
        #expect(ResultAssembler.report(from: empty, transcript: [], participants: [], meetingTitle: nil, generatedBy: "T").title == "Meeting")
    }

    @Test(arguments: [("1:05", "01:05"), ("[01:05]", "01:05"), ("1:02:03", "62:03"), ("soon", "soon")])
    func timestampNormalization(input: String, expected: String) {
        #expect(ResultAssembler.normalizedTimestamp(input) == expected)
    }
}
