import Foundation
import Observation
import os

/// The phone's end of the Apple Watch remote: applies watch commands to the open prompter and keeps the watch up to date.
///
/// `PrompterScreen` attaches its engine while the prompter is on screen. Commands arrive through the session link and
/// are answered with a fresh status. While an engine is attached, a main-actor loop samples the status every 0.25 s.
/// A reachable watch gets a live message only when what it shows changed (`LivePushGate`: state, title, speed, prompter
/// and on-screen flags, whole seconds left, progress by half a percent), with at most one message in flight: the next
/// waits for the watch's acknowledgement, and only the newest waits. Idle or paused, nothing goes out. The application
/// context is refreshed whenever the state, title, speed or prompter flags change, so a watch app opened later starts
/// from the current state. Every status gets a fresh sequence number from a `SequenceClock`.
///
/// Commands that would set the text going (start, resume, toggling from idle, paused or finished) are refused while the
/// prompter isn't on screen (`isPrompterOnScreen`: the app is in the background or the phone is locked): nothing would
/// draw the countdown, and "go" would fire unseen on the way back. Pausing, steps and speed changes still apply. The
/// status says so (`PrompterStatus.isOnScreen == false`) and the watch asks for the phone to be opened.
///
/// Prompter for Mac (M9): with no prompter open here, a paired Mac that is connected and presenting takes the watch's
/// commands instead (`RemoteTarget`): they are forwarded over the sync connection (`MacRemoteRelay`) and the watch's
/// reply waits for the Mac's answer. The Mac pushes its status as it changes; each one is re-stamped with this phone's
/// sequence clock and goes to the watch through the same live gate and application context, marked with the Mac's name.
///
/// Holds the engine weakly and observes it only by sampling; it never sets `engine.onEvent` (the screen owns that).
@MainActor @Observable
final class PrompterRemoteHub {
    /// How often the hub looks at the engine while a prompter is attached. Looking is cheap; only changes are sent.
    nonisolated static let defaultSampleInterval: Duration = .milliseconds(250)
    /// A live message neither acknowledged nor failed after this long counts as lost, so the next one may go.
    nonisolated static let defaultAckTimeout: Duration = .seconds(3)

    private(set) var isReachable = false
    private(set) var isPaired = false
    private(set) var isWatchAppInstalled = false
    /// The prompter's scene isn't in the background (the screen reports it with `prompterVisibilityChanged(_:)`). True
    /// until told otherwise; meaningless while no prompter is attached.
    private(set) var isPrompterOnScreen = true
    /// The app isn't in the background (the app reports it with `appActivityChanged(_:)`). In the background the sync
    /// connection to the Mac is closed, so the watch can't reach the Mac through this iPhone.
    private(set) var isAppActive = true

    @ObservationIgnored private var link: (any RemoteSessionLink)?
    /// The paired Mac (`connectMac(_:)`), for the watch to control while it presents.
    @ObservationIgnored private var macRelay: (any MacRemoteRelay)?
    @ObservationIgnored private let sampleInterval: Duration?
    @ObservationIgnored private let ackTimeout: Duration
    @ObservationIgnored private var hasActivated = false
    @ObservationIgnored private var sessionState = RemoteSessionState()
    @ObservationIgnored private weak var engine: ScrollEngine?
    @ObservationIgnored private var scriptTitle = ""
    @ObservationIgnored private var sequenceClock = SequenceClock()
    /// What the application context last carried, to push it again only when that changes.
    @ObservationIgnored private var lastContext: ContextKey?
    @ObservationIgnored private var sampleTask: Task<Void, Never>?
    /// What goes out live, and when (one message in flight, newest waiting).
    @ObservationIgnored private var liveGate = LivePushGate()
    /// Gives up on the message in flight after `ackTimeout`.
    @ObservationIgnored private var ackTimeoutTask: Task<Void, Never>?
    /// Intents waiting for the prompter to come on screen (`waitUntilPrompterOnScreen(timeout:)`), by ticket.
    @ObservationIgnored private var visibilityWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var nextWaiterTicket = 0

    /// Doesn't touch the session until `activate()`. `link` nil: `activate()` uses `WCSession.default` if supported.
    /// `sampleInterval` nil turns the sampling loop off (tests call `publishStatus()` themselves).
    init(
        link: (any RemoteSessionLink)? = nil,
        sampleInterval: Duration? = defaultSampleInterval,
        ackTimeout: Duration = defaultAckTimeout
    ) {
        self.link = link
        self.sampleInterval = sampleInterval
        self.ackTimeout = ackTimeout
    }

    /// Starts the watch session (once). Call at launch: the watch can launch the app in the background with a command.
    func activate() {
        guard !hasActivated else { return }
        hasActivated = true
        if link == nil { link = WatchSessionLink() }
        remoteLog.info("\(self.link == nil ? "no WatchConnectivity here" : "session activating", privacy: .public)")
        link?.activate(events: RemoteSessionEvents(
            stateChanged: { [weak self] state in self?.sessionChanged(state) },
            commandReceived: { [weak self] command, reply in
                guard let self else {
                    reply(.noPrompter)
                    return
                }
                self.receiveFromWatch(command ?? .requestStatus, reply: reply)
            }
        ))
    }

    /// The paired Mac: while no prompter is open here and it presents, the watch controls it through this iPhone.
    func connectMac(_ relay: any MacRemoteRelay) {
        macRelay = relay
        relay.onMacStatusChange = { [weak self] in self?.macStatusChanged() }
    }

    /// The app went to the background (false) or came back (true). Tells the watch at once: without the app in the
    /// foreground the Mac can't be reached from the watch.
    func appActivityChanged(_ isActive: Bool) {
        guard isActive != isAppActive else { return }
        isAppActive = isActive
        remoteLog.info("app \(isActive ? "active" : "in the background", privacy: .public)")
        publishStatus()
    }

    /// Who the watch controls right now (see `RemoteTarget`).
    var target: RemoteTarget {
        RemoteTarget.choose(
            hasPhonePrompter: engine != nil,
            macStatus: macRelay?.macPresenterStatus,
            isMacPaired: macRelay?.isMacPaired ?? false,
            isAppActive: isAppActive
        )
    }

    /// A command from the watch. The iPhone's own prompter (or nothing) answers at once through `handle(_:)`; the Mac's
    /// prompter answers once the Mac has (`reply` then runs later, at most `SyncClient.remoteReplyTimeout` on).
    func receiveFromWatch(_ command: RemoteCommand, reply: @escaping @MainActor (PrompterStatus) -> Void) {
        guard case .mac = target, let macRelay, command != .requestStatus else {
            // A status request needs no round trip to the Mac: it pushes every change, so the status here is current.
            reply(handle(command))
            return
        }
        let sentAt = ContinuousClock.now
        remoteLog.info("""
            forward \(String(describing: command), privacy: .public) to the Mac at \
            \(Date.now.timeIntervalSince1970, format: .fixed(precision: 3), privacy: .public)
            """)
        macRelay.forward(command) { [weak self] answer in
            guard let self else { return }
            let status = self.makeStatus()
            let waited = ContinuousClock.now - sentAt
            remoteLog.info("""
                Mac \(answer == nil ? "didn't answer" : "answered", privacy: .public) \
                \(String(describing: command), privacy: .public) after \(waited, privacy: .public): \
                \(status.logDescription, privacy: .public)
                """)
            self.updateContextIfChanged(status)
            reply(status)
        }
    }

    /// The prompter is on screen: commands go to `engine` and the watch hears about it.
    func attach(engine: ScrollEngine, scriptTitle: String) {
        self.engine = engine
        self.scriptTitle = scriptTitle
        remoteLog.info("attach (watch reachable: \(self.sessionState.isReachable, privacy: .public))")
        publish(makeStatus(), forceContext: true)
        startSampling()
    }

    /// The prompter closed: tells the watch there is no prompter. Ignored if another engine was attached since.
    func detach(engine: ScrollEngine) {
        guard engine === self.engine else {
            remoteLog.info("detach ignored: another prompter is attached")
            return
        }
        remoteLog.info("detach")
        self.engine = nil
        scriptTitle = ""
        stopSampling()
        publish(makeStatus(), forceContext: true)
    }

    /// The prompter's scene went to the background (false) or came back (true): records it, lets intents waiting for
    /// the prompter go ahead, and tells the watch at once (the sampling loop may not tick again before the app is
    /// suspended): live if no message is in flight (else as soon as it is acknowledged), and in the application context.
    func prompterVisibilityChanged(_ isOnScreen: Bool) {
        if isOnScreen != isPrompterOnScreen {
            isPrompterOnScreen = isOnScreen
            remoteLog.info("prompter \(isOnScreen ? "on screen" : "off screen", privacy: .public)")
        }
        if isOnScreen { resumeVisibilityWaiters() }
        publishStatus()
    }

    /// Returns once the prompter is on screen, or after `timeout`. Returns at once when it already is, or when there is no
    /// prompter (nothing to wait for). An intent that brings the app to the foreground calls this first, so its start
    /// lands on a visible prompter instead of being refused while the scene is still coming back.
    func waitUntilPrompterOnScreen(timeout: Duration) async {
        guard engine != nil, !isPrompterOnScreen else { return }
        let ticket = nextWaiterTicket
        nextWaiterTicket += 1
        remoteLog.info("waiting for the prompter to come on screen")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            visibilityWaiters[ticket] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.visibilityWaiters.removeValue(forKey: ticket)?.resume()
            }
        }
    }

    /// Applies a command to the iPhone's own prompter and returns the fresh status (the watch's reply; intents read it
    /// too). Without a prompter here nothing happens and the status says `hasPrompter == false` (or, while the watch
    /// controls the Mac, describes the Mac: `deviceName` is set). While the prompter isn't on screen, commands that would
    /// set the text going are refused (see the type's notes) and the status says `isOnScreen == false`.
    func handle(_ command: RemoteCommand) -> PrompterStatus {
        if let engine, !isPrompterOnScreen, RemoteCommandRouter.needsScreen(command, from: engine.state) {
            remoteLog.info("command \(String(describing: command), privacy: .public) refused: the prompter isn't on screen")
        } else {
            RemoteCommandRouter.apply(command, to: engine)
        }
        let status = makeStatus()
        remoteLog.info("command \(String(describing: command), privacy: .public): \(status.logDescription, privacy: .public)")
        updateContextIfChanged(status)
        return status
    }

    /// One tick of the sampling loop: the live status to a reachable watch if what it shows changed (`LivePushGate`),
    /// and the application context if the state, title, speed or prompter flags changed. Stops the loop if the engine
    /// went away without `detach`.
    func publishStatus() {
        publish(makeStatus(), forceContext: false)
        if engine == nil {
            scriptTitle = ""
            stopSampling()
        }
    }

    // MARK: Private

    /// What the application context follows: everything the watch shows except the numbers that move every tick (the
    /// device and the note too).
    private struct ContextKey: Equatable {
        var hasPrompter: Bool
        var scriptTitle: String
        var state: PlaybackState
        var speedLabel: String
        var isOnScreen: Bool?
        var deviceName: String?
        var note: RemoteNote?

        init(_ status: PrompterStatus) {
            hasPrompter = status.hasPrompter
            scriptTitle = status.scriptTitle
            state = status.state
            speedLabel = status.speedLabel
            isOnScreen = status.isOnScreen
            deviceName = status.deviceName
            note = status.note
        }
    }

    /// The status for the watch: the iPhone's prompter, the Mac's (re-stamped with this phone's clock, so the watch's
    /// `StatusGate` orders it with everything else), or no prompter with a note.
    private func makeStatus() -> PrompterStatus {
        switch target {
        case .phone:
            return RemoteCommandRouter.status(
                engine: engine, scriptTitle: scriptTitle, sequence: sequenceClock.next(), isOnScreen: isPrompterOnScreen
            )
        case .mac(let macStatus):
            var status = macStatus
            status.sequence = sequenceClock.next()
            // The Mac's prompter is on screen whenever it presents.
            status.isOnScreen = nil
            status.note = nil
            if status.deviceName?.isEmpty ?? true { status.deviceName = "Mac" }
            return status
        case .none(let note):
            var status = PrompterStatus.noPrompter
            status.sequence = sequenceClock.next()
            status.note = note
            return status
        }
    }

    /// The Mac's status changed (or the connection to it came or went). With a prompter open here that changes nothing
    /// the watch shows; otherwise it goes to the watch like any change (live if it shows differently, and the context).
    private func macStatusChanged() {
        guard engine == nil else { return }
        publish(makeStatus(), forceContext: false)
    }

    private func resumeVisibilityWaiters() {
        guard !visibilityWaiters.isEmpty else { return }
        let waiters = Array(visibilityWaiters.values)
        visibilityWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func publish(_ status: PrompterStatus, forceContext: Bool) {
        if sessionState.isReachable { pushLive(status) }
        if forceContext {
            pushContext(status)
        } else {
            updateContextIfChanged(status)
        }
    }

    private func updateContextIfChanged(_ status: PrompterStatus) {
        guard ContextKey(status) != lastContext else { return }
        pushContext(status)
    }

    private func pushContext(_ status: PrompterStatus) {
        lastContext = ContextKey(status)
        link?.updateContext(status)
    }

    /// Offers the status to the live gate and sends it if the gate says so.
    private func pushLive(_ status: PrompterStatus) {
        if let next = liveGate.offer(status) { sendLive(next) }
    }

    /// Sends a status the gate put in flight; its acknowledgement, failure or timeout lets the next one go.
    private func sendLive(_ status: PrompterStatus) {
        let sequence = status.sequence
        guard let link else {
            liveGate.reset()
            return
        }
        ackTimeoutTask?.cancel()
        let timeout = ackTimeout
        ackTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.liveGate.inFlight == sequence else { return }
            remoteLog.info("live seq \(sequence, privacy: .public) unanswered after \(timeout, privacy: .public): next")
            self.liveEnded(sequence)
        }
        // May call back at once (not sent): the gate already holds this message as in flight, so that is safe.
        link.send(status) { [weak self] delivered in
            let outcome = delivered ? "acknowledged" : "not delivered"
            remoteLog.debug("live \(outcome, privacy: .public) seq \(sequence, privacy: .public)")
            self?.liveEnded(sequence)
        }
    }

    /// The live message `sequence` was acknowledged, failed or timed out: the waiting status (if any) goes out now.
    private func liveEnded(_ sequence: UInt64) {
        guard liveGate.inFlight == sequence else { return }   // one given up on earlier: its successor already went
        ackTimeoutTask?.cancel()
        ackTimeoutTask = nil
        guard sessionState.isReachable else {
            liveGate.reset()
            return
        }
        if let next = liveGate.ended(sequence: sequence) { sendLive(next) }
    }

    private func sessionChanged(_ state: RemoteSessionState) {
        let old = sessionState
        sessionState = state
        if state != old {
            remoteLog.info("""
                hub session: activated \(state.isActivated, privacy: .public), reachable \(state.isReachable, privacy: .public), \
                paired \(state.isPaired, privacy: .public), watch app installed \(state.isWatchAppInstalled, privacy: .public)
                """)
        }
        if isReachable != state.isReachable { isReachable = state.isReachable }
        if isPaired != state.isPaired { isPaired = state.isPaired }
        if isWatchAppInstalled != state.isWatchAppInstalled { isWatchAppInstalled = state.isWatchAppInstalled }

        // Out of reach or back in reach: whatever was in flight is gone (WatchConnectivity fails it), and a watch that
        // comes back may have missed anything, so the next live status goes out whatever it shows.
        if state.isReachable != old.isReachable {
            liveGate.reset()
            ackTimeoutTask?.cancel()
            ackTimeoutTask = nil
        }

        // A new session (launch, or another watch) or a newly installed watch app: replace whatever context an earlier
        // run left behind. A watch that just became reachable gets the status at once.
        let isNewWatch = state.isActivated
            && (!old.isActivated || state.isPaired != old.isPaired || state.isWatchAppInstalled != old.isWatchAppInstalled)
        let becameReachable = state.isReachable && !old.isReachable
        guard isNewWatch || becameReachable else { return }
        let status = makeStatus()
        if becameReachable { pushLive(status) }
        if isNewWatch { pushContext(status) }
    }

    private func startSampling() {
        // No link (iPad, or not activated): nobody to tell.
        guard sampleTask == nil, link != nil, let sampleInterval else { return }
        remoteLog.info("sampling started")
        sampleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: sampleInterval)
                // Only strong for this tick, so the loop never keeps the hub alive.
                guard !Task.isCancelled, let self else { return }
                self.publishStatus()
            }
        }
    }

    private func stopSampling() {
        guard let sampleTask else { return }
        remoteLog.info("sampling stopped")
        sampleTask.cancel()
        self.sampleTask = nil
    }
}

/// The phone's remote log (Console: the app bundle ID as subsystem, category remote). Live pushes log at debug level.
let remoteLog = Logger(subsystem: LogSubsystem.current, category: "remote")

// MARK: - Session link

/// The parts of WCSession the hub uses, so tests can stand in for it. `WatchSessionLink` is the real one.
@MainActor
protocol RemoteSessionLink: AnyObject {
    /// Starts the session; from then on the link reports to `events`, always on the main actor.
    func activate(events: RemoteSessionEvents)
    /// A live status for a reachable watch, sent with a reply handler. `ended` runs once, on the main actor: true when
    /// the watch acknowledged it, false when it failed or wasn't sent (it may then run before `send` returns).
    func send(_ status: PrompterStatus, ended: @escaping @MainActor @Sendable (_ delivered: Bool) -> Void)
    /// Replaces the application context, which the watch reads when it opens. Failures are ignored.
    func updateContext(_ status: PrompterStatus)
}

/// The session as the hub sees it.
struct RemoteSessionState: Equatable, Sendable {
    var isActivated = false
    var isReachable = false
    var isPaired = false
    var isWatchAppInstalled = false
}

/// How a link reports to the hub.
struct RemoteSessionEvents: Sendable {
    /// Activation finished, or reachability, pairing or the watch app's installation changed.
    var stateChanged: @MainActor @Sendable (RemoteSessionState) -> Void
    /// A command arrived (nil: a message the phone couldn't read). The hub calls `reply` once with the status to reply
    /// with: at once for the iPhone's own prompter, later when it had to ask the Mac.
    var commandReceived: @MainActor @Sendable (
        _ command: RemoteCommand?, _ reply: @escaping @MainActor (PrompterStatus) -> Void
    ) -> Void
}
