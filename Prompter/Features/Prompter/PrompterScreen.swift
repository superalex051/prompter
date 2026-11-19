import SwiftUI

/// The prompter, presented full screen over the library. Reads the script once when it opens.
///
/// The canvas (text, dimming, reading-line markers, HUD, countdown) is mirrored/flipped/rotated as one unit; the close
/// button and the settings sheet are not, because they are for the person touching the phone.
struct PrompterScreen: View {
    let scriptID: Script.ID
    /// Start the countdown as soon as the text is laid out (`-autoStart`, for screenshots).
    var autoStart = false
    /// Open the settings sheet right away (`-route prompterSettings`, for screenshots).
    var opensSettings = false

    @Environment(ScriptStore.self) private var scriptStore
    @Environment(SettingsStore.self) private var settingsStore
    @State private var controller: PrompterController?

    var body: some View {
        ZStack {
            Color(settingsStore.settings.scheme.backgroundUIColor)
                .ignoresSafeArea()
            if let controller {
                PrompterStage(controller: controller, opensSettings: opensSettings)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear(perform: open)
    }

    private func open() {
        guard controller == nil else { return }
        Self.applyLaunchOrientationOptions(to: settingsStore)
        let script = scriptStore.script(id: scriptID)
        let controller = PrompterController(
            scriptTitle: script?.displayTitle ?? "Untitled",
            body: script?.body ?? "",
            settings: settingsStore.settings
        )
        self.controller = controller
        // Safe before the first layout pass: the engine waits for text, then counts down.
        if autoStart { controller.engine.start() }
    }

    /// `-demoData -landscapeOnly NO` (screenshots, foldable checks): the first prompter of the launch opens with "Landscape
    /// only" set that way; `-landscapeSide left` makes its lock pick that side. Only the throwaway demo settings and side
    /// store are touched, and only once, so a later toggle by hand stays.
    @MainActor private static var appliedLaunchOrientationOptions = false

    private static func applyLaunchOrientationOptions(to settingsStore: SettingsStore) {
        guard !appliedLaunchOrientationOptions else { return }
        appliedLaunchOrientationOptions = true
        let options = LaunchOptions()
        guard options.demoData else { return }
        if let isOn = options.landscapeOnly { settingsStore.settings.lockLandscape = isOn }
        if let side = options.landscapeSide { OrientationLock.rememberSide(side == .left ? .landscapeLeft : .landscapeRight) }
    }
}

/// The canvas's share of `PrompterAvoidance`: the active fold and camera in canvas points, the way back to the screen
/// (to break ties towards the screen's trailing side, whatever the mirror), and the countdown digit's area. All empty
/// unless something is in the way, so the canvas lays out exactly as it always has on iPhone and iPad.
private struct CanvasAvoidance {
    var blocks: [CGRect] = []
    var toScreen: CGAffineTransform = .identity
    var countdownArea: CGRect?
}

/// What the orientation lock hears about the prompter's window. The orientation is in it so a half turn (same size,
/// other way up, which the inner screen of a foldable does on its own) is reported too: the reader's body runs again when
/// the camera's region moves round the screen.
private struct WindowReport: Equatable {
    var size: CGSize
    var isFoldable: Bool
    var isHingeClosed: Bool?
    var orientation: UIInterfaceOrientation?
}

/// Everything on screen once the controller exists.
private struct PrompterStage: View {
    let controller: PrompterController
    let opensSettings: Bool

    @Environment(SettingsStore.self) private var settingsStore
    @Environment(PrompterRemoteHub.self) private var remoteHub: PrompterRemoteHub?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    @State private var isShowingSettings = false
    /// The device has a hinge (iPhone Duo): a fold mid-take keeps the exact place at the reading line.
    @State private var isFoldable = false
    /// Foldables: the hinge is closed (the cover is in use). Tells the orientation lock which screen the window is on.
    @State private var isHingeClosed: Bool?
    /// Bumped on every touch; the close button shows for 3 s after the last one.
    @State private var touchCount = 0
    @State private var recentlyTouched = false

    private var engine: ScrollEngine { controller.engine }
    private var settings: PrompterSettings { settingsStore.settings }

    var body: some View {
        @Bindable var settingsStore = settingsStore

        GeometryReader { proxy in
            // Only a foldable steps around the fold and its camera: an iPhone on iOS 27.1 reports its Dynamic Island as
            // a reserved region too, and its prompter must stay exactly as it is.
            transformedCanvas(screenSize: proxy.size, avoiding: isFoldable ? proxy.activeReservedRects : [])
                // A fold moves the window to the other screen; the orientation lock follows (foldables only).
                .onChange(of: windowReport(size: proxy.size), initial: true) { _, report in
                    OrientationLock.windowChanged(
                        size: report.size, isFoldable: report.isFoldable, isHingeClosed: report.isHingeClosed
                    )
                }
        }
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) { closeButton }
        // In landscape on iPhone a sheet would cover the whole prompter, so the settings float in a popover there and
        // edits show live beside it; elsewhere it's the usual sheet (medium and large detents).
        .sheet(isPresented: settingsPresentation(asPopover: false)) {
            PrompterSettingsSheet(settings: $settingsStore.settings)
        }
        .popover(
            isPresented: settingsPresentation(asPopover: true),
            attachmentAnchor: .point(UnitPoint(x: 0.97, y: 0.02)),
            arrowEdge: .top
        ) {
            PrompterSettingsSheet(settings: $settingsStore.settings)
                .frame(idealWidth: 400, idealHeight: 640)
                .presentationCompactAdaptation(.popover)
        }
        .onChange(of: isShowingSettings) { _, isShowing in
            if DuoProbe.isEnabled { DuoProbe.log("prompter settings \(isShowing ? "shown" : "hidden")") }
            if !isShowing { controller.focusKeys() }
        }
        // Settings sheet → engine (live), engine speed steps (keys, later the watch) → saved settings.
        .onChange(of: settingsStore.settings) { _, newValue in engine.settings = newValue }
        .onChange(of: engine.settings) { _, newValue in self.settingsStore.settings = newValue }
        .onChange(of: settingsStore.settings.lockLandscape) { _, isOn in OrientationLock.setLandscapeOnly(isOn) }
        .onChange(of: scenePhase) { _, phase in sceneChanged(to: phase) }
        .onAppear(perform: appear)
        .onDisappear(perform: disappear)
        .task(id: touchCount) {
            guard touchCount > 0 else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            recentlyTouched = false
        }
        .task {
            guard opensSettings else { return }
            // Let the full-screen presentation and the rotation finish first.
            try? await Task.sleep(for: .milliseconds(800))
            openSettings()
        }
        .modifier(FoldableDeviceReader(isFoldable: $isFoldable, isHingeClosed: $isHingeClosed))
        .duoProbe(DuoProbe.isEnabled, label: "prompter ")
    }

    /// Off a foldable only the size matters (and `windowChanged` ignores it), so the orientation isn't read there.
    private func windowReport(size: CGSize) -> WindowReport {
        WindowReport(
            size: size, isFoldable: isFoldable, isHingeClosed: isHingeClosed,
            orientation: isFoldable ? OrientationLock.interfaceOrientation : nil
        )
    }

    // MARK: Canvas

    /// The canvas, rotated (for 90°/270° its frame swaps width and height first), then mirrored/flipped, as one unit.
    /// `blocks`: the active fold and the camera, in screen points (see `PrompterAvoidance`); empty on iPhone and iPad.
    private func transformedCanvas(screenSize: CGSize, avoiding blocks: [CGRect]) -> some View {
        let rotation = settings.rotation
        let canvasSize = PrompterCanvasTransform.canvasSize(rotation: rotation, screenSize: screenSize)
        let transform = PrompterCanvasTransform.make(
            rotation: rotation,
            mirror: settings.mirrorHorizontal,
            flip: settings.flipVertical,
            canvasSize: canvasSize
        )
        return canvas(size: canvasSize, avoidance: canvasAvoidance(screenSize: screenSize, blocks: blocks))
            .frame(width: canvasSize.width, height: canvasSize.height)
            .transformEffect(transform)
            .frame(width: screenSize.width, height: screenSize.height)
    }

    /// The fold and the camera brought into canvas points, and where the countdown digit goes.
    private func canvasAvoidance(screenSize: CGSize, blocks: [CGRect]) -> CanvasAvoidance {
        guard !blocks.isEmpty else { return CanvasAvoidance() }
        let toScreen = PrompterCanvasTransform.canvasToScreen(
            rotation: settings.rotation, mirror: settings.mirrorHorizontal, flip: settings.flipVertical,
            screenSize: screenSize
        )
        let toCanvas = toScreen.inverted()
        return CanvasAvoidance(
            blocks: blocks.map { $0.applying(toCanvas) },
            toScreen: toScreen,
            countdownArea: PrompterAvoidance.countdownArea(screen: screenSize, blocks: blocks)?.applying(toCanvas)
        )
    }

    private func canvas(size: CGSize, avoidance: CanvasAvoidance) -> some View {
        let style = PrompterTextStyle(settings: settings, canvasSize: size, isPad: PrompterTextView.scalesFont(canvasSize: size))
        let foreground = Color(settings.scheme.foregroundUIColor)
        let background = Color(settings.scheme.backgroundUIColor)
        // The amber of the pause cues, deepened per scheme so it holds its contrast on white too.
        let accent = Color(settings.scheme.cueUIColor)
        let shortSide = min(size.width, size.height)
        let hudInset = max(style.sideInset, 44)

        return ZStack {
            PrompterCanvas(controller: controller, settings: settings, callbacks: callbacks, isFoldable: isFoldable)

            ReadingLineOverlay(
                readingLineY: style.readingLineY,
                sideInset: style.sideInset,
                dimmedOpacity: settings.dimmedOpacity,
                background: background,
                markerColor: accent
            )
            .allowsHitTesting(false)

            if controller.isEmpty {
                emptyMessage(foreground: foreground)
                    .allowsHitTesting(false)
            }

            PrompterHUD(
                engine: engine,
                foreground: foreground,
                background: background,
                accent: accent,
                horizontalInset: hudInset,
                fontSize: min(max(shortSide * 0.042, 15), 28),
                avoiding: avoidance.blocks,
                toScreen: avoidance.toScreen
            )
            .frame(maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)

            CountdownOverlay(
                engine: engine, foreground: foreground, background: background, canvasSize: size,
                digitArea: avoidance.countdownArea
            )
            .allowsHitTesting(false)
        }
        .coordinateSpace(.named(PrompterHUD.canvasSpace))
        .background(background)
    }

    private func emptyMessage(foreground: Color) -> some View {
        VStack(spacing: 8) {
            Text("This script is empty")
                .font(.title.weight(.heavy))
            Text("Add some text in the editor, then come back.")
                .font(.title3)
                .opacity(0.7)
        }
        .foregroundStyle(foreground)
        .multilineTextAlignment(.center)
        .padding(32)
    }

    private var callbacks: PrompterTextView.Callbacks {
        PrompterTextView.Callbacks(
            onTouch: noteTouch,
            onOpenSettings: openSettings,
            onExit: close,
            onFontSizeCommit: { size in settingsStore.settings.fontSize = size }
        )
    }

    // MARK: Close button

    /// Always visible unless the text is moving (or counting down); then only for 3 s after a touch.
    private var showsCloseButton: Bool {
        !engine.needsFrames || recentlyTouched
    }

    /// Out of the view tree while hidden, not just transparent: the faded-out button used to stay in the accessibility
    /// tree even with `accessibilityHidden` (UI tests still found it while the text played), so VoiceOver could land on an
    /// invisible control. It sits 12 pt inside the safe area's top leading corner, and steps off an active fold or the
    /// camera if one is there (`PrompterAvoidance.buttonOffset`), read in the same safe-area coordinates.
    @ViewBuilder private var closeButton: some View {
        if isFoldable {
            GeometryReader { proxy in
                closeButtonContent
                    .offset(PrompterAvoidance.buttonOffset(
                        button: CGRect(x: 12, y: 12, width: 44, height: 44),
                        screen: proxy.size,
                        blocks: proxy.activeReservedRects
                    ))
            }
        } else {
            closeButtonContent
        }
    }

    private var closeButtonContent: some View {
        ZStack(alignment: .topLeading) {
            if showsCloseButton {
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 34))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color(white: 0.24))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("prompter.close")
                .padding(12)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showsCloseButton)
    }

    // MARK: Actions

    private func noteTouch() {
        touchCount += 1
        recentlyTouched = true
    }

    /// `isShowingSettings` as either the sheet or the popover, whichever fits the current size class.
    private func settingsPresentation(asPopover: Bool) -> Binding<Bool> {
        Binding(
            get: { isShowingSettings && (verticalSizeClass == .compact) == asPopover },
            set: { isPresented in
                if !isPresented { isShowingSettings = false }
            }
        )
    }

    private func openSettings() {
        guard !isShowingSettings else { return }
        engine.pause()
        isShowingSettings = true
    }

    private func close() {
        dismiss()
    }

    /// A call, Siri, Control Center or the side button: the take stops (see `PrompterController.sceneChanged(to:)`).
    /// The hub learns whether the prompter is still on screen (it refuses to start one in the background) and tells the
    /// watch at once ("Paused", or "Open Prompter on your iPhone"), rather than on its next push, which may not come
    /// before the app is suspended.
    private func sceneChanged(to phase: ScenePhase) {
        controller.sceneChanged(to: phase)
        remoteHub?.prompterVisibilityChanged(phase != .background)
    }

    /// The app keeps the screen awake only while the prompter is open. Nothing else in the app touches the idle timer, so
    /// closing always hands it back (remembering the old value on every appear could leave it stuck off: a second
    /// appear without a disappear would remember "disabled" as the value to restore).
    private func appear() {
        if DuoProbe.isEnabled { DuoProbe.log("prompter appear, landscape only \(settings.lockLandscape)") }
        UIApplication.shared.isIdleTimerDisabled = true
        OrientationLock.prompterOpened(landscapeOnly: settings.lockLandscape)
        remoteHub?.attach(engine: engine, scriptTitle: controller.scriptTitle)
        remoteHub?.prompterVisibilityChanged(scenePhase != .background)
    }

    private func disappear() {
        if DuoProbe.isEnabled { DuoProbe.log("prompter disappear, state \(engine.state)") }
        UIApplication.shared.isIdleTimerDisabled = false
        OrientationLock.prompterClosed()
        remoteHub?.detach(engine: engine)
        controller.close()
    }
}
