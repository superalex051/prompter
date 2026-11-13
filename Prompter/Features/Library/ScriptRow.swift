import SwiftUI

/// One row in the library: title, first line and stats on the left, a big Prompt button on the right.
/// Both buttons use explicit styles so each one takes only its own taps inside a List row.
struct ScriptRow: View {
    let script: Script
    let wordsPerMinute: Double
    /// Settings → Markdown formatting: count the words as the prompter shows them.
    var markdown = false
    var onOpen: () -> Void
    var onPrompt: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// From Extra Extra Extra Large up (not only the accessibility sizes) the text takes the full row width and the
    /// Prompt button sits under it: side by side, the details were squeezed into a few characters per line.
    private var isLargeText: Bool { dynamicTypeSize >= .xxxLarge }

    var body: some View {
        let layout = isLargeText
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            Button(action: onOpen) {
                details
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Big on purpose (spec §3.1): it's the main action, often tapped one-handed right before the phone
            // goes into the cradle. `.large` makes the capsule about 50 pt tall (44 pt is the minimum tap target).
            Button(action: onPrompt) {
                PromptButtonLabel()
                    .font(.body)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .fixedSize()
            .accessibilityLabel("Prompt \(script.displayTitle)")
        }
        .padding(.vertical, 4)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(script.displayTitle)
                .font(.headline)
                .lineLimit(isLargeText ? 3 : 1)
            if !script.firstLine.isEmpty {
                Text(script.firstLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(isLargeText ? 3 : 1)
            }
            Text("\(statsSummary) · \(script.updatedAt, format: .relative(presentation: .named))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(isLargeText ? 3 : 1)
                .padding(.top, 2)
        }
    }

    /// "412 words · 2:56" ("1,204 words" from a thousand up), with read time at the current words-per-minute setting.
    private var statsSummary: String {
        let stats = ReadingStats(text: script.body, markdown: markdown)
        let words = stats.wordCount
        let time = TimeFormatting.clock(stats.readingSeconds(atWPM: wordsPerMinute))
        return "\(words.formatted()) \(words == 1 ? "word" : "words") · \(time)"
    }
}
