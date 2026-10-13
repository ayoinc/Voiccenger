import Foundation
import Testing
@testable import VCIntelligence

@Suite struct ReportNotesTests {
    static func bulkyNotes(items: Int) -> RawReport {
        let list = (1...items).map { "Item \($0): a fact about the launch plan worth keeping in mind." }
        let cited = list.enumerated().map { RawItem(text: $1, lines: [$0 + 1]) }
        return RawReport(
            title: "Launch",
            overview: "The team set the launch date. Marketing wants notice. Engineering is on track.",
            topics: (1...items).map { RawTopic(title: "Topic \($0)", summary: "Summary \($0).", speakers: ["Daniel"]) },
            decisions: cited,
            actionItems: (1...items).map { RawActionItem(task: "Task \($0)", owner: "Rishi", due: "Friday", lines: [7]) },
            notesToRemember: cited,
            missedOpportunities: list,
            openQuestions: cited,
            corrections: (1...items).map {
                RawCorrection(speaker: "Daniel", kind: "selfCorrection", original: "Tuesday \($0)", corrected: "Wednesday \($0)", lines: [5])
            },
            participantSummaries: [RawParticipant(name: "Karen", keyPoints: cited)])
    }

    @Test func renderListsEverySectionAndSkipsEmptyOnes() {
        var notes = Self.bulkyNotes(items: 1)
        notes.openQuestions = []
        let text = ReportNotes.render(notes)
        #expect(text.contains("Overview: The team set the launch date."))
        #expect(text.contains("- Item 1: a fact about the launch plan worth keeping in mind. (L1)"))
        #expect(text.contains("- Task 1 | owner: Rishi | due: Friday (L7)"))
        #expect(text.contains("- Daniel: \"Tuesday 1\" -> \"Wednesday 1\" [selfCorrection] (L5)"))
        #expect(text.contains("- Karen: Item 1: a fact about the launch plan worth keeping in mind. (L1)"))
        #expect(!text.contains("Open questions"))
    }

    @Test func compactionShrinksMonotonicallyAndTerminates() {
        var notes = Self.bulkyNotes(items: 37)
        var previousCost = AppleIntelligenceEngine.cost(of: notes)
        var steps = 0
        while let smaller = ReportNotes.compacted(notes) {
            let cost = AppleIntelligenceEngine.cost(of: smaller)
            #expect(cost < previousCost)
            // Keeps the earliest items of every list.
            #expect(smaller.decisions == Array(notes.decisions.prefix(smaller.decisions.count)))
            previousCost = cost
            notes = smaller
            steps += 1
        }
        #expect(steps <= 8)
        #expect(notes.decisions.count == 1)
        #expect(notes.overview == "The team set the launch date.")
    }

    @Test func fittedRespectsLimitOrThrows() throws {
        let notes = Self.bulkyNotes(items: 40)
        let limit = 300
        let fitted = try AppleIntelligenceEngine.fitted(notes, within: limit)
        #expect(AppleIntelligenceEngine.cost(of: fitted) <= limit)
        #expect(AppleIntelligenceEngine.cost(of: notes) > limit)

        #expect(throws: IntelligenceError.contextWindowExceeded) {
            try AppleIntelligenceEngine.fitted(notes, within: 10)
        }
    }
}
