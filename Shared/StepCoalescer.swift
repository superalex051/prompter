import Foundation

/// Batches Digital Crown detents so the watch sends at most one speed message per `interval`, carrying the sum of the
/// steps since the last one. The first detent after a quiet spell goes out at once; detents inside the window are
/// summed and flushed when it ends. Steps that cancel out (+1, −1) send nothing.
///
/// Times are seconds on any monotonic clock (the watch uses `ProcessInfo.systemUptime`), so tests can pass their own.
struct StepCoalescer: Sendable {
    enum Action: Equatable, Sendable {
        /// Send this many steps now.
        case send(Int)
        /// Call `flush(now:)` after this many seconds.
        case flush(after: TimeInterval)
        /// Nothing to do (a flush is already due, or the steps were zero).
        case none
    }

    let interval: TimeInterval
    /// Steps waiting for the next flush.
    private(set) var pending = 0
    private var lastSent: TimeInterval?
    private var isFlushScheduled = false

    init(interval: TimeInterval = 0.1) {
        self.interval = interval
    }

    mutating func add(_ steps: Int, now: TimeInterval) -> Action {
        pending = Self.sum(pending, steps)
        guard !isFlushScheduled else { return .none }
        if let lastSent, now - lastSent < interval, now >= lastSent {
            isFlushScheduled = true
            return .flush(after: interval - (now - lastSent))
        }
        return flush(now: now).map(Action.send) ?? .none
    }

    /// Takes the pending steps (nil if they sum to zero) and starts a new window if there were any.
    mutating func flush(now: TimeInterval) -> Int? {
        isFlushScheduled = false
        let steps = pending
        pending = 0
        guard steps != 0 else { return nil }
        lastSent = now
        return steps
    }

    /// Adds without trapping, however long someone spins the Crown.
    private static func sum(_ a: Int, _ b: Int) -> Int {
        let (result, overflow) = a.addingReportingOverflow(b)
        return overflow ? (b > 0 ? .max : .min) : result
    }
}
