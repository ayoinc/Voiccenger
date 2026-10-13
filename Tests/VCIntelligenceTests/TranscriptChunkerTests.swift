import Foundation
import Testing
import VCModels
@testable import VCIntelligence

@Suite struct TranscriptChunkerTests {
    @Test(arguments: [40, 120, 400, 5_000])
    func chunksCoverTranscriptInOrderWithinBudget(budget: Int) throws {
        let transcript = NumberedLine.numbering(try Fixture.transcript())
        let chunks = TranscriptChunker.chunk(transcript, tokenBudget: budget)

        #expect(chunks.flatMap { $0 } == transcript)
        #expect(chunks.allSatisfy { !$0.isEmpty })
        for chunk in chunks {
            let cost = chunk.reduce(0) { $0 + TranscriptChunker.defaultCost($1) }
            // Over budget only when one line alone is larger than the budget.
            #expect(cost <= budget || chunk.count == 1)
        }
        // Greedy packing: the next chunk's first line would not have fitted in the previous chunk.
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            let used = previous.reduce(0) { $0 + TranscriptChunker.defaultCost($1) }
            #expect(used + TranscriptChunker.defaultCost(next[0]) > budget)
        }
    }

    @Test func wholeTranscriptFitsOneChunkWhenBudgetAllows() throws {
        let transcript = NumberedLine.numbering(try Fixture.transcript())
        let total = transcript.reduce(0) { $0 + TranscriptChunker.defaultCost($1) }
        #expect(TranscriptChunker.chunk(transcript, tokenBudget: total).count == 1)
        #expect(TranscriptChunker.chunk(transcript, tokenBudget: total - 1).count == 2)
        #expect(TranscriptChunker.chunk([], tokenBudget: 10).isEmpty)
    }

    @Test func splitLongLinesKeepsEveryWordNumberAndMetadata() {
        let id = UUID()
        let words = (1...400).map { "word\($0)" }
        let long = ContextLine(segmentID: id, speaker: "Karen", time: 754, text: words.joined(separator: "  \n"))
        let short = ContextLine(segmentID: UUID(), speaker: "Rishi", time: 760, text: "Agreed.")
        let maxTokens = 60

        let pieces = TranscriptChunker.splitLongLines(NumberedLine.numbering([long, short]), maxTokens: maxTokens)

        #expect(pieces.count > 2)
        #expect(pieces.last == NumberedLine(number: 2, line: short))
        let longPieces = pieces.dropLast()
        #expect(longPieces.allSatisfy { TranscriptChunker.defaultCost($0) <= maxTokens })
        #expect(longPieces.allSatisfy { $0.number == 1 && $0.line.segmentID == id && $0.line.speaker == "Karen" && $0.line.time == 754 })
        #expect(longPieces.flatMap { $0.line.text.split(separator: " ").map(String.init) } == words)
    }

    @Test func splitLongLinesKeepsOversizedSingleWordWhole() {
        let word = String(repeating: "x", count: 900)
        let line = ContextLine(segmentID: UUID(), speaker: "A", time: 0, text: "a \(word) b")
        let pieces = TranscriptChunker.splitLongLines(NumberedLine.numbering([line]), maxTokens: 50)
        #expect(pieces.map(\.line.text) == ["a", word, "b"])
    }

    @Test func tailKeepsMostRecentLinesWithinBudget() throws {
        let transcript = try Fixture.transcript()
        let budget = 100
        let tail = TranscriptChunker.tail(transcript, tokenBudget: budget)

        #expect(!tail.isEmpty)
        #expect(Array(transcript.suffix(tail.count)) == tail)
        #expect(tail.reduce(0) { $0 + TranscriptChunker.defaultCost($1) } <= budget)
        let withOneMore = transcript.suffix(tail.count + 1).reduce(0) { $0 + TranscriptChunker.defaultCost($1) }
        #expect(withOneMore > budget)
    }

    @Test func tokenEstimateOverestimatesMeasuredRatio() {
        // Measured ~3.6 bytes per token on the on-device model; the estimate must never undershoot that.
        let text = "[12:04] Karen: We should move the launch to Wednesday the fifteenth."
        #expect(TokenEstimator.estimate(text) >= Int((Double(text.utf8.count) / 3.6).rounded(.up)))
        #expect(TokenEstimator.estimate("") == 0)
    }
}
