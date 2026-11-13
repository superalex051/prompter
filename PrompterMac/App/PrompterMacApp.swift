import AppKit
import Network
import SwiftUI

@main
struct PrompterMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @State private var scriptStore: ScriptStore
    @State private var settingsStore: SettingsStore
    @State private var presenterLauncher: PresenterLauncher
    @State private var library: MacLibraryModel
    @State private var syncHost: SyncHost
    @State private var settingsRouter = MacSettingsRouter()
    private let libraryLaunch = LibraryLaunchOptions()

    /// The settings suite `-demoData` (and the test host) uses instead of the real settings. Emptied at every such launch.
    static let demoSettingsSuite = "PrompterMacDemo"

    init() {
        // AppKit opens a command-line argument it can't pair with an option as a file ("-demoData -snapshot dir" reads
        // as -demoData = "-snapshot" plus a file "dir"), and SwiftUI then opens no window. The debug options are ours.
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
        let options = MacLaunchOptions()
        let libraryLaunch = LibraryLaunchOptions()
        let store: ScriptStore
        let settings: SettingsStore
        let pairingStore: PairingStore
        if options.usesThrowawayStorage {
            // A throwaway library, throwaway settings and throwaway pairings, so the real ones (~/Library/Application
            // Support/Prompter and the app's defaults) are never touched by screenshots or tests.
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "PrompterMacDemo-\(UUID().uuidString)", directoryHint: .isDirectory)
            pairingStore = PairingStore(directory: directory)
            store = ScriptStore(
                directory: directory,
                initialScripts: { [markdownDemo = PresenterLaunchOptions().script == .markdown] in
                    libraryLaunch.emptyLibrary ? [] : DemoData.scripts(now: $0, includeMarkdown: markdownDemo)
                }
            )
            // UserDefaults only rejects a suite named like the app's bundle ID or NSGlobalDomain, so this never fails.
            let demoDefaults = UserDefaults(suiteName: Self.demoSettingsSuite)!
            demoDefaults.removePersistentDomain(forName: Self.demoSettingsSuite)
            settings = SettingsStore(defaults: demoDefaults)
        } else {
            store = ScriptStore()
            settings = SettingsStore()
            pairingStore = PairingStore(keyVault: KeychainPairingKeyVault())
        }
        let sync = SyncLaunchOptions()
        let host = SyncHost(
            library: store,
            pairing: pairingStore,
            name: options.demoData ? DemoData.macName : (Host.current().localizedName ?? "Mac"),
            isDemo: options.demoData,
            port: sync.port.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any,
            // `-syncPort` is the direct (loopback) mode for checks: no Bonjour, which is what needs Local Network access.
            advertises: sync.port == nil
        )
        store.onLocalChange = { [weak host] in host?.libraryChanged() }
        // The test host runs no sync: the tests make their own hosts.
        if !options.isRunningTests {
            host.start()
            // A debug code pairs any iPhone that knows it, so only a throwaway demo library ever opens one.
            if let code = sync.pairingCode, options.demoData { host.openStandingPairing(code: code) }
            if sync.demo, options.demoData {
                Task { @MainActor in
                    await SyncDemo.runOnMac(store: store, isConnected: { [weak host] in !(host?.connectedDeviceIDs.isEmpty ?? true) })
                }
            }
        }
        _syncHost = State(initialValue: host)
        let launcher = PresenterLauncher(scriptStore: store, settingsStore: settings)
        // The Apple Watch remote, relayed by a paired iPhone: commands reach the presenting session, statuses go back.
        let remote = MacRemoteControl(
            deviceName: host.name,
            session: { [weak launcher] in launcher?.controller?.session },
            publish: { [weak host] in host?.publishPresenterStatus($0) }
        )
        host.remoteHandler = { remote.handle($0) }
        host.presenterStatusProvider = { remote.status() }
        launcher.onPresentingChange = { remote.presentingChanged() }
        let model = MacLibraryModel(store: store, present: { launcher.present(scriptID: $0) })
        _scriptStore = State(initialValue: store)
        _settingsStore = State(initialValue: settings)
        _presenterLauncher = State(initialValue: launcher)
        _library = State(initialValue: model)
    }

    var body: some Scene {
        // One library window. (A second window would show the same library with its own selection, and the menu
        // commands act on one library.)
        Window("Prompter", id: LibraryWindow.id) {
            MacLibraryView(model: library, launch: libraryLaunch)
                .background(LibraryWindowOpenerCapture())
                .environment(scriptStore)
                .environment(settingsStore)
                .environment(presenterLauncher)
                .environment(syncHost)
                .environment(settingsRouter)
                .preferredColorScheme(.dark)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 1100, height: 700)
        .commands { MacLibraryCommands(model: library, launcher: presenterLauncher, settingsRouter: settingsRouter) }

        Settings {
            MacSettingsView(initialTab: libraryLaunch.settingsTab)
                .environment(scriptStore)
                .environment(settingsStore)
                .environment(syncHost)
                .environment(settingsRouter)
        }
    }
}

/// The app is dark-only, like the iPhone app: the whole of AppKit (title bar, menus, sheets) follows.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = MacLaunchOptions()
        guard !options.isRunningTests else { return }
        Task { @MainActor in
            if let directory = options.snapshotDirectory {
                await WindowSnapshotter.snapshotWhenReady(to: directory, settle: options.snapshotDelay ?? 1.5)
            }
            if let seconds = options.quitAfter {
                try? await Task.sleep(for: .seconds(seconds))
                NSApp.terminate(nil)
            }
        }
    }

    /// Closing the library (⌘W) leaves Prompter running, like any Mac app: sync keeps going, and so does a take being
    /// presented. A click on the Dock icon brings the library back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        return MainActor.assumeIsolated {
            guard let open = LibraryWindow.open else { return true }
            open()
            return false
        }
    }
}

/// Opens the library window from outside SwiftUI: a click on the Dock icon with no window open, or presenting ending
/// while the library is closed.
@MainActor
enum LibraryWindow {
    static let id = "library"
    /// Set once the library window has appeared (SwiftUI's `openWindow`, which works after that window has closed too).
    static var open: (() -> Void)?

    /// Brings the library to the front, opening it again if it was closed.
    static func show() {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(id) == true && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            open?()
        }
    }
}

/// Hands SwiftUI's `openWindow` for the library to `LibraryWindow`.
private struct LibraryWindowOpenerCapture: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .onAppear {
                let openWindow = openWindow
                LibraryWindow.open = { openWindow(id: LibraryWindow.id) }
            }
    }
}
