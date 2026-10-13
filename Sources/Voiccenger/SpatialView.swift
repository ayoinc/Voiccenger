import SwiftUI
import VCPipeline

/// SwiftUI's `@State` macro needs a compiler plugin missing from the Command Line Tools; the property wrapper works.
private typealias ViewState = SwiftUI.State

/// Live microphone-array direction while recording with an array, and the GCC-PHAT simulator.
struct SpatialView: View {
    @Environment(MeetingCoordinator.self) private var coordinator
    @ViewState private var mode: Mode = .live

    private enum Mode: String, CaseIterable, Identifiable {
        case live, simulator
        var id: String { rawValue }
        var title: String { self == .live ? "Live Array" : "Simulator" }
    }

    private var liveSession: MeetingSession? {
        guard let session = coordinator.session, session.isActive, session.hasMicArray else { return nil }
        return session
    }

    var body: some View {
        Group {
            switch mode {
            case .live:
                if let session = liveSession {
                    LiveArrayView(session: session)
                } else {
                    ContentUnavailableView {
                        Label("No Live Array", systemImage: "dot.radiowaves.left.and.right")
                    } description: {
                        Text(
                            coordinator.settings.arrayGeometry == nil
                                ? "Choose your microphone array in Settings › Audio, then record to see where each person sits."
                                : "Start recording to see where each person sits around the \(coordinator.settings.arrayGeometry?.name ?? "array")."
                        )
                    } actions: {
                        if coordinator.settings.arrayGeometry == nil {
                            SettingsLink { Text("Open Audio Settings…") }
                        }
                        Button("Open Simulator") { mode = .simulator }
                    }
                }
            case .simulator:
                GCCPHATSimulatorView()
            }
        }
        .navigationTitle("Spatial")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }
}

private struct LiveArrayView: View {
    let session: MeetingSession

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            SeatCompass(
                markers: session.participants.compactMap { p in
                    p.seatAzimuthDegrees.map { SeatCompass.Marker(id: p.id, label: p.displayName, azimuth: $0, colorIndex: p.colorIndex) }
                },
                liveAzimuth: session.latestDirection?.azimuthDegrees,
                liveConfidence: session.latestDirection?.confidence ?? 0
            )
            .frame(minWidth: 280, maxWidth: 520)
            .padding()

            Form {
                Section("Current Direction") {
                    if let d = session.latestDirection {
                        LabeledContent("Azimuth", value: Format.degrees(d.azimuthDegrees))
                        LabeledContent("Confidence") {
                            Gauge(value: max(0, min(1, d.confidence))) { EmptyView() }
                                .gaugeStyle(.accessoryLinearCapacity)
                                .frame(width: 120)
                                .accessibilityValue(d.confidence.formatted(.percent.precision(.fractionLength(0))))
                        }
                        LabeledContent("At", value: Format.timestamp(d.time))
                    } else {
                        Text("Waiting for speech…").foregroundStyle(.secondary)
                    }
                }
                Section("Seats") {
                    let seated = session.participants.filter { $0.channel == .microphone }
                    if seated.isEmpty {
                        Text("Seats appear once speakers are identified.").foregroundStyle(.secondary)
                    }
                    ForEach(seated) { p in
                        LabeledContent {
                            Text(p.seatAzimuthDegrees.map(Format.degrees) ?? "Locating…").monospacedDigit()
                        } label: {
                            HStack(spacing: 6) {
                                ParticipantDot(colorIndex: p.colorIndex)
                                Text(p.displayName)
                            }
                        }
                    }
                }
                if let geometry = session.config.arrayGeometry {
                    Section("Array") {
                        LabeledContent("Model", value: geometry.name)
                        LabeledContent("Microphones", value: "\(geometry.mics.count)")
                        LabeledContent("Aperture", value: Measurement(value: geometry.aperture * 100, unit: UnitLength.centimeters).formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(1)))))
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 280, maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
