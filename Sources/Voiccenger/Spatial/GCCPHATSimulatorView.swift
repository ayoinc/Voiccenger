import Charts
import SwiftUI
import VCModels
import VCSpatial

/// The SDK's `State()` macro plugin ships only with Xcode; the alias resolves to the property
/// wrapper so this file builds with the Command Line Tools.
private typealias ViewState = SwiftUI.State

/// Interactive GCC-PHAT / SRP direction-of-arrival playground.
///
/// A simulated far-field source is rendered onto a preset microphone array (or a two-mic pair with
/// adjustable spacing) with noise and reverberation, then analysed with the same `GCCPHAT` and
/// `DirectionEstimator` code the live pipeline uses. The correlation of the widest mic pair, the
/// steered response power around the array and the resulting angle are plotted against the truth.
struct GCCPHATSimulatorView: View {
    @ViewState private var arrayChoice: ArrayChoice = .respeaker4
    @ViewState private var sourceKind: SourceKind = .speech
    @ViewState private var toneFrequency = 1_000.0
    @ViewState private var azimuth = 60.0
    @ViewState private var snrDB = 20.0
    @ViewState private var reverb = 0.0
    @ViewState private var pairSpacing = 0.10
    @ViewState private var seed: UInt64 = 1
    @ViewState private var result: SimulationResult?

    private var parameters: SimulationParameters {
        SimulationParameters(
            arrayChoice: arrayChoice, sourceKind: sourceKind, toneFrequency: toneFrequency,
            azimuth: azimuth, snrDB: snrDB, reverb: reverb, pairSpacing: pairSpacing, seed: seed)
    }

    var body: some View {
        HStack(spacing: 0) {
            controls
                .frame(width: 320)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let result {
                        if result.aliasingFrequency < SimulationParameters.bandEdge {
                            AliasingWarning(result: result)
                        }
                        HStack(alignment: .top, spacing: 16) {
                            AngleSummary(result: result)
                            PolarResponseChart(result: result)
                        }
                        CorrelationChart(result: result)
                    } else {
                        ProgressView("Simulating…")
                            .frame(maxWidth: .infinity, minHeight: 320)
                    }
                }
                .padding(20)
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minHeight: 560)
        .navigationTitle("GCC-PHAT Simulator")
        .task(id: parameters) {
            let parameters = parameters
            // Coalesce rapid slider drags: a newer value cancels this task during the pause.
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            let simulated = await SimulationResult.compute(parameters)
            guard !Task.isCancelled else { return }
            result = simulated
        }
    }

    private var controls: some View {
        Form {
            Section {
                Picker(selection: $arrayChoice) {
                    ForEach(ArrayChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                } label: {
                    Label("Array", systemImage: "circle.grid.cross")
                }
                ValueSlider(
                    title: "Mic spacing", systemImage: "arrow.left.and.right",
                    value: $pairSpacing, range: 0.01...0.30, step: 0.005,
                    format: { String(format: "%.1f cm", $0 * 100) }
                )
                .disabled(arrayChoice != .twoMicPair)
            } header: {
                Text("Microphones")
            } footer: {
                Text("Mic spacing applies to the two-mic pair, which is mirror-ambiguous: it cannot tell θ from −θ.")
            }

            Section("Source") {
                Picker(selection: $sourceKind) {
                    ForEach(SourceKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                } label: {
                    Label("Signal", systemImage: "waveform")
                }
                if sourceKind == .tone {
                    ValueSlider(
                        title: "Frequency", systemImage: "tuningfork",
                        value: $toneFrequency, range: 200...7_500, step: 50,
                        format: { String(format: "%.0f Hz", $0) })
                }
                ValueSlider(
                    title: "Azimuth", systemImage: "location.north.line",
                    value: $azimuth, range: 0...359, step: 1,
                    format: { String(format: "%.0f°", $0) })
            }

            Section {
                ValueSlider(
                    title: "SNR", systemImage: "speaker.wave.2",
                    value: $snrDB, range: -10...40, step: 1,
                    format: { String(format: "%.0f dB", $0) })
                ValueSlider(
                    title: "Reverb", systemImage: "dot.radiowaves.left.and.right",
                    value: $reverb, range: 0...1, step: 0.05,
                    format: { String(format: "%.0f%%", $0 * 100) })
                Button {
                    seed &+= 1
                } label: {
                    Label("New Noise Realisation", systemImage: "dice")
                }
            } header: {
                Text("Room")
            } footer: {
                Text("White sensor noise at the chosen SNR; reverb adds decaying early reflections from other directions.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Parameters

private enum ArrayChoice: String, CaseIterable, Identifiable, Hashable, Sendable {
    case respeaker4, respeaker6, uma8, twoMicPair

    var id: String { rawValue }

    var title: String {
        switch self {
        case .respeaker4: ArrayPresets.respeaker4.name
        case .respeaker6: ArrayPresets.respeaker6.name
        case .uma8: ArrayPresets.uma8.name
        case .twoMicPair: "Two-mic pair"
        }
    }

    func geometry(pairSpacing: Double) -> MicArrayGeometry {
        switch self {
        case .respeaker4: ArrayPresets.respeaker4
        case .respeaker6: ArrayPresets.respeaker6
        case .uma8: ArrayPresets.uma8
        case .twoMicPair:
            MicArrayGeometry(
                name: "Two-mic pair",
                mics: [.init(x: -pairSpacing / 2, y: 0), .init(x: pairSpacing / 2, y: 0)],
                channelMap: [0, 1])
        }
    }
}

private enum SourceKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case speech, pinkNoise, tone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speech: "Speech-like bursts"
        case .pinkNoise: "Pink noise"
        case .tone: "Pure tone"
        }
    }
}

private struct SimulationParameters: Hashable, Sendable {
    static let sampleRate = 16_000.0
    static let speedOfSound = 343.0
    /// Top of the analysed band (Nyquist at 16 kHz); aliasing below it produces ghost peaks.
    static let bandEdge = sampleRate / 2
    static let duration = 1.0

    var arrayChoice: ArrayChoice
    var sourceKind: SourceKind
    var toneFrequency: Double
    var azimuth: Double
    var snrDB: Double
    var reverb: Double
    var pairSpacing: Double
    var seed: UInt64
}

// MARK: - Simulation

private struct CorrelationPoint: Identifiable, Sendable {
    var lag: Int
    var value: Double
    var id: Int { lag }
}

private struct SimulationResult: Sendable {
    var geometry: MicArrayGeometry
    var trueAzimuth: Double
    var estimate: DirectionEstimate?
    /// Normalised steered response, index = degree.
    var response: [Double]
    var pair: (first: Int, second: Int)
    var pairSpacing: Double
    var correlation: [CorrelationPoint]
    var trueLag: Double
    var estimatedLag: Double
    var maxPhysicalLag: Double
    var aliasingFrequency: Double

    var angularError: Double? {
        guard let estimate else { return nil }
        let difference = abs(estimate.azimuthDegrees - trueAzimuth).truncatingRemainder(dividingBy: 360)
        return min(difference, 360 - difference)
    }

    @concurrent
    static func compute(_ parameters: SimulationParameters) async -> SimulationResult {
        let sampleRate = SimulationParameters.sampleRate
        let count = Int(SimulationParameters.duration * sampleRate)
        let geometry = parameters.arrayChoice.geometry(pairSpacing: parameters.pairSpacing)
        let source: [Float] =
            switch parameters.sourceKind {
            case .speech: SignalGenerator.speechLike(count: count, sampleRate: sampleRate, seed: parameters.seed)
            case .pinkNoise: SignalGenerator.pinkNoise(count: count, seed: parameters.seed)
            case .tone: SignalGenerator.tone(frequency: parameters.toneFrequency, count: count, sampleRate: sampleRate)
            }

        let simulator = ArraySimulator(
            geometry: geometry, sampleRate: sampleRate, speedOfSound: SimulationParameters.speedOfSound)
        let micSignals = simulator.render(
            source: source, azimuthDegrees: parameters.azimuth, snrDB: parameters.snrDB,
            reverb: parameters.reverb, seed: parameters.seed)
        let mono = (0..<count).map { n in micSignals.reduce(Float(0)) { $0 + $1[n] } / Float(micSignals.count) }
        let chunk = AudioChunk(
            channel: .microphone, startTime: 0, sampleRate: sampleRate, samples: mono,
            channelSamples: simulator.deviceChannels(micSignals))
        let estimator = DirectionEstimator(geometry: geometry, speedOfSound: SimulationParameters.speedOfSound)

        let pair = widestPair(geometry)
        let spacing = distance(geometry.mics[pair.first], geometry.mics[pair.second])
        let maxPhysicalLag = spacing / SimulationParameters.speedOfSound * sampleRate
        let maxLag = max(8, Int((2 * maxPhysicalLag).rounded(.up)))
        let correlation = GCCPHAT.correlate(micSignals[pair.first], micSignals[pair.second], maxLag: maxLag)
        let measured = GCCPHAT.tdoa(
            micSignals[pair.first], micSignals[pair.second], sampleRate: sampleRate,
            maxDelay: spacing / SimulationParameters.speedOfSound)

        return SimulationResult(
            geometry: geometry,
            trueAzimuth: parameters.azimuth,
            estimate: estimator.estimate(chunk),
            response: estimator.response(chunk),
            pair: pair,
            pairSpacing: spacing,
            correlation: zip(correlation.lags, correlation.values).map { CorrelationPoint(lag: $0, value: Double($1)) },
            trueLag: simulator.tdoa(from: pair.first, to: pair.second, azimuthDegrees: parameters.azimuth) * sampleRate,
            estimatedLag: measured.seconds * sampleRate,
            maxPhysicalLag: maxPhysicalLag,
            aliasingFrequency: ArraySimulator.spatialAliasingFrequency(
                micSpacing: spacing, speedOfSound: SimulationParameters.speedOfSound))
    }

    private static func widestPair(_ geometry: MicArrayGeometry) -> (first: Int, second: Int) {
        var best = (first: 0, second: min(1, geometry.mics.count - 1))
        var widest = -1.0
        for i in geometry.mics.indices {
            for j in geometry.mics.indices where j > i {
                let d = distance(geometry.mics[i], geometry.mics[j])
                if d > widest + 1e-9 {
                    widest = d
                    best = (i, j)
                }
            }
        }
        return best
    }

    private static func distance(_ a: MicArrayGeometry.Point, _ b: MicArrayGeometry.Point) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }
}

// MARK: - Controls

private struct ValueSlider: View {
    var title: LocalizedStringKey
    var systemImage: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var format: (Double) -> String

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Slider(value: $value, in: range, step: step)
                    .labelsHidden()
                    .accessibilityLabel(Text(title))
                    .accessibilityValue(format(value))
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}

// MARK: - Result panels

private struct AliasingWarning: View {
    var result: SimulationResult

    var body: some View {
        let halfWavelength = SimulationParameters.speedOfSound / SimulationParameters.bandEdge / 2
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Spatial aliasing above \(result.aliasingFrequency / 1_000, format: .number.precision(.fractionLength(1))) kHz")
                    .font(.headline)
                Text(
                    "Mics \(result.pair.first + 1)–\(result.pair.second + 1) are \(result.pairSpacing * 100, format: .number.precision(.fractionLength(1))) cm apart, more than λ/2 = \(halfWavelength * 100, format: .number.precision(.fractionLength(1))) cm at 8 kHz. Energy above the aliasing frequency can add ghost peaks to the correlation."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.12), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private struct AngleSummary: View {
    var result: SimulationResult

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("True azimuth") {
                    Text("\(result.trueAzimuth, format: .number.precision(.fractionLength(0)))°")
                }
                if let estimate = result.estimate {
                    LabeledContent("Estimated azimuth") {
                        Text("\(estimate.azimuthDegrees, format: .number.precision(.fractionLength(1)))°")
                    }
                    if let error = result.angularError {
                        LabeledContent("Error") {
                            Text("\(error, format: .number.precision(.fractionLength(1)))°")
                        }
                        .foregroundStyle(error <= 10 ? Color.primary : Color.orange)
                    }
                    Gauge(value: estimate.confidence) {
                        Text("Confidence")
                    } currentValueLabel: {
                        Text(estimate.confidence, format: .percent.precision(.fractionLength(0)))
                    }
                    .tint(estimate.confidence >= SeatTracker.minimumConfidence ? Color.accentColor : Color.orange)
                    if estimate.confidence < SeatTracker.minimumConfidence {
                        Text("Below the \(SeatTracker.minimumConfidence, format: .percent) seat-tracking threshold; this estimate would be ignored.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label("No estimate: every frame was gated as silence.", systemImage: "speaker.slash")
                        .foregroundStyle(.secondary)
                }
                Divider()
                LabeledContent("True TDOA, mics \(result.pair.first + 1)–\(result.pair.second + 1)") {
                    Text("\(microseconds(result.trueLag), format: .number.precision(.fractionLength(1))) µs")
                }
                LabeledContent("GCC-PHAT TDOA") {
                    Text("\(microseconds(result.estimatedLag), format: .number.precision(.fractionLength(1))) µs")
                }
            }
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Direction", systemImage: "scope")
        }
        .frame(minWidth: 240, maxWidth: 320)
    }

    private func microseconds(_ lagSamples: Double) -> Double {
        lagSamples / SimulationParameters.sampleRate * 1e6
    }
}

private struct PolarResponseChart: View {
    var result: SimulationResult

    private struct PolarPoint: Identifiable {
        var id: Int
        var x: Double
        var y: Double
    }

    private static let ringRadii = [0.25, 0.5, 0.75, 1.0]

    var body: some View {
        GroupBox {
            VStack(spacing: 8) {
                Chart {
                    ForEach(Self.ringRadii, id: \.self) { radius in
                        ForEach(circle(radius: radius)) { point in
                            LineMark(
                                x: .value("x", point.x), y: .value("y", point.y),
                                series: .value("Ring", "ring-\(radius)"))
                            .foregroundStyle(.quaternary)
                            .lineStyle(StrokeStyle(lineWidth: 0.5))
                        }
                    }
                    ForEach(responseCurve) { point in
                        LineMark(
                            x: .value("x", point.x), y: .value("y", point.y),
                            series: .value("Series", "response"))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    ForEach(ray(azimuth: result.trueAzimuth)) { point in
                        LineMark(
                            x: .value("x", point.x), y: .value("y", point.y),
                            series: .value("Series", "true"))
                        .foregroundStyle(.green)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    }
                    if let estimate = result.estimate {
                        ForEach(ray(azimuth: estimate.azimuthDegrees)) { point in
                            LineMark(
                                x: .value("x", point.x), y: .value("y", point.y),
                                series: .value("Series", "estimate"))
                            .foregroundStyle(.orange)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        }
                    }
                    ForEach(Array(micPositions.enumerated()), id: \.offset) { index, point in
                        PointMark(x: .value("x", point.x), y: .value("y", point.y))
                            .foregroundStyle(.secondary)
                            .symbolSize(30)
                            .annotation(position: .top, spacing: 2) {
                                Text("\(index + 1)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .chartXScale(domain: -1.1...1.1)
                .chartYScale(domain: -1.1...1.1)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .overlay(alignment: .trailing) {
                    Text("0°").font(.caption2).foregroundStyle(.secondary)
                }
                .overlay(alignment: .top) {
                    Text("90°").font(.caption2).foregroundStyle(.secondary)
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(minWidth: 240, maxWidth: 360)
                .accessibilityElement()
                .accessibilityLabel("Steered response power around the array")
                .accessibilityValue(accessibilitySummary)

                HStack(spacing: 14) {
                    LegendSwatch(title: "Response", color: .accentColor, dashed: false)
                    LegendSwatch(title: "True", color: .green, dashed: true)
                    LegendSwatch(title: "Estimated", color: .orange, dashed: false)
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity)
        } label: {
            Label("Steered Response Power", systemImage: "circle.dashed")
        }
    }

    private var responseCurve: [PolarPoint] {
        guard result.response.count == 360 else { return [] }
        return (0...360).map { degree in
            let radius = result.response[degree % 360]
            return polar(id: degree, radius: radius, degrees: Double(degree))
        }
    }

    private var micPositions: [PolarPoint] {
        let mics = result.geometry.mics
        let extent = mics.map { hypot($0.x, $0.y) }.max() ?? 0
        let scale = extent > 0 ? 0.3 / extent : 0
        return mics.enumerated().map { PolarPoint(id: $0.offset, x: $0.element.x * scale, y: $0.element.y * scale) }
    }

    private func circle(radius: Double) -> [PolarPoint] {
        stride(from: 0, through: 360, by: 5).map { polar(id: $0, radius: radius, degrees: Double($0)) }
    }

    private func ray(azimuth: Double) -> [PolarPoint] {
        [PolarPoint(id: 0, x: 0, y: 0), polar(id: 1, radius: 1.05, degrees: azimuth)]
    }

    private func polar(id: Int, radius: Double, degrees: Double) -> PolarPoint {
        let radians = degrees * .pi / 180
        return PolarPoint(id: id, x: radius * cos(radians), y: radius * sin(radians))
    }

    private var accessibilitySummary: String {
        let truth = String(format: "True source at %.0f degrees", result.trueAzimuth)
        guard let estimate = result.estimate else { return truth + ", no estimate." }
        return truth + String(
            format: ", response peaks at %.1f degrees with %.0f percent confidence.",
            estimate.azimuthDegrees, estimate.confidence * 100)
    }
}

private struct CorrelationChart: View {
    var result: SimulationResult

    var body: some View {
        GroupBox {
            Chart {
                RectangleMark(
                    xStart: .value("Lag", -result.maxPhysicalLag), xEnd: .value("Lag", result.maxPhysicalLag))
                .foregroundStyle(.quaternary.opacity(0.5))
                ForEach(result.correlation) { point in
                    LineMark(x: .value("Lag", Double(point.lag)), y: .value("GCC-PHAT", point.value))
                        .foregroundStyle(Color.accentColor)
                        .interpolationMethod(.monotone)
                }
                RuleMark(x: .value("True lag", result.trueLag))
                    .foregroundStyle(.green)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("True").font(.caption2).foregroundStyle(.green)
                    }
                RuleMark(x: .value("Estimated lag", result.estimatedLag))
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("Estimated").font(.caption2).foregroundStyle(.orange)
                    }
            }
            .chartXAxisLabel("Lag (samples at 16 kHz; positive = mic \(result.pair.second + 1) hears later)")
            .chartYAxisLabel("Correlation")
            .frame(minHeight: 220)
            .accessibilityElement()
            .accessibilityLabel("GCC-PHAT correlation between mics \(result.pair.first + 1) and \(result.pair.second + 1)")
            .accessibilityValue(
                String(
                    format: "True lag %.2f samples, estimated lag %.2f samples.", result.trueLag,
                    result.estimatedLag))
        } label: {
            Label(
                "GCC-PHAT, Mics \(result.pair.first + 1)–\(result.pair.second + 1) (\(String(format: "%.1f", result.pairSpacing * 100)) cm)",
                systemImage: "waveform.path.ecg")
        }
    }
}

private struct LegendSwatch: View {
    var title: LocalizedStringKey
    var color: Color
    var dashed: Bool

    var body: some View {
        HStack(spacing: 4) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 5))
                path.addLine(to: CGPoint(x: 16, y: 5))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [4, 2] : []))
            .frame(width: 16, height: 10)
            Text(title)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
