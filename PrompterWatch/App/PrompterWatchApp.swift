import SwiftUI

@main
struct PrompterWatchApp: App {
    @State private var remote: WatchRemote

    init() {
        let options = WatchLaunchOptions()
        let remote: WatchRemote
        if let demo = options.demoStatus {
            // Screenshots: a canned status, no phone needed.
            remote = WatchRemote(demo: demo)
        } else {
            remote = WatchRemote()
            remote.activate()
        }
        if let script = options.remoteScript {
            remote.run(script)
        }
        _remote = State(initialValue: remote)
    }

    var body: some Scene {
        WindowGroup {
            RemoteView(remote: remote)
        }
    }
}
