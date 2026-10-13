import SwiftUI
import VCPipeline

/// SwiftUI's `@State` macro needs a compiler plugin missing from the Command Line Tools; the property wrapper works.
private typealias ViewState = SwiftUI.State

/// Asked before recording until the user confirms they tell participants (`MeetingCoordinator.pendingRecording`).
struct RecordingConsentSheet: View {
    @Environment(MeetingCoordinator.self) private var coordinator
    @ViewState private var dontRemind = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "person.2.wave.2.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.red)
                    .frame(width: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Let people know you're recording")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("Recording laws differ by country, state and workplace, and some places require everyone's permission before a conversation is recorded.")
                    Text("Tell the people in this meeting that you're recording and transcribing it, and get their consent where it's required.")
                    Label(privacyNote, systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Don't remind me again", isOn: $dontRemind)
                .toggleStyle(.checkbox)
                .padding(.leading, 54)
                .help("Turn off to be asked before every recording. Meetings are only recorded automatically once you've turned this on.")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { coordinator.cancelPendingRecording() }
                    .keyboardShortcut(.cancelAction)
                Button("I'll Tell Them — Start Recording") {
                    let remember = dontRemind
                    Task { await coordinator.confirmPendingRecording(remember: remember) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private var privacyNote: String {
        if coordinator.settings.engine == .claude {
            return "Audio and transcripts are saved on this Mac. Transcript text is sent to Anthropic for analysis because Claude is selected in Settings › Intelligence."
        }
        return "Audio and transcripts stay on this Mac."
    }
}
