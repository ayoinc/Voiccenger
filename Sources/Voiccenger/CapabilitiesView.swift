import SwiftUI
import VCPipeline

/// "What this Mac can do": every feature, whether it runs on this Mac, and why not. Shown once at first launch
/// and from Settings › General.
struct CapabilitiesView: View {
    var isFirstRun = false
    let onDone: () -> Void
    private let capabilities = PlatformCapabilities.current()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(isFirstRun ? "Welcome to Voiccenger" : "What This Mac Can Do")
                    .font(.title2.bold())
                Text(capabilities.summary)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(capabilities.tierName)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isFirstRun {
                Text("Here's what works on this Mac.")
                    .font(.headline)
            }
            ScrollView {
                Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 12) {
                    ForEach(capabilities.features) { feature in
                        GridRow {
                            Image(systemName: feature.isAvailable ? "checkmark.circle.fill" : "minus.circle")
                                .foregroundStyle(feature.isAvailable ? Color.green : Color.secondary)
                                .font(.body)
                                .accessibilityLabel(feature.isAvailable ? "Available" : "Not available")
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(feature.name).fontWeight(.semibold)
                                    if let reason = feature.reason {
                                        Text(reason)
                                            .font(.caption)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1)
                                            .background(.quaternary, in: Capsule())
                                    }
                                }
                                Text(feature.detail)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 280, maxHeight: 440)
            Divider()
            HStack {
                Text("Voiccenger runs on macOS \(PlatformCapabilities.minimumMacOS) or later, on Apple silicon and Intel Macs. You can reopen this from Settings › General.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(isFirstRun ? "Continue" : "Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
