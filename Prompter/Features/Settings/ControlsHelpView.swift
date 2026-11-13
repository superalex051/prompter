import SwiftUI

/// "How to use": every way to drive the prompter, in plain words. Static text, pushed from the app settings.
struct ControlsHelpView: View {
    var body: some View {
        Form {
            Section("On the screen") {
                HelpRow("Tap", "Start or pause. The first tap starts the countdown.")
                HelpRow("Drag up or down", "Scrub through the script. Scrolling pauses while you drag.")
                HelpRow("Pinch", "Make the text bigger or smaller.")
                HelpRow("Long-press, or tap with two fingers", "Open the settings.")
            }

            Section("Keyboard or Bluetooth clicker") {
                HelpRow("Space or Return", "Start or pause.")
                HelpRow(
                    "Arrow keys, Page Up and Page Down",
                    "Up, left and Page Up go back a line. Down, right and Page Down go forward a line. Hold Shift to move a whole paragraph."
                )
                HelpRow("+ and −", "Faster and slower.")
                HelpRow("0", "Back to the top.")
                HelpRow("Esc", "Close the prompter.")
            }

            Section {
                HelpRow("Start or Pause", "The big round button.")
                HelpRow("Digital Crown", "Turn it to change the speed.")
                HelpRow("Back to top", "Go to the start of the script.")
                HelpRow("Jump back", "Go back to the start of the paragraph.")
            } header: {
                Text("Apple Watch")
            } footer: {
                Text("Open the prompter on your iPhone first, then open Prompter on your wrist.")
            }

            Section {
                HelpRow("// note", "A line that starts with // is a note for you. It is dimmed, and it is not read or counted.")
                HelpRow("[pause 2]", "A line with just this holds the text for two seconds. Use any number from 1 to 60.")
            } header: {
                Text("Notes and pauses")
            }

            Section {
                ForEach(MarkdownHelp.rows, id: \.syntax) { row in
                    HelpRow(row.syntax, row.detail)
                }
            } header: {
                Text("Markdown formatting")
            } footer: {
                Text(verbatim: MarkdownHelp.footer)
            }
        }
        .navigationTitle("How to use")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// What to do on the left (or on top at large text sizes), what it does underneath.
private struct HelpRow: View {
    let action: String
    let detail: String

    init(_ action: String, _ detail: String) {
        self.action = action
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(action)
                .font(.body.weight(.semibold))
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

#Preview("How to use") {
    NavigationStack {
        ControlsHelpView()
    }
    .preferredColorScheme(.dark)
}
