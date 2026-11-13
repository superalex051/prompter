import AppKit
import Observation
import SwiftUI

/// The windows of one presenting session and everything around them:
/// - the **output** (`PrompterCanvasView`, role `.output`): borderless and black over the whole teleprompter screen, above
///   the menu bar and the Dock, pointer hidden; on a single-screen Mac an ordinary window instead;
/// - the **Presenter view** (SwiftUI): full screen on the other screen (the laptop), or a window beside the output;
/// - the screens: picked by `DisplayPicker`, the person's pick remembered, re-planned when screens come and go;
/// - the keys (a local key monitor while presenting), display sleep (held off), the menu bar and Dock (hidden while the
///   Presenter view fills its screen).
@MainActor @Observable
final class PresentingController {
    let session: PresenterSession
    private(set) var screens: [DisplayDescriptor] = []
    private(set) var plan: DisplayPlan?
    /// A short line for the Presenter view about something that just happened to the screens ("The teleprompter screen
    /// disconnected. Paused."). Clears itself after `noticeDuration`.
    private(set) var notice: String?

    @ObservationIgnored var onStop: () -> Void = {}
    /// The Presenter view switched to another script.
    @ObservationIgnored var onScriptSwitch: (Script.ID) -> Void = { _ in }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let request: OutputScreenRequest?
    @ObservationIgnored private(set) var outputWindow: NSWindow?
    @ObservationIgnored private(set) var presenterWindow: NSWindow?
    @ObservationIgnored private(set) var outputView: PrompterCanvasView?
    @ObservationIgnored private var presenterHost: NSView?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let sleepBlocker = DisplaySleepBlocker()
    @ObservationIgnored private var savedPresentationOptions: NSApplication.PresentationOptions?
    @ObservationIgnored private var windowDelegate: WindowCloseObserver?
    @ObservationIgnored private var isClosing = false
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// How long a notice stays up.
    @ObservationIgnored var noticeDuration: Duration = .seconds(6)

    static let rememberedOutputKey = "presenterOutputDisplay"
    nonisolated static let outputLostNotice = "The teleprompter screen disconnected. Paused."
    nonisolated static let outputConnectedNotice = "Teleprompter screen connected."
    nonisolated static let presenterLostNotice = "The Presenter view's screen disconnected. Paused."

    /// `screens`: the connected screens (tests pass their own; nil reads them from AppKit).
    init(session: PresenterSession, defaults: UserDefaults, request: OutputScreenRequest?, screens: [DisplayDescriptor]? = nil) {
        self.session = session
        self.defaults = defaults
        self.request = request
        self.screens = screens ?? ScreenCatalog.descriptors()
        plan = DisplayPicker.plan(screens: self.screens, request: request, remembered: Self.remembered(in: defaults))
    }

    /// The size the output will have on the planned screen (before its window exists).
    static func plannedOutputSize(defaults: UserDefaults, request: OutputScreenRequest?) -> CGSize {
        let screens = ScreenCatalog.descriptors()
        guard let plan = DisplayPicker.plan(screens: screens, request: request, remembered: remembered(in: defaults)),
              let screen = screens.first(where: { $0.id == plan.output })
        else { return CGSize(width: 1920, height: 1080) }
        return plan.isSingleScreen ? singleScreenFrames(in: screen.frame).output.size : screen.frame.size
    }

    // MARK: Open and close

    func open() {
        let output = PrompterCanvasView(session: session, role: .output)
        outputView = output
        let presenter = NSHostingView(rootView: PresenterView(controller: self).preferredColorScheme(.dark))
        presenterHost = presenter
        windowDelegate = WindowCloseObserver { [weak self] in self?.windowClosedByPerson() }
        applyPlan()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread, in the app's event loop.
            nonisolated(unsafe) let event = event
            nonisolated(unsafe) var result: NSEvent? = event
            MainActor.assumeIsolated {
                if let self { result = self.handleKey(event) }
            }
            return result
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        sleepBlocker.begin()
        // (Not while hosting the unit tests: they open windows off screen and must not take over the Mac.)
        if !MacLaunchOptions().isRunningTests { NSApp.activate() }
    }

    /// Closes both windows and puts everything back (keys, the menu bar and Dock, display sleep).
    func close() {
        guard !isClosing else { return }
        isClosing = true
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        sleepBlocker.end()
        restorePresentationOptions()
        noticeTask?.cancel()
        noticeTask = nil
        session.close()
        outputView?.stopDisplayLink()
        if let outputView { session.unregister(outputView) }
        let hadWindows = outputWindow != nil || presenterWindow != nil
        for window in [outputWindow, presenterWindow].compactMap(\.self) {
            window.delegate = nil
            window.orderOut(nil)
            // The content goes now: the Presenter view holds this controller, so a window AppKit keeps around a little
            // longer must not keep the output's canvas (and its text tiles) alive with it.
            window.contentView = nil
            window.close()
        }
        outputWindow = nil
        presenterWindow = nil
        // Let go of the views: the Presenter view (in `presenterHost`) refers back to this controller.
        outputView = nil
        presenterHost = nil
        windowDelegate = nil
        // Back to the library (opened again if it was closed meanwhile).
        if hadWindows { LibraryWindow.show() }
    }

    // MARK: Screens

    var isSingleScreen: Bool { plan?.isSingleScreen ?? true }

    func screenName(_ id: DisplayDescriptor.ID?) -> String {
        screens.first { $0.id == id }?.name ?? "No screen"
    }

    /// "2560 × 1440" for a screen, or nil when it isn't connected.
    func screenResolution(_ id: DisplayDescriptor.ID?) -> String? {
        screens.first { $0.id == id }?.resolutionText
    }

    /// One screen only (and not the "output keeps the lone screen" case): the Presenter view says how to get the
    /// prompter onto a teleprompter screen.
    var showsSingleScreenHint: Bool {
        guard let plan else { return false }
        return plan.isSingleScreen && !plan.outputStaysFullScreen
    }

    /// How far down the Presenter view's content starts: the top inset of its screen (a MacBook's notch) while the
    /// Presenter view fills that screen; an ordinary window needs none (it sits below the menu bar on its own).
    var presenterTopInset: CGFloat {
        guard let plan, showsPresenterFullScreen,
              let screen = ScreenCatalog.screen(withID: plan.presenter)
        else { return 0 }
        return Self.topInset(safeAreaTop: screen.safeAreaInsets.top)
    }

    private var showsPresenterFullScreen: Bool {
        guard let plan else { return false }
        return !(plan.isSingleScreen && !plan.outputStaysFullScreen)
    }

    /// The inset for a screen with `safeAreaTop` (0 without a notch).
    nonisolated static func topInset(safeAreaTop: CGFloat) -> CGFloat {
        max(0, safeAreaTop)
    }

    /// The person picked the output screen (the Presenter view moves off it if it has to). Remembered.
    func chooseOutput(_ id: DisplayDescriptor.ID) {
        guard let plan, id != plan.output else { return }
        self.plan = DisplayPicker.choosing(output: id, from: plan, in: screens)
        remember()
        applyPlan()
    }

    /// The output and the Presenter view trade screens. Remembered.
    func swapScreens() {
        guard let plan, !plan.isSingleScreen else { return }
        self.plan = DisplayPicker.swapped(plan)
        remember()
        applyPlan()
    }

    private func screensChanged() {
        guard !isClosing else { return }
        let previousScreens = Set(screens.map(\.id))
        screens = ScreenCatalog.descriptors()
        guard let plan else { return }
        guard let replan = DisplayPicker.replan(current: plan, screens: screens, remembered: Self.remembered(in: defaults))
        else { return }
        // A screen of the take is gone: stop the text where it is rather than let it run on unseen, or run on while the
        // person has lost the controls.
        if replan.isDisruptive { session.pause() }
        if let notice = Self.notice(for: replan, previous: plan, previousScreens: previousScreens) { show(notice: notice) }
        self.plan = replan.plan
        applyPlan()
    }

    /// What the Presenter view says about a re-plan, if anything.
    nonisolated static func notice(
        for replan: DisplayPicker.Replan, previous: DisplayPlan, previousScreens: Set<DisplayDescriptor.ID>
    ) -> String? {
        if replan.outputLost { return outputLostNotice }
        if replan.presenterLost { return presenterLostNotice }
        if replan.plan.output != previous.output, !previousScreens.contains(replan.plan.output) {
            return outputConnectedNotice
        }
        return nil
    }

    /// Shows `notice` for `noticeDuration`.
    func show(notice text: String) {
        notice = text
        noticeTask?.cancel()
        let duration = noticeDuration
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            self.notice = nil
        }
    }

    private func remember() {
        guard let plan, let output = screens.first(where: { $0.id == plan.output }) else { return }
        let remembered = RememberedOutput(displayID: output.id, name: output.name)
        if let data = try? JSONEncoder().encode(remembered) { defaults.set(data, forKey: Self.rememberedOutputKey) }
    }

    static func remembered(in defaults: UserDefaults) -> RememberedOutput? {
        defaults.data(forKey: rememberedOutputKey).flatMap { try? JSONDecoder().decode(RememberedOutput.self, from: $0) }
    }

    // MARK: Windows

    /// Puts the output and the Presenter view where the plan says, making new windows when the kind of setup (one
    /// screen or two) changes.
    private func applyPlan() {
        guard let plan, let outputView, let presenterHost,
              let outputScreen = screens.first(where: { $0.id == plan.output }),
              let presenterScreen = screens.first(where: { $0.id == plan.presenter })
        else { return }
        let single = plan.isSingleScreen

        if single, !plan.outputStaysFullScreen {
            let frames = Self.singleScreenFrames(in: ScreenCatalog.screen(withID: outputScreen.id)?.visibleFrame
                ?? outputScreen.frame)
            let output = window(current: outputWindow, borderless: false, title: "Prompter Output", content: outputView)
            let presenter = window(current: presenterWindow, borderless: false, title: "Presenter", content: presenterHost)
            output.level = .normal
            output.collectionBehavior = [.managed]
            output.setFrame(frames.output, display: true)
            presenter.setFrame(frames.presenter, display: true)
            presenter.minSize = NSSize(width: 720, height: 560)
            outputView.hidesCursor = false
            outputWindow = output
            presenterWindow = presenter
            restorePresentationOptions()
        } else {
            let output = window(current: outputWindow, borderless: true, title: "Prompter Output", content: outputView)
            let presenter = window(current: presenterWindow, borderless: true, title: "Presenter", content: presenterHost)
            // Above the menu bar and the Dock of its screen, on every Space, out of the window cycle.
            output.level = .statusBar
            output.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            output.setFrame(outputScreen.frame, display: true)
            presenter.level = .normal
            presenter.collectionBehavior = [.fullScreenPrimary]
            presenter.setFrame(presenterScreen.frame, display: true)
            outputView.hidesCursor = true
            outputWindow = output
            presenterWindow = presenter
            // The Presenter view fills its screen: the menu bar and the Dock make way while Prompter is active.
            if savedPresentationOptions == nil { savedPresentationOptions = NSApp.presentationOptions }
            NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
        }
        outputWindow?.orderFrontRegardless()
        presenterWindow?.makeKeyAndOrderFront(nil)
        outputView.refresh()
    }

    /// The existing window if it is of the right kind, else a new one (the content moves over).
    private func window(current: NSWindow?, borderless: Bool, title: String, content: NSView) -> NSWindow {
        if let current, current.styleMask.contains(.titled) != borderless {
            return current
        }
        if let current {
            current.delegate = nil
            current.contentView = NSView()
            current.orderOut(nil)
            current.close()
        }
        let style: NSWindow.StyleMask = borderless
            ? [.borderless]
            : [.titled, .closable, .miniaturizable, .resizable]
        let window = PresentingWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: style,
                                      backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = !borderless
        window.animationBehavior = .none
        window.tabbingMode = .disallowed
        window.contentView = content
        window.delegate = windowDelegate
        return window
    }

    /// One screen: the output as a large window on the left, the Presenter view beside it on the right.
    static func singleScreenFrames(in visible: CGRect) -> (output: CGRect, presenter: CGRect) {
        let gap: CGFloat = 12
        let outputWidth = (visible.width * 0.56).rounded()
        let outputHeight = min(visible.height, (outputWidth * 10 / 16).rounded())
        let output = CGRect(x: visible.minX, y: visible.maxY - outputHeight, width: outputWidth, height: outputHeight)
        let presenter = CGRect(x: output.maxX + gap, y: visible.minY,
                               width: max(visible.width - outputWidth - gap, 360), height: visible.height)
        return (output, presenter)
    }

    private func restorePresentationOptions() {
        guard let saved = savedPresentationOptions else { return }
        NSApp.presentationOptions = saved
        savedPresentationOptions = nil
    }

    private func windowClosedByPerson() {
        guard !isClosing else { return }
        onStop()
    }

    // MARK: Keys

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard !isClosing else { return event }
        let isOurs = event.window != nil && (event.window === outputWindow || event.window === presenterWindow)
        let responder = event.window?.firstResponder
        let action = PresenterKeyRouting.action(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            target: isOurs ? .presenting : .otherWindow,
            isEditingText: PresenterKeyRouting.isTextInput(responder),
            focusedControl: PresenterKeyRouting.focusedControl(responder)
        )
        guard let action else { return event }
        if action == .exit {
            escape()
        } else {
            session.perform(action)
        }
        return nil
    }

    /// Esc: a take that is running pauses first (a stray press mid-take must not end it); otherwise presenting stops.
    func escape() {
        switch PresenterKeyRouting.escapeOutcome(for: session.engine.state) {
        case .pause: session.pause()
        case .stopPresenting: onStop()
        }
    }
}

/// A window that can take the keys even without a title bar (the borderless output and Presenter view).
final class PresentingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Tells the controller when the person closes one of the presenting windows (single-screen setup): that stops presenting.
private final class WindowCloseObserver: NSObject, NSWindowDelegate {
    let onClose: @MainActor () -> Void

    init(onClose: @escaping @MainActor () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { onClose() }
    }
}
