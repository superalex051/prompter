import SwiftUI

/// The watch's one screen: script title and state on top; the Start/Pause/Resume button inside the progress ring, with
/// the time left (or the countdown digit) in it; Back to top and Jump back to its left, Speed + and − to its right (next
/// to the Crown); the speed label underneath. The Digital Crown changes the speed one step per detent.
///
/// The controls flank the ring instead of sitting in a row below it so the ring keeps the whole middle band: on a 40 mm
/// screen a bottom row left it under 60 pt with the time too small to read at a glance. Fits 40 mm without scrolling.
struct RemoteView: View {
    let remote: WatchRemote

    @State private var crownValue = 0.0
    /// The whole Crown value already turned into speed steps.
    @State private var crownHandled = 0
    @FocusState private var crownFocused: Bool

    var body: some View {
        let model = remote.display
        VStack(spacing: 2) {
            header(model)
            GeometryReader { proxy in
                middleBand(model, size: proxy.size)
            }
            Text(model.speedLabel.isEmpty ? " " : model.speedLabel)
                .font(.footnote.weight(.medium).monospacedDigit())
                .foregroundStyle(Color(white: 0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The bottom inset is empty space on a watch; the centred speed label clears the rounded corners.
        .ignoresSafeArea(.container, edges: .bottom)
        .background(Color.black)
        .focusable()
        .focused($crownFocused)
        .focusEffectDisabled()
        .digitalCrownRotation(
            $crownValue,
            from: -100_000,
            through: 100_000,
            by: 1,
            sensitivity: .low,
            isContinuous: false,
            isHapticFeedbackEnabled: model.speedControlsEnabled
        )
        .digitalCrownAccessory(.hidden)
        .onChange(of: crownValue) { _, value in
            let whole = Int(value.rounded())
            let steps = whole - crownHandled
            crownHandled = whole
            if steps != 0 { remote.stepSpeed(by: steps) }
        }
        .onAppear { crownFocused = true }
    }

    private func header(_ model: RemoteDisplayModel) -> some View {
        VStack(spacing: 0) {
            Text(model.title)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(Color(white: 0.75))
            // Controlling Prompter for Mac through the iPhone: say so, so nobody wonders why the iPhone isn't moving.
            if let deviceText = model.deviceText {
                Text(deviceText)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(Color.amber)
            }
            Text(remote.showsSendFailure ? WatchRemote.sendFailureText : model.stateText)
                .font(model.controlsEnabled && !remote.showsSendFailure ? .headline : .footnote.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .multilineTextAlignment(.center)
                .foregroundStyle(stateColor(model))
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
    }

    private func stateColor(_ model: RemoteDisplayModel) -> Color {
        if remote.showsSendFailure { return .red }
        if model.countdownDigit != nil { return .amber }
        return model.controlsEnabled ? .white : Color(white: 0.75)
    }

    /// Two control tiles on each side of the ring. The tiles get a fixed share of the width, never under 38 pt (the
    /// smallest comfortable target, which a 40 mm screen still fits); the ring takes the rest.
    private func middleBand(_ model: RemoteDisplayModel, size: CGSize) -> some View {
        let spacing: CGFloat = 4
        let side = min(max(size.width * 0.22, 38), 46)
        let ring = max(min(size.width - 2 * (side + spacing), size.height), 0)
        let tile = min((ring - spacing) / 2, 48)
        return HStack(spacing: spacing) {
            VStack(spacing: spacing) {
                ControlButton(symbol: "arrow.up.to.line", label: "Back to top") { remote.send(.backToTop) }
                    .frame(height: tile)
                ControlButton(symbol: "gobackward", label: "Jump back", hint: "Goes back one paragraph") {
                    remote.send(.jumpBack)
                }
                .frame(height: tile)
            }
            .frame(width: side)
            PrimaryRingButton(model: model) { remote.send(model.primaryCommand) }
                .frame(width: ring, height: ring)
            // In voice mode the reader sets the pace: the phone ignores speed steps, so the buttons are off.
            VStack(spacing: spacing) {
                ControlButton(symbol: "plus", label: "Faster") { remote.send(.speedStep(5)) }
                    .frame(height: tile)
                ControlButton(symbol: "minus", label: "Slower") { remote.send(.speedStep(-5)) }
                    .frame(height: tile)
            }
            .frame(width: side)
            .disabled(!model.speedControlsEnabled)
        }
        .disabled(!model.controlsEnabled)
        .frame(width: size.width, height: size.height)
    }
}

/// The big circular primary button: a progress ring around an amber disc that shows the time left (or the countdown
/// digit) above the button's symbol. Everything scales with the diameter it gets.
private struct PrimaryRingButton: View {
    let model: RemoteDisplayModel
    let action: () -> Void

    private static let ringWidth: CGFloat = 6
    private static let gap: CGFloat = 3

    var body: some View {
        Button(action: action) {
            GeometryReader { proxy in
                let diameter = min(proxy.size.width, proxy.size.height)
                let disc = max(diameter - 2 * (Self.ringWidth + Self.gap), 0)
                ZStack {
                    Circle()
                        .strokeBorder(Color(white: 0.22), lineWidth: Self.ringWidth)
                    Circle()
                        .inset(by: Self.ringWidth / 2)
                        .trim(from: 0, to: model.progress)
                        .stroke(Color.amber, style: StrokeStyle(lineWidth: Self.ringWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Circle()
                        .fill(model.controlsEnabled ? Color.amber : Color(white: 0.18))
                        .frame(width: disc, height: disc)
                    label(disc: disc)
                        .foregroundStyle(model.controlsEnabled ? Color.black : Color(white: 0.55))
                }
                .frame(width: diameter, height: diameter)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .buttonStyle(RingPressStyle())
        .accessibilityLabel(model.primaryButtonTitle)
        .accessibilityValue(model.timeAccessibilityValue)
    }

    private func label(disc: CGFloat) -> some View {
        VStack(spacing: 0) {
            if let digit = model.countdownDigit {
                Text("\(digit)")
                    .font(.system(size: disc * 0.5, weight: .heavy, design: .rounded))
                    .monospacedDigit()
            } else {
                Text(model.timeText)
                    .font(.system(size: disc * 0.33, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: disc * 0.84)
            }
            Image(systemName: model.primarySymbol)
                .font(.system(size: disc * 0.19, weight: .heavy))
        }
    }
}

/// Dims the ring button while pressed.
private struct RingPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Circle())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

/// A control tile: an SF Symbol on a dark rounded tile, filling the frame it's given.
private struct ControlButton: View {
    let symbol: String
    let label: String
    var hint: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .bold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(ControlTileStyle())
        .accessibilityLabel(label)
        .accessibilityHint(hint ?? "")
    }
}

private struct ControlTileStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.white : Color(white: 0.4))
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(white: configuration.isPressed ? 0.32 : 0.17))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension Color {
    /// Prompter's accent, #FFB020 (the phone app's AccentColor).
    static let amber = Color(red: 1, green: 176 / 255, blue: 32 / 255)
}
