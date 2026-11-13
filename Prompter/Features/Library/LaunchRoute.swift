import Foundation

/// Where to land on launch (`-route editor`, `prompter`, `prompterSettings`, `settings`, `syncSettings` or `macRemote`,
/// see `LaunchOptions`), applied once, as soon as the library and the settings have loaded.
///
/// The stores can start out waiting for the first unlock after a restart (`ScriptStore.isWaitingForProtectedData`), with
/// an empty library. Applying the route on the library's first appearance then found no script and gave up, so a
/// `-route prompter` launch stayed in the library. Here the route is only used up by a call made after loading finished.
struct LaunchRoute: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        /// The app settings sheet (needs no script).
        case openSettings
        case openEditor(Script.ID)
        case openPrompter(Script.ID, autoStart: Bool)
        /// The prompter with its settings sheet open (screenshots).
        case openPrompterSettings(Script.ID)
        /// The app settings sheet, on Sync with Mac.
        case openSyncSettings
        /// The Remote for Mac screen (needs no script).
        case openMacRemote
    }

    var route: LaunchOptions.Route = .library
    /// Which script the editor and prompter routes open.
    var script: LaunchOptions.ScriptChoice = .newest
    /// With the `.prompter` route: start the countdown right away.
    var autoStart = false
    /// The route was applied (or there was nothing to open); later calls return nil.
    private(set) var isDone = false

    /// What to open now. nil while `isLoading` (call again once it is false), and from the first call after loading on,
    /// which uses the route up whether or not there was a script to open. `scripts` is the library, newest first.
    mutating func next(isLoading: Bool, scripts: [Script]) -> Action? {
        guard !isDone, !isLoading else { return nil }
        isDone = true
        let chosen: Script? = switch script {
        case .newest: nil
        case .sample: scripts.first { $0.id == SampleScript.id }
        case .markdown: scripts.first { $0.id == DemoData.markdownScriptID }
        }
        let target = chosen ?? scripts.first
        switch route {
        case .library:
            return nil
        case .settings:
            return .openSettings
        case .syncSettings:
            return .openSyncSettings
        case .macRemote:
            return .openMacRemote
        case .editor:
            return target.map { .openEditor($0.id) }
        case .prompter:
            return target.map { .openPrompter($0.id, autoStart: autoStart) }
        case .prompterSettings:
            return target.map { .openPrompterSettings($0.id) }
        }
    }
}
