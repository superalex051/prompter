import Foundation

/// Phone side: which live statuses go to the watch, and when, so WatchConnectivity never holds a backlog. (In `Shared/`
/// because the Mac uses `showsDifferently` too, for what it pushes to the iPhone while presenting.)
///
/// - A status goes out only when what the watch shows changed since the last one handed out (`showsDifferently`):
///   the state, title, speed label, whether there is a prompter and whether it is on screen, the device and the note,
///   the whole seconds left, or the progress by at least `progressStep`. Idle or paused with nothing changing, nothing
///   goes out.
/// - At most one live message is in flight. While it is, the newest changed status waits in a single slot (a newer one
///   replaces it; there is no queue) and goes out when the watch acknowledges the one in flight, or that one fails or
///   times out (`ended(sequence:)`).
///
/// Why: the release-candidate end-to-end run pushed four messages a second unconditionally. The simulators' transport
/// stalled for 13 s when the watch app came up, then delivered about five messages a second in one batch, so the 52
/// messages that piled up took some 50 s to drain and every status (replies and the application context too) waited
/// 7–13 s behind stale ones. On a device the same habit costs radio time and battery for nothing.
struct LivePushGate: Sendable {
    /// Smallest progress change (0…1) worth a message: half a percent.
    static let progressStep = 0.005

    /// The last status handed out or waiting, which the next one is compared with. nil after `reset()`.
    private(set) var lastQueued: PrompterStatus?
    /// The sequence of the message on its way, waiting for the watch's acknowledgement.
    private(set) var inFlight: UInt64?
    /// The newest changed status, waiting for the one in flight to end.
    private(set) var pending: PrompterStatus?

    init() {}

    /// The hub has a fresh status. Returns it when it should go out now; nil when the watch already shows the same, or
    /// when a message is in flight (then it waits in `pending`, replacing anything older there).
    mutating func offer(_ status: PrompterStatus) -> PrompterStatus? {
        if let lastQueued, !Self.showsDifferently(status, from: lastQueued) { return nil }
        lastQueued = status
        guard inFlight == nil else {
            pending = status
            return nil
        }
        inFlight = status.sequence
        return status
    }

    /// The message with `sequence` was acknowledged, failed or timed out. Returns the waiting status to send now (it is
    /// then in flight). Anything but the message in flight (a late answer to one given up on) changes nothing.
    mutating func ended(sequence: UInt64) -> PrompterStatus? {
        guard inFlight == sequence else { return nil }
        inFlight = nil
        guard let next = pending else { return nil }
        pending = nil
        inFlight = next.sequence
        return next
    }

    /// Forgets everything: the watch went out of reach or came back, so nothing is in flight and the next status goes
    /// out whatever it shows.
    mutating func reset() {
        lastQueued = nil
        inFlight = nil
        pending = nil
    }

    /// Whether the watch would show `status` differently from `old`. The sequence never counts.
    static func showsDifferently(_ status: PrompterStatus, from old: PrompterStatus) -> Bool {
        status.hasPrompter != old.hasPrompter
            || status.scriptTitle != old.scriptTitle
            || status.state != old.state
            || status.speedLabel != old.speedLabel
            || status.isOnScreen != old.isOnScreen
            || status.deviceName != old.deviceName
            || status.note != old.note
            || !sameWholeSeconds(status.remainingSeconds, old.remainingSeconds)
            || progressMoved(from: old.progress, to: status.progress)
    }

    // MARK: Private

    /// The engine already rounds the time left up to whole seconds; rounding here too keeps a fraction from counting.
    private static func sameWholeSeconds(_ a: Double, _ b: Double) -> Bool {
        if a.isNaN || b.isNaN { return a.isNaN && b.isNaN }
        return a.rounded(.up) == b.rounded(.up)
    }

    private static func progressMoved(from old: Double, to new: Double) -> Bool {
        if old.isNaN || new.isNaN { return old.isNaN != new.isNaN }
        if old == new { return false }   // also two equal infinities, whose difference is NaN
        return abs(new - old) >= progressStep
    }
}
