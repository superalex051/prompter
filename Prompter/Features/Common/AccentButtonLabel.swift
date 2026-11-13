import SwiftUI

extension View {
    /// Label colour for a `.borderedProminent` button on the amber accent. Black, because the default white on
    /// #FFB020 is only about 1.8:1. A disabled button gets a grey fill, so its label falls back to `.secondary`.
    func onAccentForeground() -> some View {
        modifier(OnAccentForeground())
    }
}

private struct OnAccentForeground: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.foregroundStyle(isEnabled ? AnyShapeStyle(Color.black) : AnyShapeStyle(.secondary))
    }
}

/// "▶ Prompt" in black, for the amber Prompt buttons in the library rows and the editor toolbar.
/// It's an HStack, not a `Label`, on purpose: in a toolbar the system draws a `Label` itself (white icon only,
/// ignoring the foreground style), and in a List row a `.fixedSize()` Label collapsed to a tall icon-only capsule.
struct PromptButtonLabel: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "play.fill")
                .accessibilityHidden(true)
            Text("Prompt")
        }
        .fontWeight(.semibold)
        .onAccentForeground()
    }
}
