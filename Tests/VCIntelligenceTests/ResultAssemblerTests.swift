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
            {"intent": "Commitment.", "correctionKind": "None", "correctedText": null, "contradictsLine": "L2",
             "suggestion": "Confirm: budget owner",
             "actionItem": {"task": "Send the updated budget", "owner": "I", "due": "Friday", "extra": true}, "bogus": [1]}
            """
        let raw = try JSONDecoder().decode(RawInsight.self, from: Data(json.utf8))
        #expect(raw.contradictsLine == 2)
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
        let raw = RawInsight(intent: "musing", correctedText: nil, suggestion: nil, actionItem: nil)
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
        for kind in CorrectionKind.allCases {
            let raw = RawInsight(intent: "commitment", correctionKind: kind.rawValue, correctedText: corrected, suggestion: nil, actionItem: nil)
            let insight = ResultAssembler.insight(from: raw, utterance: utterance)
            #expect(insight.correctedText == nil)
            #expect(insight.correctionReason == nil)
        }
    }

    @Test func selfCorrectionIsKeptUnquotedWithReasonFromItsKind() throws {
        let t = try Fixture.transcript()
        let raw = RawInsight(
            intent: "correction", correctionKind: "selfCorrection", correctedText: "“Wednesday the fifteenth”", suggestion: nil,
            actionItem: nil)
        let insight = ResultAssembler.insight(from: raw, utterance: t[4], context: Array(t[..<4]))
        #expect(insight.correctedText == "Wednesday the fifteenth")
        #expect(insight.correctionReason == "Daniel corrected themselves")
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

    static func line(_ speaker: String, _ time: Double, _ text: String) -> ContextLine {
        ContextLine(segmentID: UUID(), speaker: speaker, time: time, text: text)
    }

    static let marketing = line("Karen", 15, "Marketing needs at least three weeks of notice before any launch.")

    /// (utterance, kind, corrected, cites the marketing line, expected reason)
    @Test(arguments: [
        ("So let's target the launch for Tuesday the fourteenth, sorry, I mean Wednesday the fifteenth.", "selfCorrection", "Wednesday the fifteenth", false, "Daniel corrected themselves"),
        ("We need five, no, six engineers.", "selfCorrection", "six engineers", false, "Daniel corrected themselves"),
        ("We finished the payment integration last weak.", "mishearing", "We finished the payment integration last week.", false, "Probably misheard"),
        ("The budget is forty thousand.", "mishearing", "The budget is fourteen thousand.", false, "Probably misheard"),
        ("Marketing only needs one week of notice.", "contradiction", "Marketing needs three weeks of notice.", true, "Contradicts 00:15 (Karen)"),
    ] as [(String, String, String, Bool, String)])
    func typedCorrectionsThatFitTheirKind(said: String, kind: String, corrected: String, cites: Bool, reason: String) {
        let raw = RawInsight(
            intent: "correction", correctionKind: kind, correctedText: corrected, contradictsLine: cites ? 1 : nil, suggestion: nil,
            actionItem: nil)
        let insight = ResultAssembler.insight(from: raw, utterance: Self.line("Daniel", 20, said), context: [Self.marketing])
        #expect(insight.correctedText == corrected)
        #expect(insight.correctionReason == reason)
    }

    @Test(arguments: [
        // A self-correction needs a repair cue, and its text must come from the repair.
        ("Ship it on Friday.", "selfCorrection", "Ship it on Monday.", false),
        ("So let's target the launch for Tuesday the fourteenth, sorry, I mean Wednesday the fifteenth.", "selfCorrection", "Tuesday the fourteenth", false),
        ("Actually, I think we should ship on Friday.", "selfCorrection", "We should ship on Friday.", false),
        // A mishearing is a small swap of words that sound alike.
        ("Ship it on Friday.", "mishearing", "Ship it on Monday.", false),
        ("Um, I don't, I don't really know.", "mishearing", "I don't know who I am.", false),
        // A contradiction cites a line, and its new words come from that line.
        ("Marketing only needs one week of notice.", "contradiction", "Marketing needs three weeks of notice.", false),
        ("Engineering is on track.", "contradiction", "Engineering is behind schedule.", true),
        // Model-invented or unknown kinds.
        ("Ship it on Friday.", "none", "Ship it on Monday.", false),
        ("Ship it on Friday.", "rephrase", "Please ship it on Friday.", false),
    ] as [(String, String, String, Bool)])
    func correctionsThatDoNotFitTheirKindAreRejected(said: String, kind: String, corrected: String, cites: Bool) {
        let raw = RawInsight(
            intent: "correction", correctionKind: kind, correctedText: corrected, contradictsLine: cites ? 1 : nil, suggestion: nil,
            actionItem: nil)
        let insight = ResultAssembler.insight(from: raw, utterance: Self.line("Daniel", 20, said), context: [Self.marketing])
        #expect(insight.correctedText == nil)
        #expect(insight.correctionReason == nil)
    }

    @Test(arguments: [
        ("Hey, this is, uh, a meeting.", "Hey, this is a meeting."),
        ("Um, I don't, I don't really know.", "I don't really know."),
        ("We, we, we should, um, ship it.", "We should ship it."),
    ])
    func fillerAndRepetitionEditsAreNeverCorrections(said: String, cleaned: String) {
        for kind in CorrectionKind.allCases {
            let raw = RawInsight(intent: "correction", correctionKind: kind.rawValue, correctedText: cleaned, contradictsLine: 1, suggestion: nil, actionItem: nil)
            #expect(ResultAssembler.insight(from: raw, utterance: Self.line("Ayo", 1, said), context: [Self.line("Ayo", 0, said)]).correctedText == nil)
        }
    }

    // MARK: Regression: the user's one-minute meeting (`Regression.transcript`)

    /// What the on-device model returned live for each line, under every correction kind it could have chosen.
    @Test func regressionLiveInsightsShowNothing() {
        let t = Regression.transcript
        for kind in ["selfCorrection", "contradiction", "mishearing", "Spelling error"] {
            let filler = RawInsight(intent: "statement", correctionKind: kind, correctedText: "Hey, this is a meeting.", contradictsLine: nil, suggestion: nil, actionItem: nil)
            #expect(ResultAssembler.insight(from: filler, utterance: t[0]).correctedText == nil)
            for cited in [nil, 1, 6] as [Int?] {
                let speculative = RawInsight(
                    intent: "correction", correctionKind: kind, correctedText: "I don't know who I am.", contradictsLine: cited, suggestion: nil,
                    actionItem: nil)
                #expect(ResultAssembler.insight(from: speculative, utterance: t[6], context: Array(t[..<6])).correctedText == nil)
            }
        }
        let thanks = RawInsight(
            intent: "commitment", correctedText: nil, suggestion: nil,
            actionItem: RawActionItem(task: "Thank the attendees for their attendance.", owner: "Ayo", due: nil))
        #expect(ResultAssembler.insight(from: thanks, utterance: t[2], context: Array(t[..<2])).actionItem == nil)
        let introduce = RawInsight(
            intent: "request", correctedText: nil, suggestion: "Clarify: Can you introduce yourself?",
            actionItem: RawActionItem(task: "Introduce yourself", owner: "Speaker 1", due: nil))
        let asked = ResultAssembler.insight(from: introduce, utterance: t[5], context: Array(t[..<5]))
        #expect(asked.actionItem == nil)
        #expect(asked.suggestion == nil)
        #expect(!asked.needsAttention)
    }

    @Test func regressionReportIsBriefAndInventsNothing() {
        for citeEverything in [false, true] {
            let report = ResultAssembler.report(
                from: Regression.badReport(citeEverything: citeEverything), transcript: Regression.transcript,
                participants: ["Ayo", "Speaker 1"], meetingTitle: nil, generatedBy: "test")
            #expect(report.decisions.isEmpty)
            #expect(report.actionItems.isEmpty)
            #expect(report.notesToRemember.isEmpty)
            #expect(report.missedOpportunities.isEmpty)
            #expect(report.openQuestions.isEmpty)
            #expect(report.corrections.isEmpty)
            #expect(report.participantSummaries.isEmpty)
            #expect(report.topics.count <= 1)
            #expect(report.overview == "Ayo opened a meeting about a crucial matter and thanked everyone for attending. He asked someone to introduce themselves.")
        }
    }

    @Test func participantSummariesOnlyForSpeakersAndFromTheirOwnLines() {
        let summaries = ResultAssembler.participantSummaries(
            Regression.badReport(citeEverything: false).participantSummaries
                + [RawParticipant(name: "ayo", keyPoints: [RawItem(text: "Raised a crucial matter", lines: [2])])],
            participants: ["Ayo", "Speaker 1"], evidence: Evidence(Regression.transcript), limit: 4)
        #expect(summaries == [ParticipantSummary(name: "Ayo", keyPoints: ["Raised a crucial matter"])])
    }

    // MARK: Participant points, overview and topics say only what the lines say

    static let promises: [ContextLine] = [
        ("Maya", "Tom, please send finance the list of affected accounts today."),
        ("Tom", "Sure, I will send finance the list of affected accounts today."),
        ("Priya", "I'll book the conference tickets this week."),
        ("Leo", "I spent most of the weekend moving flat, so I'm a bit tired today."),
        ("Samantha", "I propose we freeze features by the end of this month."),
        ("Rishi", "Agreed. I will send the updated budget to everyone by Friday."),
        ("Rishi", "We finished the payment integration last week."),
        ("Maya", "Priya, could you book the early-bird passes before the twentieth?"),
        ("Priya", "Sure, I'll book them this week."),
        ("Leo", "Sounds good."),
    ].enumerated().map { ContextLine(segmentID: Fixture.segmentID(200 + $0), speaker: $1.0, time: Double($0 * 5), text: $1.1) }

    @Test func participantPointsCiteTheirOwnLinesAndKeepPromisesPromises() {
        func point(_ text: String, _ lines: Int...) -> RawItem { RawItem(text: text, lines: lines) }
        let raw = [
            RawParticipant(name: "Tom", keyPoints: [
                point("Sent finance the list of affected accounts", 2),
                point("Will send finance the list of affected accounts today", 2),
                point("Asked finance for the account list", 1),
            ]),
            RawParticipant(name: "Priya", keyPoints: [
                point("Booked tickets for the conference", 3), point("Will book the conference tickets this week", 3),
                // "them" refers back to the request just before.
                point("Will book the travel visas", 9), point("Will book the early-bird passes", 9),
            ]),
            RawParticipant(name: "Leo", keyPoints: [point("Spent most of the weekend moving flat", 4), point("Sounds good.", 10)]),
            RawParticipant(name: "Samantha", keyPoints: [point("Agreed on the budget freeze", 5), point("Proposed a feature freeze by month end", 5)]),
            RawParticipant(name: "Rishi", keyPoints: [
                point("Agreed on the budget freeze", 6), point("Finished the payment integration (L7)"),
                point("Has sent the updated budget", 6),
            ]),
        ]
        let summaries = ResultAssembler.participantSummaries(raw, participants: [], evidence: Evidence(Self.promises), limit: 4)
        #expect(summaries == [
            ParticipantSummary(name: "Tom", keyPoints: ["Will send finance the list of affected accounts today"]),
            ParticipantSummary(name: "Priya", keyPoints: ["Will book the conference tickets this week", "Will book the early-bird passes"]),
            ParticipantSummary(name: "Samantha", keyPoints: ["Proposed a feature freeze by month end"]),
            ParticipantSummary(name: "Rishi", keyPoints: ["Finished the payment integration"]),
        ])
    }

    @Test func overviewAndTopicSentencesThatCallPromisesDoneAreDropped() {
        let raw = RawReport(
            overview: "Tom sent finance the list of affected accounts. Priya booked the conference tickets. Rishi finished the payment integration.",
            topics: [RawTopic(title: "Billing", summary: "Tom sent finance the list of affected accounts. The account list goes to finance today.", speakers: ["Tom"])],
            notesToRemember: [
                RawItem(text: "Tom sent finance the list of affected accounts", lines: [1, 2]),
                // "freeze" comes from four lines away: a misreading.
                RawItem(text: "Freeze the finance list", lines: [1]),
                RawItem(text: "Payment integration finished last week", lines: [7]),
            ])
        let report = ResultAssembler.report(from: raw, transcript: Self.promises, participants: [], meetingTitle: nil, generatedBy: "t")
        // The first sentence stays whatever it says.
        #expect(report.overview == "Tom sent finance the list of affected accounts. Rishi finished the payment integration.")
        #expect(report.topics.map(\.summary) == ["The account list goes to finance today."])
        #expect(report.notesToRemember == ["Payment integration finished last week"])
    }

    @Test func notesMayTakeNounsFromTheQuestionTheyAnswer() {
        let transcript = [
            ("Maya", "What's the budget for travel this quarter?"),
            ("Tom", "I think about six thousand euros, but I'd have to double-check."),
        ].enumerated().map { ContextLine(segmentID: Fixture.segmentID(300 + $0), speaker: $1.0, time: Double($0), text: $1.1) }
        let raw = RawReport(notesToRemember: [RawItem(text: "Travel budget this quarter is about six thousand euros", lines: [2])])
        let kept = ResultAssembler.groundedItems(raw.notesToRemember, evidence: Evidence(transcript)) { text, lines in
            Grounding.namesOnlyWhatWasSaid(text, evidence: Evidence(transcript).around(lines), names: [])
        }
        #expect(kept == ["Travel budget this quarter is about six thousand euros"])
    }

    @Test(arguments: [
        ("Agreed on the budget freeze", "I propose we freeze features by the end of this month.", false),
        ("Proposed a feature freeze by month end", "I propose we freeze features by the end of this month.", true),
        ("Proposed freezing features with Rishi", "I propose we freeze features by the end of this month.", true),
        ("Confirmed the launch for Wednesday", "So let's target the launch for Tuesday, sorry, Wednesday.", true),
    ])
    func shortItemsNameOnlyWhatTheLinesSay(text: String, line: String, expected: Bool) {
        #expect(Grounding.namesOnlyWhatWasSaid(text, evidence: line, names: ["Rishi", "Samantha"]) == expected)
    }

    @Test func substanceSeparatesThinMeetingsFromRealOnes() throws {
        let thin = Grounding.substance(Regression.transcript)
        let fixture = Grounding.substance(try Fixture.transcript())
        #expect(ReportShape(thin).isThin)
        #expect(!ReportShape(fixture).isThin)
        #expect(thin.speakers == 1 && fixture.speakers == 4)
    }

    // MARK: Positive: the fixture meeting

    @Test func legitimateFixtureItemsSurviveWithGroundedOwners() throws {
        let transcript = try Fixture.transcript()
        let raw = RawReport(
            title: "Planning",
            overview: "The team set the mobile app launch date.",
            topics: [RawTopic(title: "Launch date", summary: "Agreed Wednesday the fifteenth.", speakers: ["Daniel", "Sam", "Karen"])],
            decisions: [
                RawItem(text: "Launch on Wednesday the fifteenth (L5, L10)"),
                RawItem(text: "Start the quarterly planning review", lines: [1]),
            ],
            actionItems: [
                RawActionItem(task: "Send the updated budget to everyone", owner: "Rishi", due: "Friday", lines: [7]),
                // The asker named as owner: the evidence makes the person asked the owner.
                RawActionItem(task: "Share the press kit with the marketing team", owner: "Karen", due: "Monday", lines: [8]),
                RawActionItem(task: "Prepare the press kit", owner: "Samantha", due: nil, lines: [9]),
                RawActionItem(task: "Start the quarterly planning review", owner: "Daniel", due: nil, lines: [1]),
                RawActionItem(task: "Review the budget", owner: "Daniel", due: nil, lines: [42]),
            ],
            notesToRemember: [
                RawItem(text: "Marketing needs three weeks of notice before launch.", lines: [4]),
                RawItem(text: "Rishi will send the updated budget by Friday.", lines: [7]),
            ],
            corrections: [
                RawCorrection(speaker: "Karen", kind: "selfCorrection", original: "Tuesday the fourteenth", corrected: "Wednesday the fifteenth", lines: [5]),
                RawCorrection(speaker: "Rishi", kind: "mishearing", original: "Engineering is on track.", corrected: "Engineering is on track!", lines: [3]),
            ],
            participantSummaries: [
                RawParticipant(name: "Karen", keyPoints: [
                    RawItem(text: "Needs three weeks of notice", lines: [4]), RawItem(text: "Reviewed the budget", lines: [4]),
                ]),
                RawParticipant(name: "Dan", keyPoints: [RawItem(text: "Chaired", lines: [1])]),
            ])
        let report = ResultAssembler.report(
            from: raw, transcript: transcript, participants: try Fixture.speakers, meetingTitle: nil, generatedBy: "test")

        #expect(report.decisions == ["Launch on Wednesday the fifteenth"])
        #expect(report.actionItems.map(\.task) == ["Send the updated budget to everyone", "Share the press kit with the marketing team"])
        #expect(report.actionItems.map(\.owner) == ["Rishi", "Samantha"])
        #expect(report.actionItems.map(\.due) == ["Friday", "Monday"])
        // Rishi's own commitment; Karen's request to Samantha (Samantha's reply was not cited).
        #expect(report.actionItems.map(\.sourceSegmentID) == [Fixture.segmentID(6), Fixture.segmentID(7)])
        #expect(report.notesToRemember == ["Marketing needs three weeks of notice before launch."])
        #expect(report.corrections == [
            CorrectionNote(speaker: "Daniel", original: "Tuesday the fourteenth", corrected: "Wednesday the fifteenth", reason: "Daniel corrected themselves"),
        ])
        #expect(report.topics == [TopicSummary(title: "Launch date", summary: "Agreed Wednesday the fifteenth.", speakers: ["Daniel", "Karen"])])
        #expect(report.participantSummaries == [ParticipantSummary(name: "Karen", keyPoints: ["Needs three weeks of notice"])])
    }

    @Test func addresseeIsTheOnePersonNamedBeforeTheRequest() {
        let speakers = ["Maya", "Leo", "Priya"]
        let named = ContextLine(segmentID: UUID(), speaker: "Maya", time: 0, text: "Great. Leo, can you estimate the work once Priya's designs are ready?")
        #expect(ResultAssembler.addressee(of: named, among: speakers) == "Leo")
        let ambiguous = ContextLine(segmentID: UUID(), speaker: "Maya", time: 0, text: "Can you and Leo sync with Priya?")
        #expect(ResultAssembler.addressee(of: ambiguous, among: speakers) == nil)
    }

    @Test func uncitedFollowUpsMustBeSpecificAndDecisionsAreNotQuestions() throws {
        let raw = RawReport(
            decisions: [RawItem(text: "What's the launch date?", lines: [5]), RawItem(text: "Launch on Wednesday the fifteenth", lines: [10])],
            missedOpportunities: ["Discuss potential marketing strategies.", "Nobody checked the three weeks of marketing notice against the launch date."])
        let report = ResultAssembler.report(from: raw, transcript: try Fixture.transcript(), participants: [], meetingTitle: nil, generatedBy: "t")
        #expect(report.decisions == ["Launch on Wednesday the fifteenth"])
        #expect(report.missedOpportunities == ["Nobody checked the three weeks of marketing notice against the launch date."])
    }

    @Test func repeatedActionItemKeepsTheMajorityOwner() throws {
        let transcript = try Fixture.transcript()
        let task = "Share the press kit with the marketing team"
        let raw = RawReport(actionItems: [
            RawActionItem(task: task, owner: "Karen", due: "Monday", lines: [8, 9]),
            RawActionItem(task: "Send the updated budget", owner: "Rishi", due: "Friday", lines: [7]),
            RawActionItem(task: task, owner: "Samantha", due: "Monday", lines: [9]),
            RawActionItem(task: task + ".", owner: "Samantha", due: nil, lines: []),
        ])
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
            intent: "decision", correctedText: nil, suggestion: nil, actionItem: RawActionItem(task: "Thank all.", owner: "Daniel", due: nil))
        #expect(ResultAssembler.insight(from: thanks, utterance: t[9], context: Array(t[..<9])).actionItem == nil)

        let labelOnly = RawInsight(
            intent: "proposal", correctedText: nil, suggestion: nil,
            actionItem: RawActionItem(task: "Propose:", owner: "Samantha", due: "Wednesday the fifteenth"))
        #expect(ResultAssembler.insight(from: labelOnly, utterance: t[5], context: Array(t[..<5])).actionItem == nil)

        let request = RawInsight(
            intent: "request", correctedText: nil, suggestion: nil,
            actionItem: RawActionItem(task: "Share the press kit before the freeze", owner: "Karen", due: nil))
        let asked = ResultAssembler.insight(from: request, utterance: t[7], context: Array(t[..<7]))
        #expect(asked.actionItem?.owner == "Samantha")
        #expect(asked.actionItem?.task == "Share the press kit before the freeze")
    }

    @Test func inventedDueDatesAndEmptySuggestionsAreDropped() {
        let context = [ContextLine(segmentID: UUID(), speaker: "Karen", time: 20, text: "Can we have it by next Tuesday?")]
        let invented = RawInsight(
            intent: "commitment", correctedText: nil, suggestion: "Confirm:",
            actionItem: RawActionItem(task: "Send the budget", owner: "I", due: "Today at 10:00 AM."))
        let insight = ResultAssembler.insight(from: invented, utterance: utterance, context: context)
        // The invented time is dropped; the deadline the speaker actually said takes its place.
        #expect(insight.actionItem?.due == "Friday")
        #expect(insight.suggestion == nil)

        let fromContext = RawInsight(
            intent: "commitment", correctedText: nil, suggestion: "Ask: does Friday suit Karen?",
            actionItem: RawActionItem(task: "Send the budget", owner: "I", due: "next Tuesday"))
        let grounded = ResultAssembler.insight(from: fromContext, utterance: utterance, context: context)
        #expect(grounded.actionItem?.due == "next Tuesday")
        #expect(grounded.suggestion == "Ask: does Friday suit Karen?")
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
    @Test func reportDropsTimestampAndInventedDueDatesAndUncitedTasks() throws {
        let transcript = try Fixture.transcript()
        let raw = RawReport(actionItems: [
            RawActionItem(task: "Send the updated budget", owner: "Rishi", due: "00:34", lines: [7]),
            RawActionItem(task: "Share the press kit", owner: "Samantha", due: "[00:41]", lines: [9]),
            RawActionItem(task: "Book the venue", owner: "Karen", due: "End of quarter", lines: [8]),
            RawActionItem(task: "Send the updated budget", owner: "Rishi", due: "Friday", lines: [7]),
        ])
        let report = ResultAssembler.report(from: raw, transcript: transcript, participants: [], meetingTitle: nil, generatedBy: "test")
        #expect(report.actionItems.map(\.task) == ["Send the updated budget", "Share the press kit"])
        // The copied line time is dropped; Samantha's line says when.
        #expect(report.actionItems.map(\.due) == ["Friday", "Monday"])
    }

    @Test(arguments: [("me", "Rishi"), ("Samantha", "Samantha"), ("we", nil), ("The team", nil), ("", nil)] as [(String, String?)])
    func actionItemOwnerResolution(owner: String, expected: String?) {
        let raw = RawInsight(
            intent: "commitment", correctedText: nil, suggestion: nil, actionItem: RawActionItem(task: "Send the budget", owner: owner, due: nil))
        #expect(ResultAssembler.insight(from: raw, utterance: utterance).actionItem?.owner == expected)
    }

    @Test func reportCleansListsAndKeepsGivenTitle() throws {
        let transcript = try Fixture.transcript()
        let raw = RawReport(
            title: "Model title",
            overview: "Launch planning.",
            topics: [RawTopic(title: "Launch date", summary: nil, speakers: ["Daniel", "daniel", "Karen"]), RawTopic(title: nil, summary: "x", speakers: [])],
            decisions: [
                RawItem(text: "Launch on Wednesday the fifteenth.", lines: [10]),
                RawItem(text: "launch on wednesday the fifteenth", lines: [5]),
                RawItem(text: "", lines: [5]),
                RawItem(text: "Launch on Wednesday the fifteenth, uncited"),
            ],
            corrections: [RawCorrection(speaker: "Karen", kind: "mishearing", original: "Same text", corrected: "same text", lines: [4])])
        let report = ResultAssembler.report(
            from: raw, transcript: transcript, participants: ["Daniel", "Samantha", "Rishi", "Karen"],
            meetingTitle: "  Quarterly planning ", generatedBy: "Test")
        #expect(report.title == "Quarterly planning")
        #expect(report.topics == [TopicSummary(title: "Launch date", summary: "", speakers: ["Daniel", "Karen"])])
        #expect(report.decisions == ["Launch on Wednesday the fifteenth."])
        #expect(report.corrections.isEmpty)
        #expect(report.generatedBy == "Test")
    }

    @Test func reportTitleFallsBackToModelTitleThenGeneric() {
        let titled = RawReport(title: "Launch review")
        #expect(ResultAssembler.report(from: titled, transcript: [], participants: [], meetingTitle: " ", generatedBy: "T").title == "Launch review")
        #expect(ResultAssembler.report(from: RawReport(), transcript: [], participants: [], meetingTitle: nil, generatedBy: "T").title == "Meeting")
    }

    @Test func citedLinesDecodeLeniently() throws {
        let json = """
            {"decisions": [{"text": "A", "lines": ["L3", 4, "5", null]}, {"text": "B", "lines": "L3, L5"}, {"text": "C", "lines": 7}, "D"],
             "actionItems": [{"task": "T", "lines": [2.0]}]}
            """
        let raw = try JSONDecoder().decode(RawReport.self, from: Data(json.utf8))
        #expect(raw.decisions == [RawItem(text: "A", lines: [3, 4, 5]), RawItem(text: "B", lines: [3, 5]), RawItem(text: "C", lines: [7]), RawItem(text: "D")])
        #expect(raw.actionItems.map(\.lines) == [[2]])
    }
}

@Suite struct GroundingTests {
    @Test(arguments: [
        ("Can you introduce yourself?", [] as [Grounding.TaskCue]),
        ("And I would like to, 1st of all, say thank you for attending to this meeting.", []),
        ("Let's get started with the quarterly planning review.", []),
        ("Can you introduce the new design to the board by Friday?", [.request]),
        ("Samantha, can you share the press kit with my team before the freeze?", [.request]),
        ("Agreed. I will send the updated budget to everyone by Friday.", [.commitment]),
        ("Will do.", [.commitment]),
        ("Let's ship the webhook fix in Thursday's release, not as a hotfix.", [.group]),
    ] as [(String, [Grounding.TaskCue])])
    func taskCues(text: String, expected: [Grounding.TaskCue]) {
        #expect(Grounding.taskCues(text) == expected)
    }

    @Test(arguments: [
        ("Agreed. I will send the updated budget to everyone by Friday.", "Friday"),
        ("Samantha, can you share the press kit with my team before the freeze?", "before the freeze"),
        ("Okay. Tom, please send finance the list of affected accounts today.", "today"),
        ("Sure, I'll book them this week.", "this week"),
        ("Let's freeze features by the end of this month.", "the end of this month"),
        ("The fix for the webhook is already in review, by the way.", nil),
        ("Send it by email.", nil),
    ] as [(String, String?)])
    func deadlines(text: String, expected: String?) {
        #expect(Grounding.deadline(in: text) == expected)
    }

    @Test(arguments: [
        ("Who's covering support while they're away is still open; we'll figure that out next week.", false),
        ("Let's get started with the quarterly planning review.", false),
        ("Hey, this is, uh, a meeting.", false),
        ("So let's target the launch for Tuesday the fourteenth, sorry, I mean Wednesday the fifteenth.", true),
        ("Great. Decision made, we launch on Wednesday the fifteenth. Thanks all.", true),
        ("Agreed, Thursday's release.", true),
    ])
    func decisionCues(text: String, expected: Bool) {
        #expect(Grounding.hasDecisionCue(text) == expected)
    }

    @Test(arguments: [
        ("Who's covering support while they're away is still open.", true),
        ("Um, so what's the budget", true),
        ("For us to be able to discuss some very crucial matter, that touches every subject.", false),
    ])
    func questions(text: String, expected: Bool) {
        #expect(Grounding.isQuestion(text) == expected)
    }

    @Test func contentWordsIgnoreFillersGreetingsAndLogisticsAndMatchByStem() {
        #expect(Grounding.contentStems("Hey, uh, thanks everyone for attending the meeting.").isEmpty)
        #expect(Grounding.sharesContent("Introduce the estimates", with: "Leo will estimate the work") == true)
        #expect(Grounding.sharesContent("Thank attendees", with: "Thank you for attending to this meeting.") == false)
        #expect(Grounding.fluent("Um, I don't, I don't really know.") == ["i", "don", "t", "really", "know"])
    }
}

/// The user's failing one-minute meeting and the report the on-device model wrote for it.
enum Regression {
    static let transcript: [ContextLine] = [
        (1, "Hey, this is, uh, a meeting."),
        (5, "For us to be able to discuss some very crucial matter, that touches every subject."),
        (16, "And I would like to, 1st of all, say thank you for attending to this meeting."),
        (24, "He's been very important to have this discussion."),
        (34, "Hmm."),
        (35, "Can you introduce yourself?"),
        (42, "Um, I don't, I don't really know."),
        (46, "Um... what it takes... to put this together."),
    ].enumerated().map { index, line in
        ContextLine(segmentID: Fixture.segmentID(100 + index), speaker: "Ayo", time: line.0, text: line.1)
    }

    /// The bad report, citing plausible lines (or every line, the worst case for grounding).
    static func badReport(citeEverything: Bool) -> RawReport {
        func cite(_ lines: Int...) -> [Int] { citeEverything ? Array(1...8) : lines }
        return RawReport(
            title: "Meeting",
            overview: "Ayo opened a meeting about a crucial matter and thanked everyone for attending. He asked someone to introduce themselves. The meeting ended before the matter was discussed.",
            topics: [
                RawTopic(title: "Introduction", summary: "Ayo introduced the meeting and thanked attendees.", speakers: ["Ayo"]),
                RawTopic(title: "Discussion", summary: "Ayo asked for introductions.", speakers: ["Ayo", "Speaker 1"]),
            ],
            decisions: [RawItem(text: "Introductions", lines: cite(6))],
            actionItems: [
                RawActionItem(task: "Introduce yourself", owner: "Speaker 1", due: nil, lines: cite(6)),
                RawActionItem(task: "Discuss the matter", owner: "Speaker 1", due: nil, lines: cite(2)),
                RawActionItem(task: "Thank attendees", owner: "Ayo", due: nil, lines: cite(3)),
                RawActionItem(task: "Introduce the discussion", owner: "Ayo", due: nil, lines: cite(4)),
                RawActionItem(task: "Ask for introductions", owner: "Ayo", due: nil, lines: cite(6)),
                RawActionItem(task: "Thank the speaker", owner: "Ayo", due: nil, lines: cite(3)),
            ],
            notesToRemember: [
                RawItem(text: "Thank attendees", lines: cite(3)), RawItem(text: "Introduce the discussion", lines: cite(4)),
                RawItem(text: "Ask for introductions", lines: cite(6)), RawItem(text: "Thank the speaker", lines: cite(3)),
            ],
            missedOpportunities: ["Ayo could have asked for introductions earlier.", "Ayo could have thanked the speaker earlier."],
            openQuestions: [RawItem(text: "Who is the speaker?", lines: cite(6)), RawItem(text: "What is the matter?", lines: cite(2))],
            corrections: [
                RawCorrection(speaker: "Ayo", kind: "mishearing", original: "Hey, this is, uh, a meeting.", corrected: "Hey, this is a meeting.", lines: cite(1)),
                RawCorrection(speaker: "Ayo", kind: "selfCorrection", original: "Um, I don't, I don't really know.", corrected: "I don't know who I am.", lines: cite(7)),
            ],
            participantSummaries: [
                RawParticipant(name: "Ayo", keyPoints: [
                    RawItem(text: "Introduced the meeting.", lines: cite(1)), RawItem(text: "Thanked attendees.", lines: cite(3)),
                    RawItem(text: "Asked for introductions.", lines: cite(6)), RawItem(text: "Thanked the speaker.", lines: cite(3)),
                ]),
                RawParticipant(name: "Speaker 1", keyPoints: [
                    RawItem(text: "Introduced the discussion.", lines: cite(4)), RawItem(text: "Asked for introductions.", lines: cite(6)),
                ]),
            ])
    }
}
