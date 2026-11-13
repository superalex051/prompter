import Foundation

/// Watch side: when to ask the phone for its status (`requestStatus`) because the phone's own updates stopped arriving.
///
/// The phone pushes a live status whenever what the watch shows changes, but WatchConnectivity only lets it push while
/// the phone's session believes the watch app is installed and reachable, and that belief can be wrong. In the M3
/// end-to-end run the phone's session reported the watch app as not installed for a whole take while the watch app was
/// open on the wrist: the phone sent no live message and no application context, and the watch sat on "5" while the
/// phone counted down and played. The replies to the watch's own messages still came back, so the watch asks whenever
/// the pushes go quiet.
///
/// How quiet is too quiet depends on the take. Counting down or playing on screen, the digit or the time left changes
/// every second, so the phone pushes at least once a second and a 1.5 s gap means trouble. Idle, paused, finished, off
/// screen or without a prompter, nothing changes and the phone rightly pushes nothing; asking every few seconds is
/// enough to notice a change made on the phone. (Following the voice while the reader is silent nothing changes either;
/// the watch then asks once a second, which is cheap.)
///
/// Times are seconds on a monotonic clock (the watch uses `ProcessInfo.systemUptime`), so tests can pass their own.
struct StatusPoll: Sendable {
    /// While the take moves, ask after this long without a push. Well above the gap between pushes: about a second on
    /// a device (the time left), about a second on the simulators too (they deliver in batches about once a second).
    static let quietLimit: TimeInterval = 1.5
    /// Between requests while the take moves and pushes stay quiet: the watch then lags the phone by about this plus
    /// one reply (under a second).
    static let liveInterval: TimeInterval = 1
    /// While nothing moves the phone pushes only on a change, so silence is normal: asking every few seconds is enough.
    static let idleInterval: TimeInterval = 3
    /// A request with neither a reply nor an error after this long counts as lost.
    static let requestTimeout: TimeInterval = 5

    private var lastPush: TimeInterval?
    private var lastRequest: TimeInterval?
    /// When the unanswered request went out.
    private var pendingSince: TimeInterval?

    init() {}

    /// The phone pushed a status (a live message or the application context), whether or not the watch kept it.
    mutating func pushArrived(now: TimeInterval) {
        lastPush = now
    }

    /// A `requestStatus` went out, from here or elsewhere (the watch also asks when the phone becomes reachable).
    mutating func requestSent(now: TimeInterval) {
        lastRequest = now
        pendingSince = now
    }

    /// The request's reply or error arrived.
    mutating func requestEnded() {
        pendingSince = nil
    }

    /// Whether to send a `requestStatus` now (and if so, records it as sent). `expectsPushes`: the newest status the
    /// watch holds shows a take moving on screen, so the phone should be pushing at least once a second.
    mutating func shouldRequest(now: TimeInterval, isReachable: Bool, expectsPushes: Bool) -> Bool {
        guard isReachable else { return false }
        if let pendingSince, now - pendingSince < Self.requestTimeout { return false }
        let quiet = expectsPushes ? Self.quietLimit : Self.idleInterval
        let spacing = expectsPushes ? Self.liveInterval : Self.idleInterval
        if let lastPush, now - lastPush < quiet { return false }
        if let lastRequest, now - lastRequest < spacing { return false }
        requestSent(now: now)
        return true
    }

    /// `shouldRequest(now:isReachable:expectsPushes:)` for the newest status the watch holds (nil: none yet). Only a
    /// prompter that is open, on screen and counting down or playing is followed live (`expectsPushes(from:)`).
    mutating func shouldRequest(now: TimeInterval, isReachable: Bool, latest: PrompterStatus?) -> Bool {
        shouldRequest(now: now, isReachable: isReachable, expectsPushes: Self.expectsPushes(from: latest))
    }

    /// The take in `latest` moves on screen (counting down or playing), so the phone pushes at least once a second.
    static func expectsPushes(from latest: PrompterStatus?) -> Bool {
        guard let latest, latest.isLive else { return false }
        switch latest.state {
        case .countdown, .playing: return true
        case .idle, .paused, .finished: return false
        }
    }
}
