import Foundation
import Observation
import os
import WatchConnectivity

/// The watch's end of the remote: sends commands to the phone's `PrompterRemoteHub` and keeps the newest status.
///
/// Statuses arrive three ways (the reply to each command, the phone's live messages whenever what the watch shows
/// changes, and the application context for a watch app opened mid-take) and all go through one `StatusGate`, so a slow
/// reply can't overwrite a newer update. Each live message is acknowledged at once: the phone sends the next only then.
/// When the phone's pushes go quiet the watch asks for the status itself (`StatusPoll`): the phone's session can wrongly
/// believe the watch app isn't there and then refuses to push, but replies still get through.
/// A haptic plays when an accepted status changes the prompter's state (`RemoteHaptic`), once the watch is following
/// the phone live (`RemoteHapticGate`).
/// Privacy manifest: the Crown batching and the status poll read `ProcessInfo.systemUptime`, the SystemBootTime category
/// (reason 35F9.1) declared in `PrompterWatch/PrivacyInfo.xcprivacy`. Keep the two in step.
@MainActor @Observable
final class WatchRemote {
    /// The newest status from the phone, or nil before anything arrived.
    private(set) var status: PrompterStatus?
    private(set) var isReachable = false
    /// A command just failed to reach the phone. Cleared after a couple of seconds or by the next status.
    private(set) var showsSendFailure = false

    /// What the screen shows.
    var display: RemoteDisplayModel { RemoteDisplayModel(status: status, isReachable: isReachable) }

    static let sendFailureText = "Didn't reach iPhone"

    @ObservationIgnored private var gate = StatusGate()
    @ObservationIgnored private var hapticGate = RemoteHapticGate()
    @ObservationIgnored private var session: WCSession?
    /// WCSession only holds its delegate weakly.
    @ObservationIgnored private var delegate: WatchSessionDelegate?
    @ObservationIgnored private var isActivated = false
    @ObservationIgnored private let isDemo: Bool
    @ObservationIgnored private let playHaptic: @MainActor (RemoteHaptic) -> Void
    @ObservationIgnored private let playFailure: @MainActor () -> Void
    @ObservationIgnored private var crownSteps = StepCoalescer(interval: 0.1)
    @ObservationIgnored private var crownFlush: Task<Void, Never>?
    @ObservationIgnored private var failureReset: Task<Void, Never>?
    @ObservationIgnored private var scriptTask: Task<Void, Never>?
    @ObservationIgnored private var poll = StatusPoll()
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    /// How often the watch checks whether to ask for the status (`StatusPoll` decides).
    static let pollTick: Duration = .milliseconds(250)

    /// Talks to the phone once `activate()` is called.
    init(
        playHaptic: @escaping @MainActor (RemoteHaptic) -> Void = Haptics.play,
        playFailure: @escaping @MainActor () -> Void = Haptics.playFailure
    ) {
        isDemo = false
        self.playHaptic = playHaptic
        self.playFailure = playFailure
    }

    /// Shows a canned status and never touches the session (screenshots without a phone).
    init(demo: WatchLaunchOptions.DemoStatus) {
        isDemo = true
        playHaptic = { _ in }
        playFailure = {}
        isReachable = demo.isReachable
        if let status = demo.status {
            _ = gate.accept(status)
            self.status = status
        }
    }

    /// Starts the watch session (once). Does nothing in demo mode or where WatchConnectivity isn't supported.
    func activate() {
        guard !isDemo, delegate == nil, WCSession.isSupported() else { return }
        let session = WCSession.default
        let delegate = WatchSessionDelegate(events: WatchSessionEvents(
            stateChanged: { [weak self] state in self?.sessionChanged(state) },
            statusReceived: { [weak self] status, source in self?.receive(status, from: source) }
        ))
        self.session = session
        self.delegate = delegate
        session.delegate = delegate
        session.activate()
        remoteLog.notice("session activating")
        startPolling()
    }

    /// Sends a command; the phone replies with the fresh status. A failure plays a haptic and shows a short notice.
    func send(_ command: RemoteCommand) {
        guard !isDemo else {
            remoteLog.notice("demo: not sending \(String(describing: command), privacy: .public)")
            return
        }
        guard let session, isActivated else {
            remoteLog.error("not sent (session not active): \(String(describing: command), privacy: .public)")
            sendFailed()
            return
        }
        let isStatusRequest = command == .requestStatus
        if isStatusRequest {
            // Polls go out every second or so: keep them out of the persisted log.
            remoteLog.debug("send requestStatus")
        } else {
            remoteLog.notice("send \(String(describing: command), privacy: .public)")
        }
        if isStatusRequest { poll.requestSent(now: Self.uptime) }
        WatchSessionDelegate.send(
            command,
            on: session,
            replied: { [weak self] status in
                if isStatusRequest { self?.poll.requestEnded() }
                self?.receive(status, from: .reply)
            },
            failed: { [weak self] description in
                remoteLog.error("send failed: \(String(describing: command), privacy: .public): \(description, privacy: .public)")
                if isStatusRequest { self?.poll.requestEnded() }
                // A status request that fails (reachability flickering) isn't something the presenter pressed.
                if !isStatusRequest { self?.sendFailed() }
            }
        )
    }

    /// Digital Crown detents (±1 each): at most one `.speedStep` message per 0.1 s, carrying the summed steps.
    func stepSpeed(by steps: Int) {
        guard display.speedControlsEnabled else { return }
        switch crownSteps.add(steps, now: ProcessInfo.processInfo.systemUptime) {
        case .send(let total):
            send(.speedStep(total))
        case .flush(let delay):
            crownFlush = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self else { return }
                self.crownFlush = nil
                if let total = self.crownSteps.flush(now: ProcessInfo.processInfo.systemUptime) {
                    self.send(.speedStep(total))
                }
            }
        case .none:
            break
        }
    }

    /// Debug automation (`-remoteScript`): sends each step at its time after this call.
    func run(_ script: RemoteScript) {
        scriptTask?.cancel()
        let start = ContinuousClock.now
        remoteLog.notice("remote script: \(script.steps.count) steps")
        scriptTask = Task { [weak self] in
            for step in script.steps {
                try? await Task.sleep(until: start.advanced(by: .seconds(step.at)), clock: .continuous)
                guard !Task.isCancelled, let self else { return }
                remoteLog.notice("remote script step @\(step.at, privacy: .public)s")
                self.send(step.command)
            }
        }
    }

    // MARK: Private

    private func receive(_ status: PrompterStatus, from source: StatusSource) {
        // Even one the gate drops shows the phone's pushes are getting through.
        if source != .reply { poll.pushArrived(now: Self.uptime) }
        let previous = gate.latest
        let accepted = gate.accept(status)
        // Every status, for latency checks (scripts/watch-e2e.sh streams this log at debug level).
        remoteLog.debug("""
            got \(String(describing: source), privacy: .public) seq \(status.sequence, privacy: .public)\
            \(accepted ? "" : " (older, dropped)", privacy: .public)
            """)
        guard accepted else { return }
        self.status = status
        if showsSendFailure { clearSendFailure() }
        if previous?.state != status.state || previous?.hasPrompter != status.hasPrompter
            || previous?.isOnScreen != status.isOnScreen || previous?.deviceName != status.deviceName
            || previous?.note != status.note || previous?.speedLabel != status.speedLabel {
            remoteLog.notice("""
                status \(status.hasPrompter ? String(describing: status.state) : "no prompter", privacy: .public)\
                \(status.isOnScreen == false ? " (off screen)" : "", privacy: .public)\
                \(status.deviceName.map { " on \($0)" } ?? "", privacy: .public)\
                \(status.note.map { " [\($0.rawValue)]" } ?? "", privacy: .public) \
                \(status.speedLabel, privacy: .public) seq \(status.sequence, privacy: .public) \
                (\(String(describing: source), privacy: .public))
                """)
        }
        if let haptic = hapticGate.haptic(from: previous, to: status, isLive: source != .context) {
            remoteLog.notice("haptic \(String(describing: haptic), privacy: .public)")
            playHaptic(haptic)
        }
    }

    private func sessionChanged(_ state: WatchSessionState) {
        let wasReachable = isReachable
        isActivated = state.isActivated
        if isReachable != state.isReachable {
            isReachable = state.isReachable
            remoteLog.notice("reachable: \(state.isReachable, privacy: .public)")
        }
        // Out of reach: what arrives after reconnecting is catching up, not something to buzz about.
        if !state.isReachable { hapticGate.disarm() }
        if let context = state.context { receive(context, from: .context) }
        // Fresh numbers the moment the phone is back, instead of waiting for its next live update.
        if state.isReachable, !wasReachable { send(.requestStatus) }
    }

    /// Checks every `pollTick` whether the phone's pushes went quiet, and if so asks for the status (`StatusPoll`).
    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollTick)
                // Only strong for this tick, so the loop never keeps the remote alive.
                guard !Task.isCancelled, let self else { return }
                self.pollIfQuiet()
            }
        }
    }

    private func pollIfQuiet() {
        guard poll.shouldRequest(now: Self.uptime, isReachable: isActivated && isReachable, latest: gate.latest)
        else { return }
        remoteLog.debug("no update from iPhone lately: asking")
        send(.requestStatus)
    }

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func sendFailed() {
        playFailure()
        showsSendFailure = true
        failureReset?.cancel()
        failureReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.clearSendFailure()
        }
    }

    private func clearSendFailure() {
        failureReset?.cancel()
        failureReset = nil
        showsSendFailure = false
    }
}

let remoteLog = Logger(subsystem: LogSubsystem.current, category: "remote")

// MARK: - Session delegate

/// The session as the watch sees it, plus the application context read with it (activation only).
struct WatchSessionState: Equatable, Sendable {
    var isActivated = false
    var isReachable = false
    /// The phone's last application context, when this report comes from activation.
    var context: PrompterStatus?
}

/// How a status reached the watch.
enum StatusSource: Sendable {
    /// The reply to one of the watch's commands.
    case reply
    /// The phone's push whenever what the watch shows changes, while the prompter is open and the watch is reachable.
    case live
    /// The application context: the phone's last state change, possibly from a while ago.
    case context
}

/// How the delegate reports to `WatchRemote`, always on the main actor.
struct WatchSessionEvents: Sendable {
    var stateChanged: @MainActor @Sendable (WatchSessionState) -> Void
    var statusReceived: @MainActor @Sendable (PrompterStatus, StatusSource) -> Void
}

/// WCSession's delegate. Callbacks arrive on a WatchConnectivity background queue: each turns the session and message
/// into Sendable values right there, then hands them to the main actor through the main queue, in arrival order.
nonisolated final class WatchSessionDelegate: NSObject, WCSessionDelegate, Sendable {
    private let events: WatchSessionEvents

    init(events: WatchSessionEvents) {
        self.events = events
    }

    /// Sends `command` with a reply handler. Lives here, outside the main actor, so the reply and error closures are
    /// plain `@Sendable` closures: written inside `@MainActor` code they would be inferred main-actor isolated, and
    /// Swift 6 traps when WCSession calls them on its background queue.
    static func send(
        _ command: RemoteCommand,
        on session: WCSession,
        replied: @escaping @MainActor @Sendable (PrompterStatus) -> Void,
        failed: @escaping @MainActor @Sendable (String) -> Void
    ) {
        session.sendMessage(
            RemoteMessageCoder.message(for: command),
            replyHandler: { @Sendable reply in
                // An unreadable reply (a newer phone app) is ignored; the next live update replaces it.
                guard let status = RemoteMessageCoder.status(from: reply) else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { replied(status) }
                }
            },
            errorHandler: { @Sendable error in
                let description = error.localizedDescription
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { failed(description) }
                }
            }
        )
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        // The phone's last application context, so a watch opened mid-take shows the take at once.
        let context = RemoteMessageCoder.status(from: session.receivedApplicationContext)
        report(session, context: context)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        report(session, context: nil)
    }

    func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        report(session, context: nil)
    }

    /// Live status without a reply handler (phone builds before the one-in-flight change sent them this way).
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        deliver(RemoteMessageCoder.status(from: message), from: .live)
    }

    /// Live status. The phone keeps one live message in flight and sends the next (the newest status) when this one is
    /// acknowledged, so acknowledge at once, right here on WatchConnectivity's queue.
    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        replyHandler(RemoteMessageCoder.ack)
        deliver(RemoteMessageCoder.status(from: message), from: .live)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        deliver(RemoteMessageCoder.status(from: applicationContext), from: .context)
    }

    private func deliver(_ status: PrompterStatus?, from source: StatusSource) {
        guard let status else { return }
        let received = events.statusReceived
        DispatchQueue.main.async {
            MainActor.assumeIsolated { received(status, source) }
        }
    }

    private func report(_ session: WCSession, context: PrompterStatus?) {
        let isActivated = session.activationState == .activated
        let state = WatchSessionState(
            isActivated: isActivated,
            isReachable: isActivated && session.isReachable,
            context: context
        )
        let changed = events.stateChanged
        DispatchQueue.main.async {
            MainActor.assumeIsolated { changed(state) }
        }
    }
}
