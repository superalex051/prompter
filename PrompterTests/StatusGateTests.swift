import Foundation
import Testing
@testable import Prompter

struct StatusGateTests {
    static func status(_ sequence: UInt64, _ state: PlaybackState = .playing) -> PrompterStatus {
        var status = sampleStatus
        status.sequence = sequence
        status.state = state
        return status
    }

    /// Offers each status in order; which ones the gate took. (`#expect` can't call a mutating method itself.)
    static func offer(_ statuses: [PrompterStatus], to gate: inout StatusGate) -> [Bool] {
        statuses.map { gate.accept($0) }
    }

    @Test func startsEmptyAndAcceptsTheFirstStatus() {
        var gate = StatusGate()
        #expect(gate.latest == nil)
        let accepted = Self.offer([Self.status(5)], to: &gate)
        #expect(accepted == [true])
        #expect(gate.latest == Self.status(5))
    }

    @Test func acceptsNewerSequences() {
        var gate = StatusGate()
        let accepted = Self.offer([Self.status(5, .countdown(3)), Self.status(6, .playing)], to: &gate)
        #expect(accepted == [true, true])
        #expect(gate.latest?.state == .playing)
    }

    /// Review focus 2: the reply to an old command arrives after a newer 4 Hz status; the older one is dropped.
    @Test func dropsOlderSequence() {
        var gate = StatusGate()
        let accepted = Self.offer([Self.status(20, .paused), Self.status(19, .playing)], to: &gate)
        #expect(accepted == [true, false])
        #expect(gate.latest?.state == .paused)
        #expect(gate.latest?.sequence == 20)
    }

    @Test func dropsADuplicate() {
        var gate = StatusGate()
        let accepted = Self.offer([Self.status(20), Self.status(20, .finished)], to: &gate)
        #expect(accepted == [true, false])
        #expect(gate.latest?.state == .playing)
    }

    /// Review focus 1: the phone app is relaunched (its clock starts over) and the watch still takes its statuses.
    @Test func acceptsAfterPhoneRelaunch() {
        let launch = Date(timeIntervalSinceReferenceDate: 812_000_000)
        var firstRun = SequenceClock()
        // A long first run: 10 minutes of 4 Hz updates.
        let firstStatuses = (0..<2_400).map { tick in
            Self.status(firstRun.next(now: launch + Double(tick) * 0.25))
        }
        // Relaunched two seconds after the last update: a brand-new clock.
        var secondRun = SequenceClock()
        let relaunch = launch + 602
        let afterRelaunch = Self.status(secondRun.next(now: relaunch), .idle)
        let nextTick = Self.status(secondRun.next(now: relaunch + 0.25), .countdown(5))

        var gate = StatusGate()
        let accepted = Self.offer(firstStatuses + [afterRelaunch], to: &gate)
        #expect(accepted.allSatisfy { $0 })
        #expect(gate.latest?.state == .idle)
        #expect(Self.offer([nextTick], to: &gate) == [true])
        #expect(gate.latest?.state == .countdown(5))
    }

    @Test func noPrompterWithAFreshSequenceReplacesAPlayingStatus() {
        var gate = StatusGate()
        var clock = SequenceClock()
        let playing = Self.status(clock.next())
        var closed = PrompterStatus.noPrompter
        closed.sequence = clock.next()
        let accepted = Self.offer([playing, closed], to: &gate)
        #expect(accepted == [true, true])
        #expect(gate.latest?.hasPrompter == false)
    }
}

struct SequenceClockTests {
    /// The values `next(now:)` returns for each date in turn.
    static func values(_ clock: inout SequenceClock, _ dates: [Date]) -> [UInt64] {
        dates.map { clock.next(now: $0) }
    }

    static func date(_ seconds: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    @Test func isMillisecondsSince2001() {
        var clock = SequenceClock()
        let values = Self.values(&clock, [Self.date(812_345_678.5)])
        #expect(values == [812_345_678_500])
        #expect(clock.last == 812_345_678_500)
    }

    @Test func strictlyIncreasesWithinTheSameMillisecond() {
        var clock = SequenceClock()
        let values = Self.values(&clock, Array(repeating: Self.date(1_000), count: 5))
        #expect(values == [1_000_000, 1_000_001, 1_000_002, 1_000_003, 1_000_004])
    }

    @Test func staysMonotonicWhenTheWallClockGoesBackwards() {
        var clock = SequenceClock()
        let values = Self.values(&clock, [Self.date(5_000), Self.date(4_000), Self.date(4_500), Self.date(6_000)])
        // Once the wall clock passes the counter again, it follows the wall clock.
        #expect(values == [5_000_000, 5_000_001, 5_000_002, 6_000_000])
    }

    @Test func oddDatesDoNotCrash() {
        var clock = SequenceClock()
        let values = Self.values(&clock, [
            .distantPast,
            Self.date(.nan),
            Self.date(-.infinity),
            .distantFuture,
            Self.date(.infinity),
            Self.date(.greatestFiniteMagnitude),
        ])
        #expect(Array(values.prefix(3)) == [1, 2, 3])
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func neverOverflows() {
        var clock = SequenceClock(last: .max - 1)
        let values = Self.values(&clock, [Date(), Date()])
        #expect(values == [.max, .max])
    }
}
