import SwiftUI

/// The huge countdown digit in the middle of the canvas (mirrored with it), over a dark scrim so it reads through the glass.
struct CountdownOverlay: View {
    let engine: ScrollEngine
    let foreground: Color
    let background: Color
    let canvasSize: CGSize

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if case .countdown(let seconds) = engine.state {
                ZStack {
                    background.opacity(0.75)
                    Text("\(seconds)")
                        .font(.system(size: canvasSize.height * 0.8, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.1)
                        .lineLimit(1)
                        .foregroundStyle(foreground)
                        // Reduce Motion: the digit swaps in place instead of rolling.
                        .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
                        .padding(.horizontal, canvasSize.width * 0.05)
                        .accessibilityLabel("Starting in \(seconds)")
                        .accessibilityIdentifier("prompter.countdown")
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: engine.state)
    }
}
