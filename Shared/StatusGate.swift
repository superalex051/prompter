import Foundation

/// Watch side: keeps the newest status and drops anything older, so a slow reply to an old command can't overwrite a
/// newer live update.
struct StatusGate: Sendable {
    private(set) var latest: PrompterStatus?

    init() {}

    /// Accepts and stores the status if its sequence is greater than the latest accepted one. Returns whether it was accepted.
    mutating func accept(_ status: PrompterStatus) -> Bool {
        if let latest, status.sequence <= latest.sequence { return false }
        latest = status
        return true
    }
}

/// Phone side: stamps statuses with `max(last + 1, milliseconds since 2001)`. The wall-clock part keeps it increasing
/// across app launches (a relaunched phone starts above anything it sent before), the `+ 1` within a launch even if
/// the clock stalls or goes backwards.
struct SequenceClock: Sendable {
    private(set) var last: UInt64

    init(last: UInt64 = 0) {
        self.last = last
    }

    mutating func next(now: Date = Date()) -> UInt64 {
        // Saturates at UInt64.max (some 584 million years of milliseconds away).
        let following = last == .max ? last : last + 1
        last = max(following, Self.milliseconds(since2001: now))
        return last
    }

    /// Whole milliseconds since 1 January 2001; 0 for dates before it or not finite, capped far below UInt64.max.
    private static func milliseconds(since2001 date: Date) -> UInt64 {
        let milliseconds = date.timeIntervalSinceReferenceDate * 1_000
        guard milliseconds.isFinite, milliseconds > 0 else { return 0 }
        return UInt64(min(milliseconds, maxMilliseconds))
    }

    /// 2^62 ms: far beyond any real date, and exactly representable, so the conversion can't trap.
    private static let maxMilliseconds = Double(UInt64(1) << 62)
}
