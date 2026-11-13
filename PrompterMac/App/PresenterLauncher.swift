import AppKit
import Observation

/// Starts and stops presenting a script: the full-screen output window on the chosen display plus the full-screen Presenter
/// view on the laptop (`PresentingController`). The library and the menu commands only call `present(scriptID:)` and
/// `stop()`.
///
/// `-route prompter` (with `-script sample`, `-outputScreen`, `-autoStart`, `-presenterSettings`, `-snapshot`) starts
/// presenting at launch; see `PresenterLaunchOptions`.
@MainActor @Observable
final class PresenterLauncher {
    /// The script being presented, or nil when nothing is.
    private(set) var presentingScriptID: Script.ID?

    var isPresenting: Bool { presentingScriptID != nil }

    /// The open session's windows, or nil.
    @ObservationIgnored private(set) var controller: PresentingController?
    /// Presenting started, switched to another script, or stopped (the Apple Watch remote tells the iPhone at once).
    @ObservationIgnored var onPresentingChange: () -> Void = {}
    @ObservationIgnored private var scriptStore: ScriptStore?
    @ObservationIgnored private var settingsStore: SettingsStore?
    @ObservationIgnored private let options: PresenterLaunchOptions
    /// Where the remembered output screen and the preview mode are kept: the app's defaults, or with `-demoData` (and in
    /// tests) the throwaway demo suite.
    @ObservationIgnored private let defaults: UserDefaults

    static let previewModeKey = "presenterPreviewAsOnTeleprompter"

    init(
        scriptStore: ScriptStore? = nil,
        settingsStore: SettingsStore? = nil,
        options: PresenterLaunchOptions = PresenterLaunchOptions(),
        defaults: UserDefaults? = nil
    ) {
        self.scriptStore = scriptStore
        self.settingsStore = settingsStore
        self.options = options
        let launch = MacLaunchOptions()
        self.defaults = defaults
            ?? (launch.usesThrowawayStorage ? UserDefaults(suiteName: PrompterMacApp.demoSettingsSuite) : nil)
            ?? .standard
        ScreenCatalog.onlyMainScreen = options.singleScreen
        if options.routesToPrompter, scriptStore != nil, settingsStore != nil, !launch.isRunningTests {
            Task { @MainActor [weak self] in await self?.runLaunchRoute() }
        }
    }

    /// For a launcher made before the stores.
    func attach(scriptStore: ScriptStore, settingsStore: SettingsStore) {
        self.scriptStore = scriptStore
        self.settingsStore = settingsStore
    }

    /// Opens the output and the Presenter view for `scriptID`, or switches the open session to it.
    func present(scriptID: Script.ID) {
        guard let scriptStore, let settingsStore, scriptStore.script(id: scriptID) != nil else { return }
        if let controller {
            controller.session.switchScript(to: scriptID)
            presentingScriptID = scriptID
            controller.presenterWindow?.makeKeyAndOrderFront(nil)
            onPresentingChange()
            return
        }
        let session = PresenterSession(
            scriptID: scriptID,
            scriptStore: scriptStore,
            settingsStore: settingsStore,
            outputScreenSize: PresentingController.plannedOutputSize(defaults: defaults, request: options.outputScreen),
            showsAsOnTeleprompter: options.previewMirrored || defaults.bool(forKey: Self.previewModeKey)
        )
        session.isMuted = options.isMuted
        session.isSettingsPanelOpen = options.opensSettings
        let defaults = defaults
        session.onPreferencesChange = { [weak session] in
            guard let session else { return }
            defaults.set(session.showsAsOnTeleprompter, forKey: Self.previewModeKey)
        }
        let controller = PresentingController(session: session, defaults: defaults, request: options.outputScreen)
        controller.onStop = { [weak self] in self?.stop() }
        controller.onScriptSwitch = { [weak self] id in
            self?.presentingScriptID = id
            self?.onPresentingChange()
        }
        self.controller = controller
        presentingScriptID = scriptID
        controller.open()
        onPresentingChange()
    }

    /// Closes both windows and restores everything (menu bar, Dock, display sleep, keys).
    func stop() {
        let wasPresenting = controller != nil
        controller?.close()
        controller = nil
        presentingScriptID = nil
        if wasPresenting { onPresentingChange() }
    }

    // MARK: Launch route

    private func runLaunchRoute() async {
        // Let the app finish launching and the library window appear first.
        while !NSApp.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        try? await Task.sleep(for: .milliseconds(600))
        guard let scriptStore else { return }
        let script = switch options.script {
        case .sample: scriptStore.script(id: SampleScript.id) ?? scriptStore.scripts.first
        case .markdown: scriptStore.script(id: DemoData.markdownScriptID) ?? scriptStore.scripts.first
        case .newest: scriptStore.scripts.first
        }
        guard let script else { return }
        present(scriptID: script.id)
        let presentedAt = ContinuousClock.now
        if options.autoStart { controller?.session.start() }

        guard let directory = options.snapshotDirectory else { return }
        for (index, time) in options.snapshotTimes.sorted().enumerated() {
            try? await Task.sleep(until: presentedAt + .milliseconds(Int(time * 1000)))
            guard let controller else { return }
            PresenterSnapshotter.write(controller, to: directory, prefix: "presenting-\(index + 1)")
        }
    }
}
