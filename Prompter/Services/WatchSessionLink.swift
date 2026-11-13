import Foundation
import os
import WatchConnectivity

/// The real `RemoteSessionLink`: `WCSession.default` on the phone.
@MainActor
final class WatchSessionLink: RemoteSessionLink {
    private let session: WCSession
    /// WCSession only holds its delegate weakly.
    private var delegate: PhoneSessionDelegate?
    /// `-noWatchPush` (testing): behave as WCSession does when it wrongly believes the watch app isn't installed.
    private let refusesPushes: Bool

    /// nil where WatchConnectivity isn't supported (iPad). `refusesPushes`: never send a live message or an application
    /// context, only reply to the watch (see `LaunchOptions.noWatchPush`).
    init?(refusesPushes: Bool = false) {
        guard WCSession.isSupported() else { return nil }
        session = .default
        self.refusesPushes = refusesPushes
        if refusesPushes { remoteLog.notice("-noWatchPush: only replies reach the watch") }
    }

    func activate(events: RemoteSessionEvents) {
        guard delegate == nil else { return }
        let delegate = PhoneSessionDelegate(events: events)
        self.delegate = delegate
        session.delegate = delegate
        session.activate()
    }

    func send(_ status: PrompterStatus, ended: @escaping @MainActor @Sendable (_ delivered: Bool) -> Void) {
        guard !refusesPushes else {
            remoteLog.debug("live not sent (-noWatchPush): \(status.logDescription, privacy: .public)")
            ended(false)
            return
        }
        let session = session
        guard session.activationState == .activated, session.isReachable else {
            remoteLog.debug("""
                live not sent (activation \(session.activationState.rawValue, privacy: .public), \
                reachable \(session.isReachable, privacy: .public)): \(status.logDescription, privacy: .public)
                """)
            ended(false)
            return
        }
        remoteLog.debug("live \(status.logDescription, privacy: .public)")
        PhoneSessionDelegate.send(
            RemoteMessageCoder.message(for: status), on: session, sequence: status.sequence, ended: ended
        )
    }

    func updateContext(_ status: PrompterStatus) {
        guard !refusesPushes else {
            remoteLog.info("context not sent (-noWatchPush): \(status.logDescription, privacy: .public)")
            return
        }
        let session = session
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else {
            remoteLog.info("""
                context not sent (activation \(session.activationState.rawValue, privacy: .public), \
                paired \(session.isPaired, privacy: .public), \
                watch app installed \(session.isWatchAppInstalled, privacy: .public)): \
                \(status.logDescription, privacy: .public)
                """)
            return
        }
        do {
            try session.updateApplicationContext(RemoteMessageCoder.message(for: status))
            remoteLog.info("context \(status.logDescription, privacy: .public)")
        } catch {
            remoteLog.error("""
                context failed: \(error.localizedDescription, privacy: .public): \(status.logDescription, privacy: .public)
                """)
        }
    }
}

/// WCSession's delegate. Callbacks arrive on a WatchConnectivity background queue: each turns the session and message
/// into Sendable values right there, then hands them to the main actor through the main queue, in arrival order.
nonisolated final class PhoneSessionDelegate: NSObject, WCSessionDelegate, Sendable {
    private let events: RemoteSessionEvents

    init(events: RemoteSessionEvents) {
        self.events = events
    }

    /// Sends a live status with a reply handler: the watch acknowledges it, and `ended` (on the main actor) lets the hub
    /// send the next one. Lives here, outside the main actor, so the reply and error closures are plain `@Sendable`
    /// closures: written inside `@MainActor` code they would be inferred main-actor isolated, and Swift 6 traps when
    /// WCSession calls them on its background queue.
    static func send(
        _ message: [String: Any],
        on session: WCSession,
        sequence: UInt64,
        ended: @escaping @MainActor @Sendable (_ delivered: Bool) -> Void
    ) {
        session.sendMessage(
            message,
            replyHandler: { @Sendable _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { ended(true) }
                }
            },
            errorHandler: { @Sendable error in
                // Not retried: the hub sends the newest status next, if anything changed.
                remoteLog.error(
                    "live failed: seq \(sequence, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { ended(false) }
                }
            }
        )
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        if let error {
            remoteLog.error("activation failed: \(error.localizedDescription, privacy: .public)")
        }
        report(session, event: "activated")
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        report(session, event: "inactive")
    }

    func sessionDidDeactivate(_ session: WCSession) {
        // The user switched to another watch: start a session with that one.
        session.activate()
        report(session, event: "deactivated")
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        report(session, event: "watch state changed")
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        report(session, event: "reachability changed")
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let command = RemoteMessageCoder.command(from: message) else {
            remoteLog.error("unreadable message (no reply handler)")
            return
        }
        let received = events.commandReceived
        DispatchQueue.main.async {
            MainActor.assumeIsolated { received(command) { _ in } }
        }
    }

    /// Replies with the status after the command (the current status if the message couldn't be read). Commands reach
    /// the hub in arrival order, through the main queue; the reply goes once the hub has it (later for the Mac).
    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let command = RemoteMessageCoder.command(from: message)
        let reply = Reply(replyHandler)
        let received = events.commandReceived
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                received(command) { status in reply.send(RemoteMessageCoder.message(for: status)) }
            }
        }
    }

    private func report(_ session: WCSession, event: StaticString) {
        // Pairing and reachability are only meaningful once the session is activated.
        let isActivated = session.activationState == .activated
        let state = RemoteSessionState(
            isActivated: isActivated,
            isReachable: isActivated && session.isReachable,
            isPaired: isActivated && session.isPaired,
            isWatchAppInstalled: isActivated && session.isWatchAppInstalled
        )
        remoteLog.info("""
            session \(event, privacy: .public): activation \(session.activationState.rawValue, privacy: .public), \
            reachable \(session.isReachable, privacy: .public), paired \(session.isPaired, privacy: .public), \
            watch app installed \(session.isWatchAppInstalled, privacy: .public)
            """)
        let changed = events.stateChanged
        DispatchQueue.main.async {
            MainActor.assumeIsolated { changed(state) }
        }
    }
}

/// WCSession's reply block, which the SDK doesn't mark Sendable. WCSession accepts the reply on any thread, and the
/// hub calls it exactly once (on the main actor, with a dictionary built there), so carrying it across is safe.
private struct Reply: @unchecked Sendable {
    private let handler: ([String: Any]) -> Void

    init(_ handler: @escaping ([String: Any]) -> Void) {
        self.handler = handler
    }

    func send(_ message: [String: Any]) {
        handler(message)
    }
}
