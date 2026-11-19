import SwiftUI

/// The huge countdown digit in the middle of the canvas (mirrored with it), over a dark scrim so it reads through the glass.
struct CountdownOverlay: View {
    let engine: ScrollEngine
    let foreground: Color
    let background: Color
    let canvasSize: CGSize
    /// Where the digit is centred, in canvas points, when something is in the way (an active fold, see
    /// `PrompterAvoidance.countdownArea`); nil: the middle of the canvas. The dimming always covers the whole canvas.
    var digitArea: CGRect?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if case .countdown(let seconds) = engine.state {
                ZStack {
                    background.opacity(0.75)
                    placed(digit(seconds, in: digitArea?.size ?? canvasSize))
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: engine.state)
    }

    /// The digit sized for an area of `size`: 80 % of its height, scaled down to fit its width less a 5 % margin each side.
    private func digit(_ seconds: Int, in size: CGSize) -> some View {
        Text("\(seconds)")
            .font(.system(size: size.height * 0.8, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.1)
            .lineLimit(1)
            .foregroundStyle(foreground)
            // Reduce Motion: the digit swaps in place instead of rolling.
            .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
            .padding(.horizontal, size.width * 0.05)
            .accessibilityLabel("Starting in \(seconds)")
            .accessibilityIdentifier("prompter.countdown")
    }

    @ViewBuilder private func placed(_ digit: some View) -> some View {
        if let area = digitArea {
            digit
                .frame(width: area.width, height: area.height)
                .position(x: area.midX, y: area.midY)
        } else {
            digit
        }
    }
}
