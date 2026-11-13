import AppKit
import Observation

/// One presenting session: the script, its scroll engine and everything the output, the preview and the Presenter view
/// share. The canvases (`PrompterCanvasView`) register here; the session wakes them when something moves the text and
/// tells them when the settings or the script change.
///
/// Settings: the `SettingsStore` is the truth. Its changes reach the engine and the canvases at once; speed steps made
/// through the engine (keys, transport) are written back to the store, so they persist.
@MainActor @Observable
final class PresenterSession {
    let scriptStore: ScriptStore
    let settingsStore: SettingsStore
    let engine: ScrollEngine

    private(set) var scriptID: Script.ID
    private(set) var scriptTitle: String
    private(set) var document: PrompterDocument
    /// The size of the output's screen or window, in points (the canvas is this, or swapped for 90°/270°).
    private(set) var outputScreenSize: CGSize
    /// Seconds spent playing since the take started (holds included, pauses not), whole seconds.
    private(set) var elapsedSeconds = 0
    /// The Presenter view's preview applies the output's mirror, flip and rotation.
    var showsAsOnTeleprompter: Bool {
        didSet { onPreferencesChange?() }
    }
    /// The Presenter view's settings panel is open.
    var isSettingsPanelOpen = false
    /// No countdown beeps (test launches).
    @ObservationIgnored var isMuted = false
    /// Called when the Presenter view's own preferences change (the launcher saves them).
    @ObservationIgnored var onPreferencesChange: (() -> Void)?

    @ObservationIgnored private var elapsed = 0.0
    @ObservationIgnored private var lastAdvance: TimeInterval?
    @ObservationIgnored private let canvases = NSHashTable<PrompterCanvasView>.weakObjects()
    @ObservationIgnored private var isClosed = false
    /// When a canvas's display link last delivered a frame (`CACurrentMediaTime`).
    @ObservationIgnored private var lastDisplayLinkFrame: TimeInterval = 0
    @ObservationIgnored private var fallbackTimer: Timer?

    init(
        scriptID: Script.ID,
        scriptStore: ScriptStore,
        settingsStore: SettingsStore,
        outputScreenSize: CGSize,
        showsAsOnTeleprompter: Bool = false
    ) {
        self.scriptStore = scriptStore
        self.settingsStore = settingsStore
        self.scriptID = scriptID
        let script = scriptStore.script(id: scriptID)
        scriptTitle = script?.displayTitle ?? "Untitled"
        document = PrompterDocument(body: script?.body ?? "", markdown: settingsStore.settings.markdown)
        self.outputScreenSize = outputScreenSize
        self.showsAsOnTeleprompter = showsAsOnTeleprompter
        engine = ScrollEngine(settings: settingsStore.settings)
        applyVoiceFallback()
        engine.onEvent = { [weak self] event in self?.handle(event) }
        observeSettings()
        observeScript()
    }

    var settings: PrompterSettings { settingsStore.settings }

    /// The take stops and nothing more reaches the canvases.
    func close() {
        isClosed = true
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        engine.pause()
    }

    // MARK: Commands

    func perform(_ action: PrompterKeyAction) {
        switch action {
        case .togglePlay: togglePlay()
        case .stepLine(let n): engine.stepLine(n)
        case .stepParagraph(let n): engine.stepParagraph(n)
        case .speedStep(let n): speedStep(n)
        case .backToTop: backToTop()
        case .exit: break   // the launcher stops presenting
        }
        wakeCanvases()
    }

    func togglePlay() {
        if engine.state == .idle || engine.state == .finished { resetElapsed() }
        engine.togglePlay()
        wakeCanvases()
    }

    func start() {
        if engine.state == .idle || engine.state == .finished { resetElapsed() }
        engine.start()
        wakeCanvases()
    }

    func pause() {
        engine.pause()
        wakeCanvases()
    }

    func backToTop() {
        engine.backToTop()
        resetElapsed()
        wakeCanvases()
    }

    func jumpBack() {
        engine.jumpBack()
        wakeCanvases()
    }

    func stepLine(_ direction: Int) {
        engine.stepLine(direction)
        wakeCanvases()
    }

    func speedStep(_ n: Int) {
        engine.speedStep(n)
        // Persist the new pace (the store hands it back to the engine unchanged).
        if settingsStore.settings != engine.settings { settingsStore.settings = engine.settings }
        wakeCanvases()
    }

    /// The scroll wheel or trackpad over the output or the preview: moves the text (paused), like a finger drag.
    func scrub(by delta: Double) {
        engine.scrub(by: delta)
        wakeCanvases()
    }

    /// Presents another script from the top (same settings, same screens).
    func switchScript(to id: Script.ID) {
        guard id != scriptID, let script = scriptStore.script(id: id) else { return }
        engine.backToTop()
        scriptID = id
        scriptTitle = script.displayTitle
        document = PrompterDocument(body: script.body, markdown: settings.markdown)
        resetElapsed()
        refreshCanvases()
    }

    // MARK: Frames

    /// Advances the engine to a display link's frame time. Every canvas calls this from its own display link (the output
    /// and the preview may be on screens with different refresh rates); a time at or before the last one is ignored, so
    /// the engine only ever moves forward.
    func advance(to time: TimeInterval) {
        if let lastAdvance, time <= lastAdvance { return }
        let dt = lastAdvance.map { min(time - $0, ScrollTiming.maxTickInterval) } ?? 0
        lastAdvance = time
        let wasPlaying = engine.state == .playing
        engine.tick(now: time)
        if wasPlaying, dt > 0 {
            elapsed += dt
            let whole = Int(elapsed)
            if whole != elapsedSeconds { elapsedSeconds = whole }
        }
    }

    /// The output's screen or window changed size.
    func outputScreenSizeChanged(to size: CGSize, from output: PrompterCanvasView? = nil) {
        guard size.width > 0, size.height > 0, size != outputScreenSize else { return }
        outputScreenSize = size
        refreshCanvases(except: output)
    }

    // MARK: Canvases

    func register(_ canvas: PrompterCanvasView) {
        canvases.add(canvas)
    }

    func unregister(_ canvas: PrompterCanvasView) {
        canvases.remove(canvas)
    }

    /// True when an output canvas is showing: it then feeds the engine its layout, and the preview doesn't.
    var hasOutputCanvas: Bool {
        canvases.allObjects.contains { $0.role == .output && $0.window != nil }
    }

    /// Something may have moved the text or changed the state: every canvas runs its display link until it is at rest.
    func wakeCanvases() {
        for canvas in canvases.allObjects { canvas.wake() }
        startFallbackTimerIfNeeded()
    }

    /// A canvas's display link delivered a frame.
    func noteDisplayLinkFrame() {
        lastDisplayLinkFrame = CACurrentMediaTime()
    }

    /// Display links only fire while their screen shows the window: none fire with the displays asleep or the window
    /// fully covered. So while the text should move and no display link has fired for a while, a 60 Hz timer drives the
    /// frames instead (the take's timing stays true; on screen the display links take over again at once).
    private func startFallbackTimerIfNeeded() {
        guard fallbackTimer == nil, !isClosed else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fallbackTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    private func fallbackTick() {
        let canvases = canvases.allObjects
        guard !isClosed, engine.needsFrames || canvases.contains(where: \.isRunningFrames) else {
            fallbackTimer?.invalidate()
            fallbackTimer = nil
            return
        }
        let now = CACurrentMediaTime()
        guard now - lastDisplayLinkFrame > 0.1 else { return }
        for canvas in canvases { canvas.fallbackFrame(at: now) }
    }

    /// Settings, the script or the output size changed: the output first (it hands the engine the new layout), then
    /// the previews, which show the engine's re-anchored position.
    private func refreshCanvases(except skipped: PrompterCanvasView? = nil) {
        let all = canvases.allObjects.filter { $0 !== skipped }
        for canvas in all where canvas.role == .output { canvas.refresh() }
        for canvas in all where canvas.role != .output { canvas.refresh() }
    }

    // MARK: Private

    private func handle(_ event: ScrollEngine.Event) {
        if event == .go || event == .resumed { lastAdvance = nil }
        if !isMuted { MacPrompterFeedback.play(for: event, settings: engine.settings) }
        wakeCanvases()
    }

    private func resetElapsed() {
        elapsed = 0
        elapsedSeconds = 0
    }

    /// The Mac doesn't listen (no voice-follow here): voice mode scrolls and times at the WPM pace, as on an iPhone
    /// that can't listen.
    private func applyVoiceFallback() {
        if engine.isVoiceMode, engine.voiceProblem == nil {
            engine.setVoiceProblem(.unsupported)
        }
    }

    private func settingsChanged() {
        guard !isClosed else { return }
        if engine.settings != settingsStore.settings { engine.settings = settingsStore.settings }
        applyVoiceFallback()
        // Markdown formatting switched: the script is shown again with (or without) it, keeping the reading line's place.
        if let script = scriptStore.script(id: scriptID) {
            let updated = PrompterDocument(body: script.body, markdown: settingsStore.settings.markdown)
            if updated != document { document = updated }
        }
        refreshCanvases()
    }

    /// Re-arms itself after every change (Observation reports one change per registration).
    private func observeSettings() {
        withObservationTracking {
            _ = settingsStore.settings
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed else { return }
                self.settingsChanged()
                self.observeSettings()
            }
        }
    }

    /// The presented script edited elsewhere (the editor behind, or a sync): the new text shows at once and the engine
    /// keeps the reading line on the same place in the script.
    private func observeScript() {
        withObservationTracking {
            _ = scriptStore.scripts
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed else { return }
                self.scriptsChanged()
                self.observeScript()
            }
        }
    }

    private func scriptsChanged() {
        guard let script = scriptStore.script(id: scriptID) else { return }
        if script.displayTitle != scriptTitle { scriptTitle = script.displayTitle }
        let updated = PrompterDocument(body: script.body, markdown: settings.markdown)
        guard updated != document else { return }
        document = updated
        refreshCanvases()
    }
}
