import Foundation
import Testing
@testable import Prompter

struct StepCoalescerTests {
    @Test func firstStepGoesOutAtOnce() {
        var coalescer = StepCoalescer(interval: 0.1)
        #expect(coalescer.add(1, now: 10) == .send(1))
        #expect(coalescer.pending == 0)
    }

    @Test func stepsInsideTheWindowAreSummedAndFlushedOnce() {
        var coalescer = StepCoalescer(interval: 0.1)
        #expect(coalescer.add(1, now: 10) == .send(1))
        let first = coalescer.add(1, now: 10.03)
        guard case .flush(let after) = first else {
            Issue.record("expected a scheduled flush, got \(first)")
            return
        }
        #expect(abs(after - 0.07) < 1e-9)
        #expect(coalescer.add(1, now: 10.05) == .none)
        #expect(coalescer.add(1, now: 10.08) == .none)
        #expect(coalescer.flush(now: 10.1) == 3)
        #expect(coalescer.pending == 0)
    }

    @Test func atMostOneMessagePerInterval() {
        var coalescer = StepCoalescer(interval: 0.1)
        var sent: [Int] = []
        var flushAt: Double?
        // 40 detents over one second (a quick spin), one every 25 ms.
        for tick in 0..<40 {
            let now = Double(tick) * 0.025
            if let due = flushAt, now >= due {
                if let steps = coalescer.flush(now: due) { sent.append(steps) }
                flushAt = nil
            }
            switch coalescer.add(1, now: now) {
            case .send(let steps): sent.append(steps)
            case .flush(let after): flushAt = now + after
            case .none: break
            }
        }
        if let due = flushAt, let steps = coalescer.flush(now: due) { sent.append(steps) }
        #expect(sent.reduce(0, +) == 40)
        #expect(sent.count <= 11)
        #expect(sent.count >= 9)
    }

    @Test func afterAQuietSpellTheNextStepGoesOutAtOnce() {
        var coalescer = StepCoalescer(interval: 0.1)
        #expect(coalescer.add(-1, now: 5) == .send(-1))
        #expect(coalescer.add(-1, now: 5.5) == .send(-1))
    }

    @Test func stepsThatCancelOutSendNothing() {
        var coalescer = StepCoalescer(interval: 0.1)
        #expect(coalescer.add(1, now: 1) == .send(1))
        #expect(coalescer.add(1, now: 1.02) != .none)
        #expect(coalescer.add(-1, now: 1.04) == .none)
        #expect(coalescer.flush(now: 1.1) == nil)
        // Nothing went out, so the window didn't restart: the next step at 1.15 is outside the first window.
        #expect(coalescer.add(2, now: 1.15) == .send(2))
    }

    @Test func zeroStepsDoNothing() {
        var coalescer = StepCoalescer(interval: 0.1)
        #expect(coalescer.add(0, now: 1) == .none)
        #expect(coalescer.add(1, now: 1.01) == .send(1))
    }

    @Test func aClockGoingBackwardsDoesNotHoldStepsForever() {
        var coalescer = StepCoalescer(interval: 0.1)
        #expect(coalescer.add(1, now: 100) == .send(1))
        #expect(coalescer.add(1, now: 50) == .send(1))
    }

    @Test func hugeSumsSaturateInsteadOfTrapping() {
        var coalescer = StepCoalescer(interval: 0.1)
        #expect(coalescer.add(1, now: 0) == .send(1))
        _ = coalescer.add(.max, now: 0.01)
        _ = coalescer.add(.max, now: 0.02)
        #expect(coalescer.flush(now: 0.1) == .max)
    }
}
