import Foundation
import VCModels

/// Something the live analysis wants the user to see while the meeting is running.
public struct AttentionItem: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case correction
        case suggestion
        case actionItem
    }

    public let id: UUID
    public let kind: Kind
    public let segmentID: UUID
    public let speakerKey: String
    /// Session time of the utterance.
    public let time: TimeInterval
    /// What was said.
    public let utterance: String
    /// The proposed correction, suggestion text, or action item task.
    public let text: String
    /// Correction reason, or "owner · due" for action items.
    public let detail: String?

    public init(
        id: UUID = UUID(), kind: Kind, segmentID: UUID, speakerKey: String, time: TimeInterval, utterance: String,
        text: String, detail: String?
    ) {
        self.id = id
        self.kind = kind
        self.segmentID = segmentID
        self.speakerKey = speakerKey
        self.time = time
        self.utterance = utterance
        self.text = text
        self.detail = detail
    }

    /// Items worth surfacing for one analysed segment, in display order.
    public static func items(for insight: UtteranceInsight, segment: TranscriptSegment) -> [AttentionItem] {
        var items: [AttentionItem] = []
        if let corrected = insight.correctedText?.nonEmpty {
            items.append(
                AttentionItem(
                    kind: .correction, segmentID: segment.id, speakerKey: segment.speakerKey,
                    time: segment.range.start, utterance: segment.text, text: corrected,
                    detail: insight.correctionReason?.nonEmpty))
        }
        if let suggestion = insight.suggestion?.nonEmpty {
            items.append(
                AttentionItem(
                    kind: .suggestion, segmentID: segment.id, speakerKey: segment.speakerKey,
                    time: segment.range.start, utterance: segment.text, text: suggestion, detail: nil))
        }
        if let action = insight.actionItem, let task = action.task.nonEmpty {
            let detail = [action.owner?.nonEmpty, action.due?.nonEmpty].compactMap { $0 }.joined(separator: " · ")
            items.append(
                AttentionItem(
                    kind: .actionItem, segmentID: segment.id, speakerKey: segment.speakerKey,
                    time: segment.range.start, utterance: segment.text, text: task,
                    detail: detail.isEmpty ? nil : detail))
        }
        return items
    }
}
