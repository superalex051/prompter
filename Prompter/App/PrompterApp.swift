import AppIntents
import Network
import SwiftUI

@main
struct PrompterApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let launchOptions: LaunchOptions
    @State private var scriptStore: ScriptStore
    @State private var settingsStore: SettingsStore
    @State private var remoteHub: PrompterRemoteHub
    @State private var syncClient: SyncClient
    @Environment(\.scenePhase) private var scenePhase
    /// Hosting the unit tests: no sync (the tests make their own).
    private let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// The settings suite `-demoData` uses instead of the real settings. Emptied at every demo launch.
    static let demoSettingsSuite = "PrompterDemo"

    init() {
        let options = LaunchOptions()
        launchOptions = options
        let store: ScriptStore
        let pairingStore: PairingStore
        if options.demoData {
            // Screenshots: a throwaway library, throwaway settings and throwaway pairings, so the real ones are never
            // touched.
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "PrompterDemo-\(UUID().uuidString)", directoryHint: .isDirectory)
            store = ScriptStore(
                directory: directory,
                initialScripts: { DemoData.scripts(now: $0, includeMarkdown: options.script == .markdown) }
            )
            pairingStore = PairingStore(directory: directory)
            // UserDefaults only rejects a suite named like the app's bundle ID or NSGlobalDomain, so this never fails.
            let demoDefaults = UserDefaults(suiteName: Self.demoSettingsSuite)!
            demoDefaults.removePersistentDomain(forName: Self.demoSettingsSuite)
            let demoSettings = SettingsStore(defaults: demoDefaults)
            if let mode = options.scrollMode { demoSettings.settings.scrollMode = mode }
            _settingsStore = State(initialValue: demoSettings)
            OrientationLock.sideDefaults = demoDefaults
        } else {
            store = ScriptStore()
            pairingStore = PairingStore(keyVault: KeychainPairingKeyVault())
            _settingsStore = State(initialValue: SettingsStore())
        }
        _scriptStore = State(initialValue: store)
        // Mac ⇄ iPhone sync. It runs only while the app is in the foreground (see `body`).
        let sync = SyncLaunchOptions()
        let client = SyncClient(
            library: store,
            pairing: pairingStore,
            name: options.demoData ? DemoData.phoneName : UIDevice.current.name,
            platform: UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone,
            isDemo: options.demoData
        )
        if let host = sync.host, let port = sync.hostPort, let nwPort = NWEndpoint.Port(rawValue: port) {
            client.directEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        }
        // A debug code pairs with any Mac that knows it, so only a throwaway demo library ever uses one.
        client.autoPairCode = options.demoData ? sync.pairingCode : nil
        if sync.demo {
            var didRun = false
            client.onConnected = {
                guard !didRun else { return }
                didRun = true
                Task { @MainActor in await SyncDemo.runOnPhone(store: store) }
            }
        }
        store.onLocalChange = { [weak client] in client?.libraryChanged() }
        _syncClient = State(initialValue: client)
        // Activated at launch: a watch command can launch the app in the background.
        let hub = PrompterRemoteHub(link: options.noWatchPush ? WatchSessionLink(refusesPushes: true) : nil)
        // The Apple Watch controls Prompter for Mac through this iPhone while no prompter is open here (M9).
        hub.connectMac(client)
        // A watch command can launch the app straight into the background, where the Mac can't be reached.
        hub.appActivityChanged(UIApplication.shared.applicationState != .background)
        hub.activate()
        // Siri, Shortcuts and the Action button reach the prompter through this same hub (see PrompterIntents.swift).
        // Registered here, before any intent can run: the system builds the app first, then performs the intent.
        AppDependencyManager.shared.add(dependency: hub)
        _remoteHub = State(initialValue: hub)
    }

    var body: some Scene {
        WindowGroup {
            LibraryView(launchRoute: LaunchRoute(
                route: launchOptions.route,
                script: launchOptions.script,
                autoStart: launchOptions.autoStart
            ))
                .environment(scriptStore)
                .environment(settingsStore)
                .environment(remoteHub)
                .environment(syncClient)
                .preferredColorScheme(.dark)
                .duoProbe(launchOptions.duoProbe)
        }
        .commands { LibraryCommands() }
        // Sync runs in the foreground only: it connects when the app becomes active and disconnects cleanly when it goes
        // to the background (a brief "inactive", like pulling down Control Center, changes nothing).
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard !isRunningTests else { return }
            switch phase {
            case .active:
                syncClient.setActive(true)
                remoteHub.appActivityChanged(true)
            case .background:
                syncClient.setActive(false)
                remoteHub.appActivityChanged(false)
            default: break
            }
        }
    }
}
