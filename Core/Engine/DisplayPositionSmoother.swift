import Foundation

/// Turns the engine's position into the position the text view shows, so jumps (line/paragraph steps, back to top)
/// glide instead of cutting, while normal scrolling and finger drags pass through untouched.
///
/// At rest, a target within `snapDistance` is returned exactly. A bigger change starts an ease-out: each frame closes
/// `1 - exp(-dt / 0.09)` of the gap, but at least `minimumSpeed × dt`, so the tail ends promptly instead of creeping or
/// snapping. While easing, small per-frame target moves (normal scrolling) are followed 1:1, so the ease finishes on time
/// even while the text keeps scrolling. Never overshoots.
struct DisplayPositionSmoother: Equatable, Sendable {
    static let timeConstant = 0.09
    static let minimumSpeed = 400.0     // points per second

    /// The position currently shown.
    var current: Double
    var snapDistance: Double
    /// True between a jump and the moment `current` lands exactly on the target.
    private(set) var isEasing = false
    private var lastTarget: Double?

    init(current: Double = 0, snapDistance: Double = 24) {
        self.current = current
        self.snapDistance = snapDistance
    }

    /// The position to show this frame. `dt` is the time since the previous frame.
    mutating func next(target: Double, dt: Double) -> Double {
        guard target.isFinite else { return current }
        defer { lastTarget = target }
        guard current.isFinite else {
            reset(to: target)
            return target
        }

        if isEasing, let lastTarget, abs(target - lastTarget) <= snapDistance {
            current += target - lastTarget
        }
        let gap = target - current
        if gap == 0 || (!isEasing && abs(gap) <= snapDistance) {
            current = target
            isEasing = false
            return target
        }

        isEasing = true
        let step = Self.easingStep(gap: abs(gap), dt: dt)
        if step >= abs(gap) {
            current = target
            isEasing = false
        } else {
            current += gap < 0 ? -step : step
        }
        return current
    }

    /// Show `position` right away (after a relayout, when the content itself changed under the offset).
    mutating func reset(to position: Double) {
        current = position
        lastTarget = position
        isEasing = false
    }

    /// How far to move this frame toward a target `gap` points away. 0 for a non-positive or NaN `dt`.
    static func easingStep(gap: Double, dt: Double) -> Double {
        guard dt > 0, gap > 0 else { return 0 }
        let exponential = gap * (1 - exp(-dt / timeConstant))
        return min(gap, max(exponential, minimumSpeed * dt))
    }
}
