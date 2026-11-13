import Foundation
import Testing
@testable import Prompter

struct LivePushGateTests {
    /// Playing, 42 % in, 176 s left; `sequence` stands for the moment the hub sampled it.
    static func status(_ sequence: UInt64, progress: Double = 0.42, remaining: Double = 176) -> PrompterStatus {
        var status = sampleStatus
        status.state = .playing
        status.progress = progress
        status.remainingSeconds = remaining
        status.sequence = sequence
        return status
    }

    @Test func theFirstStatusGoesOutAtOnce() {
        var gate = LivePushGate()
        let sent = gate.offer(Self.status(1))
        #expect(sent?.sequence == 1)
        #expect(gate.inFlight == 1)
        #expect(gate.pending == nil)
    }

    /// Idle or paused, the hub keeps sampling but nothing goes out: a fresh sequence alone isn't a change.
    @Test func nothingGoesOutWhenNothingTheWatchShowsChanged() {
        var gate = LivePushGate()
        _ = gate.offer(Self.status(1))
        _ = gate.ended(sequence: 1)
        var sent: [UInt64] = []
        for sequence in UInt64(2)...40 {
            if let status = gate.offer(Self.status(sequence, progress: 0.42 + Double(sequence) * 0.0001)) {
                sent.append(status.sequence)
            }
        }
        #expect(sent.isEmpty)
        #expect(gate.inFlight == nil)
        #expect(gate.pending == nil)
    }

    /// Each thing the watch shows is worth a message on its own.
    @Test(arguments: [
        "state", "title", "speed", "no prompter", "off screen", "time left", "progress",
    ])
    func everythingTheWatchShowsCountsAsAChange(_ field: String) {
        var gate = LivePushGate()
        let first = Self.status(1)
        _ = gate.offer(first)
        _ = gate.ended(sequence: 1)
        var changed = Self.status(2)
        switch field {
        case "state": changed.state = .paused
        case "title": changed.scriptTitle = "Outro"
        case "speed": changed.speedLabel = "150 wpm"
        case "no prompter": changed.hasPrompter = false
        case "off screen": changed.isOnScreen = false
        case "time left": changed.remainingSeconds = 175
        case "progress": changed.progress = 0.43
        default: Issue.record("unknown field \(field)")
        }
        #expect(LivePushGate.showsDifferently(changed, from: first))
        #expect(gate.offer(changed)?.sequence == 2)
    }

    @Test func smallProgressStepsAddUpToAMessage() {
        var gate = LivePushGate()
        _ = gate.offer(Self.status(1, progress: 0.5))
        _ = gate.ended(sequence: 1)
        // About 0.1 % at a time (1/1024, exact in binary): the sixth step is the first half a percent past the last
        // status handed out, and the seventh is compared with the sixth.
        let sent = (1...7).compactMap { step in
            gate.offer(Self.status(UInt64(step + 1), progress: 0.5 + Double(step) / 1024))?.sequence
        }
        #expect(sent == [7])
    }

    /// The core of the fix: one message in flight, and while it is only the newest status waits (no queue).
    @Test func oneInFlightAndOnlyTheNewestWaits() {
        var gate = LivePushGate()
        #expect(gate.offer(Self.status(1, remaining: 100))?.sequence == 1)
        // Three more changes while the first is on its way: none goes out, the newest replaces the others.
        #expect(gate.offer(Self.status(2, remaining: 99)) == nil)
        #expect(gate.offer(Self.status(3, remaining: 98)) == nil)
        #expect(gate.offer(Self.status(4, remaining: 97)) == nil)
        #expect(gate.pending?.sequence == 4)
        #expect(gate.inFlight == 1)

        // The watch acknowledges the first: the newest goes out and is in flight in turn.
        #expect(gate.ended(sequence: 1)?.sequence == 4)
        #expect(gate.inFlight == 4)
        #expect(gate.pending == nil)
        // Nothing waiting: the next acknowledgement just frees the way.
        #expect(gate.ended(sequence: 4) == nil)
        #expect(gate.inFlight == nil)
        #expect(gate.offer(Self.status(5, remaining: 96))?.sequence == 5)
    }

    /// A failure (or the hub's timeout) ends a message just like an acknowledgement; a late answer to a message that was
    /// given up on releases nothing extra.
    @Test func onlyTheMessageInFlightCanEnd() {
        var gate = LivePushGate()
        _ = gate.offer(Self.status(1, remaining: 100))
        _ = gate.offer(Self.status(2, remaining: 99))
        #expect(gate.ended(sequence: 7) == nil)          // never sent
        #expect(gate.inFlight == 1)
        #expect(gate.ended(sequence: 1)?.sequence == 2)  // failed or timed out: the waiting one goes
        _ = gate.offer(Self.status(3, remaining: 98))
        #expect(gate.ended(sequence: 1) == nil)          // the first one's answer, late: ignored
        #expect(gate.inFlight == 2)
        #expect(gate.pending?.sequence == 3)
    }

    /// The watch went out of reach or came back: nothing is in flight any more, and the next status goes out even if it
    /// shows the same as the last one.
    @Test func resetSendsTheNextWhateverItShows() {
        var gate = LivePushGate()
        _ = gate.offer(Self.status(1))
        _ = gate.offer(Self.status(2, remaining: 10))
        gate.reset()
        #expect(gate.inFlight == nil)
        #expect(gate.pending == nil)
        #expect(gate.offer(Self.status(3))?.sequence == 3)
    }

    @Test func notANumberAndInfinityDoNotCountAsChangesForever() {
        var gate = LivePushGate()
        _ = gate.offer(Self.status(1, progress: .nan, remaining: .infinity))
        _ = gate.ended(sequence: 1)
        #expect(gate.offer(Self.status(2, progress: .nan, remaining: .infinity)) == nil)
        #expect(gate.offer(Self.status(3, progress: 0.5, remaining: .infinity))?.sequence == 3)
        _ = gate.ended(sequence: 3)
        #expect(gate.offer(Self.status(4, progress: 0.5, remaining: 60))?.sequence == 4)
        _ = gate.ended(sequence: 4)
        #expect(gate.offer(Self.status(5, progress: 0.5, remaining: .nan))?.sequence == 5)
        _ = gate.ended(sequence: 5)
        #expect(gate.offer(Self.status(6, progress: 0.5, remaining: .nan)) == nil)
    }
}
