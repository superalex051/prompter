import Testing
@testable import Prompter

struct DisplayPositionSmootherTests {
    static let frame = 1.0 / 120

    @Test(arguments: [20.0, -20, 24, -24, 0.3])
    func snapsWithinSnapDistance(offset: Double) {
        var smoother = DisplayPositionSmoother(current: 500)
        #expect(smoother.next(target: 500 + offset, dt: Self.frame) == 500 + offset)
        #expect(smoother.current == 500 + offset)
        #expect(!smoother.isEasing)
    }

    @Test func normalScrollingIsUntouched() {
        // 2.5 lines of 115 pt per second at 60 Hz is under 5 pt a frame; even 20 pt frames pass straight through.
        for step in [0.8, 4.8, 20.0, -3.0] {
            var smoother = DisplayPositionSmoother(current: 1_000)
            var target = 1_000.0
            for _ in 0..<600 {
                target += step
                #expect(smoother.next(target: target, dt: Self.frame) == target)
            }
        }
    }

    @Test(arguments: [1_000.0, -1_000, 30, -300])
    func easesALargeJumpWithoutOvershooting(jump: Double) {
        var smoother = DisplayPositionSmoother(current: 5_000)
        let target = 5_000 + jump
        var previousDistance = abs(jump)
        var elapsed = 0.0
        var settledAfter: Double?
        for _ in 0..<240 {
            let value = smoother.next(target: target, dt: Self.frame)
            elapsed += Self.frame
            let distance = abs(target - value)
            // Moves toward the target every frame and never past it.
            #expect(distance <= previousDistance)
            #expect(jump > 0 ? value <= target : value >= target)
            if distance > 0 { #expect(distance < previousDistance) }
            previousDistance = distance
            if settledAfter == nil, distance < 1 { settledAfter = elapsed }
        }
        #expect((settledAfter ?? .infinity) < 0.6)
        #expect(smoother.current == target)
        #expect(!smoother.isEasing)
    }

    @Test func aJumpIsEasedNotSnapped() {
        var smoother = DisplayPositionSmoother(current: 0)
        let first = smoother.next(target: 1_000, dt: Self.frame)
        #expect(first > 0)
        #expect(first < 200)
        #expect(smoother.isEasing)
    }

    @Test func catchesUpWithAMovingTargetAfterAJump() {
        // Jump back 600 pt while the text keeps scrolling at 460 pt/s (the fastest finish-in speed at 115 pt lines).
        var smoother = DisplayPositionSmoother(current: 2_000)
        var target = 1_400.0
        var caughtUpAfter: Double?
        for frame in 1...240 {
            target += 460 * Self.frame
            let value = smoother.next(target: target, dt: Self.frame)
            if caughtUpAfter == nil, value == target { caughtUpAfter = Double(frame) * Self.frame }
        }
        #expect((caughtUpAfter ?? .infinity) < 0.6)
        #expect(smoother.current == target)
    }

    @Test func invalidInputsDoNotMoveOrPoisonTheValue() {
        var smoother = DisplayPositionSmoother(current: 100)
        #expect(smoother.next(target: .nan, dt: Self.frame) == 100)
        #expect(smoother.next(target: .infinity, dt: Self.frame) == 100)
        #expect(smoother.next(target: 1_000, dt: .nan) == 100)
        #expect(smoother.next(target: 1_000, dt: -1) == 100)
        #expect(smoother.next(target: 1_000, dt: 0) == 100)
        #expect(smoother.current == 100)
        // A huge gap (the app was in the background) lands exactly on the target.
        #expect(smoother.next(target: 1_000, dt: 5) == 1_000)
    }

    @Test func resetJumpsStraightThere() {
        var smoother = DisplayPositionSmoother(current: 0)
        _ = smoother.next(target: 1_000, dt: Self.frame)
        #expect(smoother.isEasing)
        smoother.reset(to: 3_000)
        #expect(smoother.current == 3_000)
        #expect(!smoother.isEasing)
        #expect(smoother.next(target: 3_004, dt: Self.frame) == 3_004)
    }
}
