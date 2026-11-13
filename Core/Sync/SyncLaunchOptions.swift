import Foundation

/// Debug launch arguments for sync checks, read the same way on the Mac and the iPhone (see `LaunchArguments`).
///
/// - `-syncPairingCode 123456789012`: pair with no UI. The Mac keeps that code open all the time; the iPhone pairs with the first
///   Mac it finds (with `-demoData`, only a Mac that also runs with `-demoData`).
/// - `-syncDemo`: once connected, the Mac creates a script, edits it and deletes it on a timer; the iPhone creates one.
/// - `-syncPort 50123` (Mac): listen on that port instead of any free one, without advertising over Bonjour (the direct
///   mode for checks: Bonjour is what needs macOS's Local Network permission, and loopback connections don't).
/// - `-syncHost 127.0.0.1:50123` (iPhone): connect there instead of looking the Mac up with Bonjour.
struct SyncLaunchOptions: Equatable, Sendable {
    var pairingCode: String?
    var demo = false
    var port: UInt16?
    var host: String?
    var hostPort: UInt16?

    init(arguments: [String] = LaunchArguments.process) {
        if let value = LaunchArguments.value(after: "syncPairingCode", in: arguments) {
            pairingCode = SyncPairing.normalizedCode(value)
        }
        demo = LaunchArguments.flag("syncDemo", in: arguments)
        if let value = LaunchArguments.value(after: "syncPort", in: arguments) {
            port = UInt16(value)
        }
        if let value = LaunchArguments.value(after: "syncHost", in: arguments),
           let colon = value.lastIndex(of: ":"), let port = UInt16(value[value.index(after: colon)...]) {
            host = String(value[..<colon])
            hostPort = port
        }
    }
}

/// `-syncDemo`: scripted changes for end-to-end checks of sync, each one logged (category "sync") with its time.
@MainActor
enum SyncDemo {
    static let macTitle = "Sync demo from the Mac"
    static let phoneTitle = "Sync demo from the iPhone"

    /// The Mac: 3 s after the first iPhone connects, creates a script; 12 s later edits it; 12 s after that deletes it.
    static func runOnMac(store: ScriptStore, isConnected: @escaping @MainActor () -> Bool) async {
        while !isConnected() {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
        }
        try? await Task.sleep(for: .seconds(3))
        let script = store.create(
            title: macTitle,
            body: "Written on the Mac. If you can read this on the iPhone, sync works.\n\nLook into the lens and smile."
        )
        log("created", script.id)
        try? await Task.sleep(for: .seconds(12))
        store.update(script.id, body: "Edited on the Mac. This new text should replace the old one on the iPhone.")
        log("edited", script.id)
        try? await Task.sleep(for: .seconds(12))
        store.delete(script.id)
        log("deleted", script.id)
    }

    /// The iPhone: 3 s after it first connects, creates a script.
    static func runOnPhone(store: ScriptStore) async {
        try? await Task.sleep(for: .seconds(3))
        let script = store.create(title: phoneTitle, body: "Written on the iPhone. It should show up in the Mac's library.")
        log("created", script.id)
    }

    private static func log(_ action: String, _ id: UUID) {
        let time = Date.now.timeIntervalSince1970
        syncLog.notice("syncDemo \(action, privacy: .public) \(id.uuidString, privacy: .public) at \(time, format: .fixed(precision: 3), privacy: .public)")
    }
}
