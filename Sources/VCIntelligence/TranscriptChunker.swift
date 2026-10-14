import Foundation
import VCModels

/// Conservative token estimate used to size requests before they are sent.
///
/// Measured on the on-device model: meeting transcript lines run at ~3.6 UTF-8 bytes per token,
/// so 3 bytes per token over-estimates by ~20%, which keeps chunks safely inside the window.
public enum TokenEstimator {
    public static func estimate(_ text: String) -> Int {
        (text.utf8.count + 2) / 3
    }
}

/// Splits a transcript into consecutive chunks that fit a token budget without ever splitting a line.
public enum TranscriptChunker {
    /// Every line lands in exactly one chunk, in order. A chunk exceeds `tokenBudget` only when it
    /// holds a single line that is by itself larger than the budget.
    public static func chunk(
        _ lines: [NumberedLine], tokenBudget: Int, cost: (NumberedLine) -> Int = defaultCost
    ) -> [[NumberedLine]] {
        precondition(tokenBudget > 0, "tokenBudget must be positive")
        var chunks: [[NumberedLine]] = []
        var current: [NumberedLine] = []
        var used = 0
        for line in lines {
            let lineCost = cost(line)
            if !current.isEmpty, used + lineCost > tokenBudget {
                chunks.append(current)
                current = []
                used = 0
            }
            current.append(line)
            used += lineCost
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// As many chunks as `chunk` makes, but of about equal cost, so no chunk is a short tail without the context
    /// of its subject. A chunk still exceeds `tokenBudget` only when one line alone does.
    public static func balancedChunk(
        _ lines: [NumberedLine], tokenBudget: Int, cost: (NumberedLine) -> Int = defaultCost
    ) -> [[NumberedLine]] {
        let greedy = chunk(lines, tokenBudget: tokenBudget, cost: cost)
        guard greedy.count > 1 else { return greedy }
        let target = Double(lines.reduce(0) { $0 + cost($1) }) / Double(greedy.count)
        var chunks: [[NumberedLine]] = []
        var current: [NumberedLine] = []
        var used = 0
        for line in lines {
            let lineCost = cost(line)
            // Close at the budget, or (while chunks remain to fill) once the line would take the chunk further past
            // the target than it stays short of it.
            let overBudget = used + lineCost > tokenBudget
            let pastTarget = Double(used) + Double(lineCost) / 2 > target && chunks.count < greedy.count - 1
            if !current.isEmpty, overBudget || pastTarget {
                chunks.append(current)
                current = []
                used = 0
            }
            current.append(line)
            used += lineCost
        }
        if !current.isEmpty { chunks.append(current) }
        // An uneven split can need one chunk more than greedy filling; greedy is then the better answer.
        return chunks.count <= greedy.count ? chunks : greedy
    }

    /// Estimated cost of a line as it appears in a prompt, including its newline.
    public static func defaultCost(_ line: NumberedLine) -> Int {
        TokenEstimator.estimate(TranscriptFormatter.format(line)) + 1
    }

    /// Estimated cost of a context line as it appears in a live-analysis prompt (numbered), including its newline.
    public static func defaultCost(_ line: ContextLine) -> Int {
        TokenEstimator.estimate(TranscriptFormatter.format(line)) + 3
    }

    /// Splits any line costing more than `maxTokens` into consecutive word-boundary pieces that keep the
    /// line's number, segment, speaker and time, so no single line can overflow a chunk. Words are never cut.
    public static func splitLongLines(_ lines: [NumberedLine], maxTokens: Int, cost: (NumberedLine) -> Int = defaultCost) -> [NumberedLine] {
        precondition(maxTokens > 0, "maxTokens must be positive")
        var result: [NumberedLine] = []
        result.reserveCapacity(lines.count)
        for line in lines {
            guard cost(line) > maxTokens else {
                result.append(line)
                continue
            }
            var piece = line
            piece.line.text = ""
            for word in line.line.text.split(whereSeparator: \.isWhitespace) {
                var candidate = piece
                candidate.line.text = piece.line.text.isEmpty ? String(word) : piece.line.text + " " + word
                if !piece.line.text.isEmpty, cost(candidate) > maxTokens {
                    result.append(piece)
                    piece.line.text = String(word)
                } else {
                    piece = candidate
                }
            }
            if !piece.line.text.isEmpty { result.append(piece) }
        }
        return result
    }

    /// The most recent lines whose total cost fits `tokenBudget`, in original order.
    static func tail(_ lines: [ContextLine], tokenBudget: Int, cost: (ContextLine) -> Int = defaultCost) -> [ContextLine] {
        var used = 0
        var start = lines.endIndex
        while start > lines.startIndex {
            let lineCost = cost(lines[start - 1])
            if used + lineCost > tokenBudget { break }
            used += lineCost
            start -= 1
        }
        return Array(lines[start...])
    }
}
