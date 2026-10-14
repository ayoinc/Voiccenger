import Foundation
import VCModels

// The conversation outline: grounded points in order, segments that cover the whole meeting, and stretches the
// model left out filled in from the transcript.

extension ResultAssembler {
    /// Lines within this distance of a cited line count as covered by the point citing it.
    static let outlineReach = 2

    /// A grounded outline point; `lines` are 0-based transcript indices, ascending.
    struct DraftPoint: Equatable {
        var speaker: String
        var text: String
        var lines: [Int]
        var isQuote: Bool
    }

    /// A segment while it is being built; its first point's first line is where it starts.
    struct DraftSegment: Equatable {
        var heading: String?
        var points: [DraftPoint]
        var isExtracted: Bool

        var first: Int { points.map { $0.lines[0] }.min() ?? 0 }
        var last: Int { points.flatMap(\.lines).max() ?? 0 }

        mutating func add(_ more: [DraftPoint]) {
            points = (points + more).sorted { $0.lines[0] < $1.lines[0] }
        }
    }

    /// The model's outline, checked against the transcript:
    /// - every point is one speaker's, cites that speaker's own lines (not small talk), shares content words
    ///   with them and does not call a promise done (`groundedPoint`); points failing that are dropped;
    /// - segments are put in transcript order; one starting inside another is merged into it when both fit;
    /// - unless the meeting is thin, every substantive line must lie within `outlineReach` lines of a cited line:
    ///   a stretch nobody cited gets the speakers' most informative sentences from the transcript, quoted, in the
    ///   segment around it, or as a segment of its own when it is long (`ownSegmentLines`);
    /// - thin segments then merge into a neighbour, and neighbours merge down to about one segment per three
    ///   minutes (`consolidated`);
    /// - segments cover the whole meeting: each runs from its first cited line to the line before the next.
    /// A heading that shares no content word with its segment's lines is replaced by the segment's own words.
    static func outline(_ raw: [RawOutlineSegment], evidence: Evidence, shape: ReportShape) -> [OutlineSegment] {
        let transcript = evidence.transcript
        guard !transcript.isEmpty, shape.outlineSegments > 0 else { return [] }
        var seen = Set<String>()
        var drafts: [DraftSegment] = raw.compactMap { segment in
            let points = segment.points.compactMap { groundedOutlinePoint($0, evidence: evidence) }
                .filter { seen.insert(comparable($0.text)).inserted }
            guard !points.isEmpty else { return nil }
            var draft = DraftSegment(heading: segment.heading, points: [], isExtracted: false)
            draft.add(points)
            return draft
        }
        drafts = ordered(drafts, maximumPoints: shape.outlinePoints)
        if shape.isThin {
            drafts = Array(drafts.prefix(1)).map { DraftSegment(heading: $0.heading, points: Array($0.points.prefix(shape.outlinePoints)), isExtracted: false) }
        } else {
            drafts = consolidated(filled(drafts, transcript: transcript, maximumPoints: shape.outlinePoints), transcript: transcript)
        }
        return segments(Array(drafts.prefix(shape.outlineSegments)), transcript: transcript)
    }

    /// The lines each draft covers in the final outline: from its first cited line (the first draft from line 0)
    /// to the line before the next draft.
    static func spans(_ drafts: [DraftSegment], lineCount: Int) -> [Range<Int>] {
        let starts = drafts.indices.map { $0 == 0 ? 0 : drafts[$0].first }
        return drafts.indices.map { starts[$0]..<($0 + 1 < drafts.count ? starts[$0 + 1] : lineCount) }
    }

    /// Drafts merged by `TranscriptOutliner.mergeGroups`: thin ones (few substantive lines, or only quotes filled in
    /// from the transcript) into their closer neighbour, then the closest neighbours until the meeting has about
    /// one segment per three minutes. A merged segment keeps every point (so the coverage holds) and the heading of
    /// the member the model wrote (not filled in from the transcript) with the most points of the model's own, then
    /// the most points, then the most substantive lines.
    static func consolidated(_ drafts: [DraftSegment], transcript: [ContextLine]) -> [DraftSegment] {
        guard drafts.count > 1 else { return drafts }
        let ranges = spans(drafts, lineCount: transcript.count)
        let groups = TranscriptOutliner.mergeGroups(ranges, weak: drafts.map(\.isExtracted), transcript: transcript)
        func rank(_ i: Int) -> [Int] {
            [drafts[i].isExtracted ? 0 : 1, drafts[i].points.filter { !$0.isQuote }.count, drafts[i].points.count,
             TranscriptOutliner.substantiveLines(ranges[i], of: transcript)]
        }
        return groups.map { group in
            let members = group.map { drafts[$0] }
            let lead = group.max { rank($0).lexicographicallyPrecedes(rank($1)) }!
            var merged = DraftSegment(heading: drafts[lead].heading, points: [], isExtracted: members.allSatisfy(\.isExtracted))
            merged.add(members.flatMap(\.points))
            return merged
        }
    }

    /// An outline point the transcript supports, attributed to a speaker who spoke. A leading "Name:" is the
    /// attribution; without a usable speaker the point is the cited lines' speaker's when they all share one.
    /// A point that is itself small talk ("Thanks Daniel.", "Wednesday works.") says nothing and is dropped; one
    /// copied from a cited line is kept as a quote.
    static func groundedOutlinePoint(_ raw: RawOutlinePoint, evidence: Evidence) -> DraftPoint? {
        guard let written = raw.text else { return nil }
        let (body, numbers) = Evidence.citation(in: written)
        var text = body
        var speaker = raw.speaker.flatMap(evidence.speaker)
        if let colon = text.firstIndex(of: ":"), let named = evidence.speaker(String(text[..<colon])) {
            speaker = named
            text = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard !Grounding.isSmallTalk(text) else { return nil }
        let cited = evidence.numbers(raw.lines + numbers)
        // Only an unattributed point takes its lines' speaker; one naming someone who never spoke is not reassigned.
        let named = raw.speaker.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        if speaker == nil, !named {
            let owners = deduplicated(cited.map { evidence.transcript[$0 - 1].speaker })
            speaker = owners.count == 1 ? evidence.speaker(owners[0]) : nil
        }
        guard let speaker, let grounded = groundedPoint(RawItem(text: text, lines: cited), by: speaker, evidence: evidence) else { return nil }
        let lines = grounded.lines.map { $0 - 1 }.sorted()
        let copied = lines.contains { comparable(evidence.transcript[$0].text).contains(comparable(grounded.text)) }
        return DraftPoint(speaker: speaker, text: grounded.text, lines: lines, isQuote: copied)
    }

    /// Drafts in transcript order; a draft starting inside the previous one joins it when they fit together
    /// (and always when both start on the same line, keeping the earliest points).
    static func ordered(_ drafts: [DraftSegment], maximumPoints: Int) -> [DraftSegment] {
        var result: [DraftSegment] = []
        for draft in drafts.sorted(by: { $0.first < $1.first }) {
            if var previous = result.last, draft.first <= previous.last,
                previous.points.count + draft.points.count <= maximumPoints || draft.first == previous.first
            {
                previous.add(draft.points)
                previous.points = Array(previous.points.prefix(maximumPoints))
                result[result.count - 1] = previous
            } else {
                result.append(draft)
            }
        }
        return result
    }

    /// Stretches of substantive lines no point covers, as index ranges from the first to the last uncovered
    /// substantive line; a covered line ends a stretch.
    static func uncoveredStretches(_ drafts: [DraftSegment], transcript: [ContextLine]) -> [(range: ClosedRange<Int>, substantive: Int)] {
        var covered = Set<Int>()
        for line in drafts.flatMap({ $0.points.flatMap(\.lines) }) {
            covered.formUnion(max(0, line - outlineReach)...min(transcript.count - 1, line + outlineReach))
        }
        var stretches: [(range: ClosedRange<Int>, substantive: Int)] = []
        var current: (first: Int, last: Int, count: Int)?
        for index in transcript.indices {
            if covered.contains(index) {
                if let open = current { stretches.append((open.first...open.last, open.count)) }
                current = nil
            } else if TranscriptOutliner.isSubstantive(transcript[index].text) {
                current = current.map { ($0.first, index, $0.count + 1) } ?? (index, index, 1)
            }
        }
        if let open = current { stretches.append((open.first...open.last, open.count)) }
        return stretches
    }

    /// A stretch the model skipped needs this many substantive lines to become a segment of its own.
    static let ownSegmentLines = 6

    /// `drafts` with every uncovered stretch filled from the transcript, repeating until every substantive line is
    /// covered. A stretch joins the segment whose span it falls in (or the one before it); only a long stretch
    /// (`ownSegmentLines` substantive lines or more) becomes a segment of its own, splitting a segment it falls
    /// inside into it and its continuation. A stretch without a quotable sentence quotes its first substantive line.
    static func filled(_ drafts: [DraftSegment], transcript: [ContextLine], maximumPoints: Int) -> [DraftSegment] {
        var drafts = drafts
        let vocabulary = TranscriptOutliner.Vocabulary(transcript)
        // Every pass covers at least one more line, so this many passes always suffice.
        for _ in transcript.indices {
            guard let stretch = uncoveredStretches(drafts, transcript: transcript).first else { break }
            let range = stretch.range.lowerBound..<(stretch.range.upperBound + 1)
            let limit = min(maximumPoints, max(1, stretch.substantive / 2))
            var quotes = TranscriptOutliner.points(in: range, of: transcript, vocabulary: vocabulary, limit: limit).compactMap { point in
                transcript.firstIndex { $0.segmentID == point.segmentIDs.first }.map {
                    DraftPoint(speaker: point.speaker, text: point.text, lines: [$0], isQuote: true)
                }
            }
            if quotes.isEmpty, let line = range.first(where: { TranscriptOutliner.isSubstantive(transcript[$0].text) }) {
                quotes = [DraftPoint(speaker: transcript[line].speaker, text: TranscriptOutliner.cleaned(transcript[line].text), lines: [line], isQuote: true)]
            }
            // The draft whose span (first cited line up to the next draft) holds the stretch, else the first one.
            let holder = drafts.lastIndex { $0.first <= range.lowerBound } ?? (drafts.isEmpty ? nil : 0)
            if stretch.substantive < Self.ownSegmentLines, let holder {
                drafts[holder].add(quotes)
                continue
            }
            let own = DraftSegment(
                heading: TranscriptOutliner.heading(of: range, in: transcript, vocabulary: vocabulary),
                points: quotes.sorted { $0.lines[0] < $1.lines[0] }, isExtracted: true)
            if let holder, drafts[holder].first < range.lowerBound, drafts[holder].last > range.upperBound - 1 {
                // Split the holder around the stretch.
                var continuation = drafts[holder]
                continuation.points = drafts[holder].points.filter { $0.lines[0] >= range.upperBound }
                continuation.heading = drafts[holder].heading.map { "\($0) (continued)" }
                drafts[holder].points = drafts[holder].points.filter { $0.lines[0] < range.lowerBound }
                drafts.insert(contentsOf: [own, continuation].filter { !$0.points.isEmpty }, at: holder + 1)
            } else {
                drafts.append(own)
            }
            drafts = drafts.filter { !$0.points.isEmpty }.sorted { $0.first < $1.first }
        }
        return drafts
    }

    /// Final segments covering every line: each runs from its first cited line (the first from line 0) to the
    /// line before the next segment.
    static func segments(_ drafts: [DraftSegment], transcript: [ContextLine]) -> [OutlineSegment] {
        let vocabulary = TranscriptOutliner.Vocabulary(transcript)
        let ranges = spans(drafts, lineCount: transcript.count)
        return drafts.indices.map { i in
            let range = ranges[i]
            let draft = drafts[i]
            let spoken = Evidence.joined(Array(transcript[range]))
            let heading = draft.heading.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                .flatMap { Grounding.sharesContent($0, with: spoken) ? $0 : nil }
                ?? TranscriptOutliner.heading(of: range, in: transcript, vocabulary: vocabulary)
            let (start, end) = TranscriptOutliner.times(of: range, in: transcript)
            let points = draft.points.map { point in
                OutlinePoint(
                    speaker: point.speaker, text: point.text, time: transcript[point.lines[0]].time,
                    segmentIDs: point.lines.map { transcript[$0].segmentID }, isQuote: point.isQuote)
            }
            return OutlineSegment(heading: heading, start: start, end: end, points: points, isExtracted: draft.isExtracted)
        }
    }
}
