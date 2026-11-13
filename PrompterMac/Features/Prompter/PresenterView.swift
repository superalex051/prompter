import SwiftUI

/// The Presenter view on the laptop while the prompter shows on the teleprompter screen (like PowerPoint's presenter
/// view): a live preview of the output, the time left in big digits, large transport buttons, a live settings panel,
/// the script and screen pickers and "Stop presenting". Dark, amber, readable from a step back.
struct PresenterView: View {
    let controller: PresentingController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var session: PresenterSession { controller.session }

    /// The window width from which the timing sits beside the preview. The wide layout needs about 1420 pt (the transport
    /// row alone is 950 pt, the timing column 400), and 1830 with the 380-pt settings panel beside it. So a 14" MacBook
    /// (1512 pt) and a 13" Air (1470 pt) get the wide layout, and with Settings open the compact one, whose time-left
    /// clock is just as big (96 pt) and whose keys sit in a strip.
    nonisolated static func isWide(width: CGFloat, settingsOpen: Bool) -> Bool {
        width >= (settingsOpen ? 1830 : 1440)
    }

    /// Narrower than this, the top bar has no room for the state pill and the screen picker (the pill moves to the
    /// timing card, the picker is left out).
    static let topBarCompactBelow: CGFloat = 1250

    var body: some View {
        GeometryReader { proxy in
            let isWide = Self.isWide(width: proxy.size.width, settingsOpen: session.isSettingsPanelOpen)
            let isTopBarCompact = proxy.size.width < Self.topBarCompactBelow
            // A MacBook's notch: nothing sits under it (unless the hosting view already insets by it).
            let notchInset = max(0, controller.presenterTopInset - proxy.safeAreaInsets.top)
            VStack(spacing: 0) {
                PresenterTopBar(controller: controller, isCompact: isTopBarCompact)
                    .padding(.horizontal, isWide ? 28 : 18)
                    .padding(.vertical, 14)
                Rectangle().fill(PresenterTheme.hairline).frame(height: 1)
                if let notice = controller.notice {
                    PresenterNoticeBanner(text: notice)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
                if controller.showsSingleScreenHint {
                    PresenterNoticeBanner(
                        text: PresenterView.singleScreenHint,
                        systemImage: "info.circle.fill",
                        identifier: "presenter.singleScreenHint"
                    )
                }
                HStack(alignment: .top, spacing: 20) {
                    if isWide {
                        VStack(spacing: 20) {
                            PresenterPreviewCard(session: session)
                            PresenterTransport(session: session, isCompact: false)
                        }
                        PresenterTimingPanel(session: session, isCompact: false)
                            .frame(width: 400)
                    } else {
                        VStack(spacing: 14) {
                            PresenterPreviewCard(session: session)
                            PresenterTimingPanel(session: session, isCompact: true, showsStatePill: isTopBarCompact)
                            PresenterTransport(session: session, isCompact: true)
                            KeyLegend(isStrip: true)
                        }
                    }
                    if session.isSettingsPanelOpen {
                        PresenterSettingsPanel(session: session)
                            .frame(width: isWide ? 380 : 330)
                            .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(isWide ? 28 : 18)
            }
            .padding(.top, notchInset)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: session.isSettingsPanelOpen)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: controller.notice)
        }
        .background(PresenterTheme.background)
        .foregroundStyle(.white)
        .tint(PresenterTheme.accent)
    }
}

extension PresenterView {
    /// Under the top bar while only one screen is connected.
    static let singleScreenHint = "Only one screen found. Connect your teleprompter screen and the prompter moves there by itself. Not showing? Turn off Mirror Displays."
}

// MARK: - Theme

enum PresenterTheme {
    static let background = Color(white: 0.055)
    static let card = Color(white: 0.105)
    static let raised = Color(white: 0.16)
    static let raisedPressed = Color(white: 0.22)
    static let hairline = Color.white.opacity(0.08)
    static let secondary = Color.white.opacity(0.58)
    /// The app's amber (#FFB020).
    static let accent = Color(red: 1, green: 0xB0 / 255, blue: 0x20 / 255)
    static let playing = Color(red: 0.30, green: 0.85, blue: 0.45)
    static let finished = Color(red: 0.45, green: 0.65, blue: 1)

    static func tone(_ tone: PresenterStatus.Tone) -> Color {
        switch tone {
        case .neutral: Color.white.opacity(0.7)
        case .countdown, .paused: accent
        case .playing: playing
        case .finished: finished
        }
    }

    static func caption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 13, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(secondary)
    }
}

// MARK: - Top bar

private struct PresenterTopBar: View {
    let controller: PresentingController
    let isCompact: Bool

    private var session: PresenterSession { controller.session }

    var body: some View {
        HStack(spacing: 14) {
            scriptMenu
            Spacer(minLength: 12)
            if !isCompact {
                StatePill(session: session)
                Spacer(minLength: 12)
            }
            WallClock()
            if !isCompact { screenMenu }
            iconButton("Swap screens", systemImage: "arrow.left.arrow.right") { controller.swapScreens() }
                .disabled(controller.isSingleScreen)
                .help("Swap screens: the prompter and this view trade places")
            iconButton(session.isSettingsPanelOpen ? "Hide settings" : "Settings", systemImage: "slider.horizontal.3",
                       isOn: session.isSettingsPanelOpen) {
                session.isSettingsPanelOpen.toggle()
            }
            .help("Prompter settings")
            Button { controller.onStop() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                    Text("Stop presenting")
                    KeyHint("esc")
                }
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(Color.red.opacity(0.22), in: Capsule())
                .overlay(Capsule().stroke(Color.red.opacity(0.45), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("presenter.stop")
        }
    }

    private var scriptMenu: some View {
        Menu {
            ForEach(session.scriptStore.scripts) { script in
                Button {
                    controller.session.switchScript(to: script.id)
                    controller.onScriptSwitch(script.id)
                } label: {
                    if script.id == session.scriptID {
                        Label(script.displayTitle, systemImage: "checkmark")
                    } else {
                        Text(script.displayTitle)
                    }
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(PresenterTheme.accent)
                    .frame(width: 38, height: 38)
                    .background(PresenterTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 1) {
                    PresenterTheme.caption("Presenting")
                    HStack(spacing: 6) {
                        Text(session.scriptTitle)
                            .font(.system(size: 20, weight: .semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(PresenterTheme.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch script")
    }

    private var screenMenu: some View {
        Menu {
            Section("Show the prompter on") {
                ForEach(controller.screens) { screen in
                    Button {
                        controller.chooseOutput(screen.id)
                    } label: {
                        if screen.id == controller.plan?.output {
                            Label(screen.name, systemImage: "checkmark")
                        } else {
                            Text(screen.name)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "display")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(PresenterTheme.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    PresenterTheme.caption(controller.isSingleScreen ? "Prompter window on" : "Teleprompter screen")
                    HStack(spacing: 6) {
                        Text(controller.screenName(controller.plan?.output))
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        if let resolution = controller.screenResolution(controller.plan?.output) {
                            Text(resolution)
                                .font(.system(size: 13, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(PresenterTheme.secondary)
                                .lineLimit(1)
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(PresenterTheme.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(PresenterTheme.card, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose the screen the prompter shows on")
    }

    private func iconButton(
        _ title: String, systemImage: String, isOn: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 40)
                .background(isOn ? PresenterTheme.accent.opacity(0.22) : PresenterTheme.card,
                            in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(isOn ? PresenterTheme.accent : .white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// "Playing", "Paused", "Starting 3"… in a colored capsule.
private struct StatePill: View {
    let session: PresenterSession

    var body: some View {
        let state = session.engine.state
        let color = PresenterTheme.tone(PresenterStatus.tone(for: state))
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 12, height: 12)
            Text(PresenterStatus.stateWord(for: state, holdSeconds: session.engine.holdSecondsLeft))
                .font(.system(size: 20, weight: .bold))
                .monospacedDigit()
        }
        .padding(.horizontal, 18)
        .frame(height: 42)
        .background(color.opacity(0.16), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.4), lineWidth: 1))
        .accessibilityIdentifier("presenter.state")
    }
}

/// The time of day, small, in the top bar: how long until the next thing, without looking away from the prompter.
private struct WallClock: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(context.date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 15, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(PresenterTheme.secondary)
                .padding(.trailing, 4)
                .accessibilityLabel("Time of day")
                .accessibilityValue(context.date.formatted(date: .omitted, time: .shortened))
        }
    }
}

// MARK: - Preview

private struct PresenterPreviewCard: View {
    @Bindable var session: PresenterSession

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                CanvasPreview(session: session, showsAsOnTeleprompter: session.showsAsOnTeleprompter,
                              settings: session.settings)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Preview of the prompter text")
            .accessibilityValue(PresenterStatus.stateWord(for: session.engine.state, holdSeconds: session.engine.holdSecondsLeft))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(10)
            HStack(spacing: 12) {
                PresenterTheme.caption(session.showsAsOnTeleprompter ? "Preview · as on the teleprompter" : "Preview")
                Spacer()
                Toggle("Show as on the teleprompter", isOn: $session.showsAsOnTeleprompter)
                    .toggleStyle(AmberSwitchStyle())
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background(PresenterTheme.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(PresenterTheme.hairline, lineWidth: 1))
    }
}

/// The output's canvas again, live, for the Presenter view.
private struct CanvasPreview: NSViewRepresentable {
    let session: PresenterSession
    /// Passed in so SwiftUI updates the view when they change.
    let showsAsOnTeleprompter: Bool
    let settings: PrompterSettings

    func makeNSView(context: Context) -> PrompterCanvasView {
        PrompterCanvasView(session: session, role: .preview)
    }

    func updateNSView(_ view: PrompterCanvasView, context: Context) {
        view.refresh()
    }

    static func dismantleNSView(_ view: PrompterCanvasView, coordinator: ()) {
        view.stopDisplayLink()
        view.session.unregister(view)
    }
}

// MARK: - Timing

private struct PresenterTimingPanel: View {
    let session: PresenterSession
    let isCompact: Bool
    /// The top bar has no room for the state pill: it shows here instead.
    var showsStatePill = false

    var body: some View {
        let engine = session.engine
        VStack(alignment: .leading, spacing: isCompact ? 10 : 18) {
            if isCompact {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        PresenterTheme.caption("Time left").accessibilityHidden(true)
                        bigClock(engine.remainingSeconds, size: 96)
                    }
                    Spacer()
                    if showsStatePill { StatePill(session: session) }
                }
            } else {
                PresenterTheme.caption("Time left").accessibilityHidden(true)
                bigClock(engine.remainingSeconds, size: 120)
                    .padding(.top, -10)
            }
            ProgressTrack(progress: engine.progress)
            HStack(alignment: .top) {
                stat("Elapsed", TimeFormatting.clock(Double(session.elapsedSeconds)))
                Spacer()
                stat("Progress", PresenterStatus.percent(engine.progress))
                Spacer()
                stat("Pace", engine.speedLabel)
            }
            if !isCompact {
                Rectangle().fill(PresenterTheme.hairline).frame(height: 1)
                KeyLegend(isStrip: false)
                Spacer(minLength: 0)
            }
        }
        .padding(isCompact ? 18 : 26)
        .frame(maxHeight: isCompact ? nil : .infinity, alignment: .top)
        .background(PresenterTheme.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(PresenterTheme.hairline, lineWidth: 1))
    }

    private func bigClock(_ seconds: Double, size: CGFloat) -> some View {
        Text(TimeFormatting.clock(seconds))
            .font(.system(size: size, weight: .bold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .accessibilityLabel("Time left")
            .accessibilityValue(TimeFormatting.clock(seconds))
            .accessibilityIdentifier("presenter.timeLeft")
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            PresenterTheme.caption(title)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }
}

private struct ProgressTrack: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(PresenterTheme.accent)
                    .frame(width: proxy.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}

/// The keyboard, at a glance: a list in the wide layout, a wrapping strip in the compact one.
private struct KeyLegend: View {
    let isStrip: Bool

    static let rows: [(keys: [String], action: String)] = [
        (["Space", "Return"], "Start or pause"),
        (["↑", "←", "PgUp"], "Back a line"),
        (["↓", "→", "PgDn"], "Forward a line"),
        (["⇧"], "Hold with those: a paragraph at a time"),
        (["−", "+"], "Slower, faster"),
        (["0"], "Back to top"),
        (["Esc"], "Pause, then stop presenting"),
    ]

    var body: some View {
        if isStrip {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(Self.rows, id: \.action) { row($0) }
            }
            .padding(.horizontal, 6)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Keys")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                PresenterTheme.caption("Keys")
                ForEach(Self.rows, id: \.action) { row($0) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Keys")
        }
    }

    private func row(_ row: (keys: [String], action: String)) -> some View {
        HStack(spacing: 6) {
            ForEach(row.keys, id: \.self) { KeyHint($0) }
            Text(row.action)
                .font(.system(size: 14))
                .foregroundStyle(PresenterTheme.secondary)
                .padding(.leading, 6)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .accessibilityElement(children: .combine)
    }
}

struct KeyHint: View {
    let key: String

    init(_ key: String) {
        self.key = key
    }

    var body: some View {
        Text(key)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 7)
            .frame(minWidth: 24, minHeight: 22)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.14), lineWidth: 1))
    }
}

// MARK: - Transport

private struct PresenterTransport: View {
    let session: PresenterSession
    let isCompact: Bool

    var body: some View {
        VStack(spacing: isCompact ? 8 : 12) {
            // Room for the start prompt, which is drawn centred on the Start button (see `row`), not on the whole row:
            // the speed controls make the row lopsided, so the row's centre is off to the side of Start.
            if PresenterStatus.startPrompt(for: session.engine.state) != nil {
                Color.clear.frame(height: promptHeight)
            }
            // Narrow windows: the same buttons without their captions.
            ViewThatFits(in: .horizontal) {
                row(showsTitles: true)
                row(showsTitles: false)
            }
        }
        .padding(isCompact ? 12 : 16)
        .frame(maxWidth: .infinity)
        .background(PresenterTheme.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(PresenterTheme.hairline, lineWidth: 1))
    }

    private var promptFontSize: CGFloat { isCompact ? 18 : 22 }
    private var promptHeight: CGFloat { (promptFontSize * 1.25).rounded(.up) }
    private var promptGap: CGFloat { isCompact ? 8 : 12 }

    private func row(showsTitles: Bool) -> some View {
        let state = session.engine.state
        let size: CGFloat = isCompact ? 58 : 72
        return HStack(spacing: isCompact ? 8 : 12) {
            TransportButton(title: "Back to top", systemImage: "arrow.up.to.line", size: size, showsTitle: showsTitles) {
                session.backToTop()
            }
            TransportButton(title: "Jump back", systemImage: "arrow.uturn.backward", size: size, showsTitle: showsTitles) {
                session.jumpBack()
            }
            TransportButton(title: "Line back", systemImage: "chevron.up", size: size, showsTitle: showsTitles) {
                session.stepLine(-1)
            }
            Button { session.togglePlay() } label: {
                HStack(spacing: 12) {
                    Image(systemName: state == .playing || state.isCountdown ? "pause.fill" : "play.fill")
                        .font(.system(size: isCompact ? 22 : 28, weight: .bold))
                    Text(PresenterStatus.primaryAction(for: state))
                        .font(.system(size: isCompact ? 22 : 28, weight: .bold))
                }
                .foregroundStyle(.black)
                .frame(minWidth: isCompact ? 170 : 230)
                .frame(height: size + 12)
                .background(PresenterTheme.accent, in: RoundedRectangle(cornerRadius: 18))
                .contentShape(RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(PressableStyle())
            .accessibilityIdentifier("presenter.playPause")
            .overlay(alignment: .top) {
                if let prompt = PresenterStatus.startPrompt(for: state) {
                    Text(prompt)
                        .font(.system(size: promptFontSize, weight: .bold))
                        .foregroundStyle(PresenterTheme.accent)
                        .fixedSize()
                        .frame(height: promptHeight)
                        .offset(y: -(promptHeight + promptGap))
                        .accessibilityIdentifier("presenter.startPrompt")
                }
            }
            TransportButton(title: "Line forward", systemImage: "chevron.down", size: size, showsTitle: showsTitles) {
                session.stepLine(1)
            }
            Rectangle().fill(PresenterTheme.hairline).frame(width: 1, height: size)
                .padding(.horizontal, isCompact ? 2 : 6)
            SpeedControl(session: session, size: size)
        }
        .fixedSize()
    }
}

private struct TransportButton: View {
    let title: String
    let systemImage: String
    let size: CGFloat
    var showsTitle = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.3, weight: .semibold))
                if showsTitle {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(PresenterTheme.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .frame(minWidth: showsTitle ? size + 18 : size, minHeight: size + 12)
            .padding(.horizontal, 4)
            .background(PresenterTheme.raised, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(title)
        .help(title)
    }
}

private struct SpeedControl: View {
    let session: PresenterSession
    let size: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            stepButton("minus", label: "Slower") { session.speedStep(-5) }
            VStack(spacing: 2) {
                PresenterTheme.caption("Speed")
                Text(session.engine.speedLabel)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(minWidth: 120)
            stepButton("plus", label: "Faster") { session.speedStep(5) }
        }
    }

    private func stepButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .bold))
                .frame(width: size, height: size + 12)
                .background(PresenterTheme.raised, in: RoundedRectangle(cornerRadius: 14))
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
        .help(label)
    }
}

/// Dims a little while pressed.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

extension PlaybackState {
    var isCountdown: Bool {
        if case .countdown = self { true } else { false }
    }
}
