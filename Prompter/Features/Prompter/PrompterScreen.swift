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
        Self.applyLaunchLandscapeOnly(to: settingsStore)
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
    /// only" set that way. Only the throwaway demo settings are touched, and only once, so a later toggle by hand stays.
    @MainActor private static var appliedLaunchLandscapeOnly = false

    private static func applyLaunchLandscapeOnly(to settingsStore: SettingsStore) {
        guard !appliedLaunchLandscapeOnly else { return }
        appliedLaunchLandscapeOnly = true
        let options = LaunchOptions()
        guard options.demoData, let isOn = options.landscapeOnly else { return }
        settingsStore.settings.lockLandscape = isOn
    }
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
    /// Bumped on every touch; the close button shows for 3 s after the last one.
    @State private var touchCount = 0
    @State private var recentlyTouched = false

    private var engine: ScrollEngine { controller.engine }
    private var settings: PrompterSettings { settingsStore.settings }

    var body: some View {
        @Bindable var settingsStore = settingsStore

        GeometryReader { proxy in
            transformedCanvas(screenSize: proxy.size)
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
        .modifier(FoldableDeviceReader(isFoldable: $isFoldable))
        .duoProbe(DuoProbe.isEnabled, label: "prompter ")
    }

    // MARK: Canvas

    /// The canvas, rotated (for 90°/270° its frame swaps width and height first), then mirrored/flipped, as one unit.
    private func transformedCanvas(screenSize: CGSize) -> some View {
        let rotation = settings.rotation
        let canvasSize = PrompterCanvasTransform.isSideways(rotation)
            ? CGSize(width: screenSize.height, height: screenSize.width)
            : screenSize
        let transform = PrompterCanvasTransform.make(
            rotation: rotation,
            mirror: settings.mirrorHorizontal,
            flip: settings.flipVertical,
            canvasSize: canvasSize
        )
        return canvas(size: canvasSize)
            .frame(width: canvasSize.width, height: canvasSize.height)
            .transformEffect(transform)
            .frame(width: screenSize.width, height: screenSize.height)
    }

    private func canvas(size: CGSize) -> some View {
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
                fontSize: min(max(shortSide * 0.042, 15), 28)
            )
            .frame(maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)

            CountdownOverlay(engine: engine, foreground: foreground, background: background, canvasSize: size)
                .allowsHitTesting(false)
        }
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
    /// invisible control.
    private var closeButton: some View {
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
