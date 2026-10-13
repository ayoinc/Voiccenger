import SwiftUI
import UniformTypeIdentifiers
import VCPipeline

// MARK: - Colours and formatting

enum ParticipantPalette {
    private static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .red, .mint, .brown, .cyan, .yellow]

    static func color(_ index: Int) -> Color { colors[((index % colors.count) + colors.count) % colors.count] }
}

enum Format {
    static func localeName(_ id: String?) -> String {
        guard let id else { return "Unknown" }
        return Locale.current.localizedString(forIdentifier: id) ?? id
    }

    static func timestamp(_ t: TimeInterval) -> String { ReportRenderer.timestamp(t) }

    static func duration(_ d: TimeInterval) -> String {
        Duration.seconds(max(0, d)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }

    static func degrees(_ d: Double) -> String { "\(Int(d.rounded()))°" }
}

// MARK: - Small views

struct ParticipantDot: View {
    let colorIndex: Int
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(ParticipantPalette.color(colorIndex))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Horizontal input level meter driven by an RMS value (0…1), shown on a dBFS scale.
struct LevelMeter: View {
    let rms: Double

    private var fraction: Double {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db + 60) / 60))
    }

    var body: some View {
        Gauge(value: fraction) { Text("Input level") }
            .gaugeStyle(.accessoryLinearCapacity)
            .tint(Gradient(colors: [.green, .yellow, .red]))
            .animation(.linear(duration: 0.1), value: fraction)
            .accessibilityLabel("Input level")
            .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

/// Top-down view of a microphone array with each participant's seat and the live direction of arrival.
/// Azimuths are degrees counter-clockwise from the array's +x axis, drawn with +x pointing right and +y up.
struct SeatCompass: View {
    struct Marker: Identifiable {
        let id: String
        let label: String
        let azimuth: Double
        let colorIndex: Int
    }

    let markers: [Marker]
    let liveAzimuth: Double?
    var liveConfidence: Double = 1

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let radius = side / 2 - 28
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            ZStack {
                Circle()
                    .strokeBorder(.separator, lineWidth: 1)
                    .frame(width: radius * 2, height: radius * 2)
                    .position(center)
                ForEach([0.0, 90, 180, 270], id: \.self) { angle in
                    Text(Format.degrees(angle))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .position(point(center, radius + 16, angle))
                }
                Image(systemName: "mic.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .position(center)
                if let liveAzimuth {
                    Path { p in
                        p.move(to: center)
                        p.addLine(to: point(center, radius, liveAzimuth))
                    }
                    .stroke(Color.accentColor.opacity(0.35 + 0.65 * min(1, max(0, liveConfidence))), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .animation(.easeOut(duration: 0.2), value: liveAzimuth)
                }
                ForEach(markers) { marker in
                    VStack(spacing: 2) {
                        ParticipantDot(colorIndex: marker.colorIndex, size: 14)
                        Text(marker.label)
                            .font(.caption2)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .position(point(center, radius, marker.azimuth))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(marker.label), seat at \(Format.degrees(marker.azimuth))")
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Seat compass")
        .accessibilityValue(liveAzimuth.map { "Current speaker at \(Format.degrees($0))" } ?? "No direction")
    }

    private func point(_ center: CGPoint, _ r: CGFloat, _ degrees: Double) -> CGPoint {
        let a = degrees * .pi / 180
        return CGPoint(x: center.x + r * cos(a), y: center.y - r * sin(a))
    }
}

/// Status symbol for the menu bar and window toolbar.
struct StatusSymbol {
    static func name(for status: MeetingCoordinator.Status) -> String {
        switch status {
        case .idle: "waveform.circle"
        case .detected: "waveform.badge.exclamationmark"
        case .recording: "record.circle.fill"
        case .finishing: "hourglass.circle"
        }
    }

    static func label(for status: MeetingCoordinator.Status) -> String {
        switch status {
        case .idle: "Idle"
        case .detected: "Meeting detected"
        case .recording: "Recording"
        case .finishing: "Finishing"
        }
    }
}

// MARK: - Export

extension UTType {
    /// Markdown (`UTType.markdown` itself needs macOS 27); the system declares this identifier.
    static let markdownText = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}

struct MarkdownDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.markdownText, .plainText]
    static let writableContentTypes: [UTType] = [.markdownText]

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

enum Pasteboard {
    @MainActor static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

extension String {
    /// Nil when blank.
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

extension UtteranceIntent {
    var title: String {
        switch self {
        case .statement: "Statement"
        case .question: "Question"
        case .proposal: "Proposal"
        case .decision: "Decision"
        case .commitment: "Commitment"
        case .request: "Request"
        case .objection: "Objection"
        case .correction: "Correction"
        case .smallTalk: "Small talk"
        }
    }
}
