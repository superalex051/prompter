import Foundation

enum TimeFormatting {
    /// "0:00"-style clock. Rounds to the nearest second. Negative, NaN or infinite → "0:00". ≥ 1 h → "h:mm:ss".
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        // Cap far beyond any real script so the Int conversion can't trap.
        let total = Int(min(seconds, 1e12).rounded())
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let secs = total % 60
        if hours > 0 {
            return "\(hours):\(twoDigits(minutes)):\(twoDigits(secs))"
        }
        return "\(minutes):\(twoDigits(secs))"
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
