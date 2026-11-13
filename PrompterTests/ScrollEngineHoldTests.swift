import Foundation
import Testing
@testable import Prompter

/// `[pause N]` holds. The rules (see `ScrollEngine.advance(to:)` and `pause()`):
/// - while playing, when the position reaches a cue's line (or playing starts or a step lands right on it) the text stands
///   still for N seconds, the state stays `.playing`, then it scrolls on;
/// - a hold runs once per visit: a pause or a drag during it ends it, and resuming scrolls straight on; moving away by a
///   step, a drag or back to top lets the cue hold again when playing reaches it next time;
/// - time remaining includes the holds still to come; finish in counts them inside the chosen duration.
///
/// Layouts are `uniform(lines: 10)` (100 pt lines, 20 characters each) at speed level 4, so 100 pt/s, unless stated.
@MainActor
extension ScrollEngineTests {
    /// `layout` with a hold of `seconds` at the top of each given line (keyed by the line's first character, like a cue).
    static func withHolds(_ layout: PrompterLayout, _ holds: [(line: Int, seconds: Double)]) -> PrompterLayout {
        var layout = layout
        layout.holds = holds.map { hold in
            let line = layout.lines[hold.line]
            return PrompterLayout.Hold(y: line.y, seconds: hold.seconds, characterIndex: line.characterIndex)
        }
        return layout
    }

    @Test func holdStopsAtTheCueForItsDuration() {
        let (engine, clock) = makeEngine(layout: Self.withHolds(Self.uniform(lines: 10), [(3, 3)]))
        let log = EventLog(engine)
        engine.start()
        run(engine, clock, for: 2.5)
        #expect(abs(engine.position - 250) < 0.01)
        #expect(!engine.isHolding)
        #expect(engine.holdSecondsLeft == nil)

        run(engine, clock, for: 1)              // reached the cue at 3.0 s; 2.5 s of the hold left
        #expect(engine.position == 300)
        #expect(engine.isHolding)
        #expect(engine.state == .playing)
        #expect(engine.needsFrames)
        #expect(engine.holdSecondsLeft == 3)
        run(engine, clock, for: 1)
        #expect(engine.holdSecondsLeft == 2)
        run(engine, clock, for: 1)
        #expect(engine.holdSecondsLeft == 1)
        #expect(engine.position == 300)

        run(engine, clock, for: 1)              // the hold ended at 6.0 s; half a second of scrolling since
        #expect(!engine.isHolding)
        #expect(engine.holdSecondsLeft == nil)
        #expect(abs(engine.position - 350) < 0.01)
        let rest = run(engine, clock, for: 10) { $0.state == .finished }
        #expect(abs(rest - 6.5) <= 0.1)         // 650 pt to go at 100 pt/s, no more holds
        #expect(log.events == [.go, .finished])  // a hold is not a pause
    }

    @Test func timeRemainingIncludesTheHoldsToCome() {
        let (engine, clock) = makeEngine(layout: Self.withHolds(Self.uniform(lines: 10), [(3, 3), (6, 2)]))
        #expect(engine.preciseRemainingSeconds == 15)       // 10 s of scrolling + 5 s of holds
        #expect(engine.remainingSeconds == 15)
        #expect(engine.pendingHoldSeconds == 5)
        engine.start()
        run(engine, clock, for: 4)              // 1 s into the first hold
        #expect(abs(engine.preciseRemainingSeconds - (7 + 2 + 2)) < 1e-6)
        run(engine, clock, for: 3)              // first hold over at 6 s; at 400
        #expect(abs(engine.preciseRemainingSeconds - (6 + 2)) < 1e-6)
        let rest = run(engine, clock, for: 20) { $0.state == .finished }
        #expect(abs(rest - 8) <= 0.1)
    }

    @Test func wpmTimesTheTextWordsAndAddsTheHolds() {
        // 140 words at 140 wpm is one minute of scrolling, plus a 5 s hold half way.
        let layout = Self.withHolds(Self.uniform(lines: 14, words: 140), [(7, 5)])
        let (engine, clock) = makeEngine(layout: layout) {
            $0.scrollMode = .wpm
            $0.wordsPerMinute = 140
        }
        #expect(engine.remainingSeconds == 65)
        engine.start()
        let elapsed = run(engine, clock, for: 80) { $0.state == .finished }
        #expect(abs(elapsed - 65) <= 0.1)
    }

    @Test func pauseDuringAHoldEndsIt() {
        let (engine, clock) = makeEngine(layout: Self.withHolds(Self.uniform(lines: 10), [(3, 3)]))
        let log = EventLog(engine)
        engine.start()
        run(engine, clock, for: 4)              // 1 s into the hold
        #expect(engine.isHolding)
        engine.pause()
        #expect(engine.state == .paused)
        #expect(!engine.isHolding)
        #expect(engine.holdSecondsLeft == nil)
        #expect(engine.position == 300)
        #expect(abs(engine.preciseRemainingSeconds - 7) < 1e-6)    // the cut-short hold no longer counts

        clock.now += 10
        engine.resume()                         // the presenter took over the timing: straight on, no second hold
        #expect(!engine.isHolding)
        run(engine, clock, for: 1)
        #expect(abs(engine.position - 400) < 0.01)
        #expect(log.events == [.go, .paused, .resumed])
    }

    @Test func tappingTwiceDuringAHoldSkipsIt() {
        let (engine, clock) = makeEngine(layout: Self.withHolds(Self.uniform(lines: 10), [(3, 3)]))
        engine.start()
        run(engine, clock, for: 3.5)
        #expect(engine.isHolding)
        engine.togglePlay()
        engine.togglePlay()
        #expect(engine.state == .playing)
        #expect(!engine.isHolding)
        run(engine, clock, for: 0.5)
        #expect(abs(engine.position - 350) < 0.01)
    }

    @Test func scrubbingPastAHoldSkipsIt() {
        let (engine, clock) = makeEngine(layout: Self.withHolds(Self.uniform(lines: 10), [(3, 3)]))
        engine.start()
        run(engine, clock, for: 2)
        engine.scrub(by: 150)                   // from 200 past the cue to 350, paused
        #expect(engine.state == .paused)
        #expect(abs(engine.preciseRemainingSeconds - 6.5) < 1e-6)  // the cue is behind: no hold in the time left
        engine.resume()
        run(engine, clock, for: 1)
        #expect(!engine.isHolding)
        #expect(abs(engine.position - 450) < 0.01)
    }

    @Test func scrubbingBackBeforeAHoldHoldsAgain() {
        let (engine, clock) = makeEngine(layout: Self.withHolds(Self.uniform(lines: 10), [(3, 3)]))
        engine.start()
        run(engine, clock, for: 6.5)            // held 3…6 s, now at 350
        #expect(!engine.isHolding)
        #expect(abs(engine.position - 350) < 0.01)
        engine.scrub(by: -100)                  // back to 250, before the cue
        engine.resume()
        run(engine, clock, for: 1)              // reaches it after 0.5 s and holds again
        #expect(engine.isHolding)
        #expect(engine.position == 300)
        #expect(engine.holdSecondsLeft == 3)
    }

    @Test func draggingDuringAHoldEndsItAndForwardDoesNotHoldAgain() {
        let (engine, clock) = makeEngine(layout: Self.withHolds(Self.uniform(lines: 10), [(3, 3)]))
        engine.start()
        run(engine, clock, for: 4)
        engine.scrubBegan()
        #expect(engine.state == .paused)
        #expect(!engine.isHolding)
        engine.scrub(by: 30)
        engine.resume()
        run(engine, clock, for: 0.5)
        #expect(!engine.isHolding)
        #expect(abs(engine.position - 380) < 0.01)
    }

    @Test func steppingOntoAHoldWhilePlayingHoldsThere() {
        let (engine, clock) = makeEngine(layout: Self.withHolds(Self.uniform(lines: 10), [(3, 3)]))
        engine.start()
        run(engine, clock, for: 0.5)
        engine.stepLine(3)                      // 50 → 100 → 200 → 300, the cue
        #expect(engine.position == 300)
        #expect(engine.state == .playing)
        #expect(engine.isHolding)
        #expect(engine.holdSecondsLeft == 3)
        run(engine, clock, for: 2.5)
        #expect(engine.position == 300)
        run(engine, clock, for: 1)
        #expect(abs(engine.position - 350) < 0.01)
    }

    @Test func steppingOntoAHoldWhilePausedHoldsOnResume() {
        let (engine, clock) = makeEngine(layout: Self.withHolds(Self.uniform(lines: 10), [(3, 3)]))
        engine.stepLine(3)                      // idle, on the cue
        #expect(engine.remainingSeconds == 10)  // 7 s of scrolling + the 3 s hold it will start with
        engine.start()                          // no countdown: plays, and holds first
        #expect(engine.isHolding)
        run(engine, clock, for: 3.5)
        #expect(abs(engine.position - 350) < 0.01)
    }

    @Test func steppingOffAHoldMovesOnOrHoldsAgainLater() {
        let (forward, forwardClock) = makeEngine(layout: Self.withHolds(Self.uniform(lines: 10), [(3, 3)]))
        forward.start()
        run(forward, forwardClock, for: 3.5)
        forward.stepLine(1)                     // off the cue to 400, still playing
        #expect(forward.state == .playing)
        #expect(!forward.isHolding)
        run(forward, forwardClock, for: 1)
        #expect(abs(forward.position - 500) < 0.01)

        let (back, backClock) = makeEngine(layout: Self.withHolds(Self.uniform(lines: 10), [(3, 3)]))
        back.start()
        run(back, backClock, for: 3.5)
        back.stepLine(-1)                       // back to 200: re-reading that line, then the pause again
        #expect(back.position == 200)
        #expect(!back.isHolding)
        run(back, backClock, for: 1.5)
        #expect(back.isHolding)
        #expect(back.position == 300)
    }

    @Test func holdAtTheVeryStart() {
        let (engine, clock) = makeEngine(layout: Self.withHolds(Self.uniform(lines: 10), [(0, 3)])) {
            $0.countdownSeconds = 3
        }
        let log = EventLog(engine)
        #expect(engine.remainingSeconds == 13)
        engine.start()
        #expect(engine.state == .countdown(3))
        #expect(!engine.isHolding)
        engine.tick(now: clock.now)             // the countdown's first frame (it is on screen)
        clock.now += 3
        engine.tick(now: clock.now)             // "go": the text is on the cue, so it holds first
        #expect(engine.state == .playing)
        #expect(engine.isHolding)
        #expect(engine.holdSecondsLeft == 3)
        #expect(engine.position == 0)
        run(engine, clock, for: 2.9)
        #expect(engine.position == 0)
        run(engine, clock, for: 0.2)
        #expect(abs(engine.position - 10) < 0.01)
        #expect(log.events == [.countdownTick(3), .go])     // one tick at the 3 s mark: straight to "go"
    }

    @Test func backToTopDuringAHoldClearsIt() {
        let (engine, clock) = makeEngine(layout: Self.withHolds(Self.uniform(lines: 10), [(3, 3)]))
        engine.start()
        run(engine, clock, for: 4)
        engine.backToTop()
        #expect(engine.state == .idle)
        #expect(!engine.isHolding)
        #expect(engine.holdSecondsLeft == nil)
        #expect(engine.remainingSeconds == 13)
        engine.start()
        run(engine, clock, for: 3.5)
        #expect(engine.isHolding)               // the same cue holds again on the next pass
    }

    @Test func relayoutDuringAHoldKeepsHolding() {
        let (engine, clock) = makeEngine(layout: Self.withHolds(Self.uniform(lines: 10), [(3, 3)]))
        engine.start()
        run(engine, clock, for: 4)              // the cue starts at character 60; 2 s of the hold left
        // Pinch to bigger text: 150 pt lines of 12 characters, so the cue (character 60) is now line 5, at 750.
        let bigger = Self.withHolds(Self.uniform(lines: 20, pitch: 150, charactersPerLine: 12), [(5, 3)])
        engine.updateLayout(bigger)
        #expect(engine.position == 750)
        #expect(engine.isHolding)
        #expect(engine.holdSecondsLeft == 2)
        run(engine, clock, for: 2.5)            // the rest of the hold, then 0.5 s at 150 pt/s
        #expect(!engine.isHolding)
        #expect(abs(engine.position - 825) < 0.01)
    }

    @Test func finishInCountsTheHoldsInsideTheChosenTime() {
        // 2000 pt in 2:00 with a 10 s hold half way: the text scrolls 2000 pt in 110 s and the take still ends at 2:00.
        let layout = Self.withHolds(Self.uniform(lines: 20), [(10, 10)])
        let (engine, clock) = makeEngine(layout: layout) {
            $0.scrollMode = .finishIn
            $0.finishInSeconds = 120
        }
        #expect(engine.remainingSeconds == 120)
        engine.start()
        #expect(abs(engine.pointsPerSecond - 2_000.0 / 110) < 1e-9)
        run(engine, clock, for: 60)             // reached the cue at 55 s; 5 s into the hold
        #expect(engine.isHolding)
        #expect(engine.position == 1_000)
        #expect(abs(engine.preciseRemainingSeconds - 60) < 0.05)
        #expect(abs(engine.pointsPerSecond - 2_000.0 / 110) < 1e-6)   // the pace after the hold is unchanged
        let rest = run(engine, clock, for: 70) { $0.state == .finished }
        #expect(abs(rest - 60) <= 0.1)
    }

    @Test func finishInSpeedStepKeepsTheHoldsWhole() {
        let layout = Self.withHolds(Self.uniform(lines: 20), [(10, 10)])
        let (idle, _) = makeEngine(layout: layout) {
            $0.scrollMode = .finishIn
            $0.finishInSeconds = 120
        }
        idle.speedStep(-2)                      // 2:00 → 2:10
        #expect(idle.remainingSeconds == 130)

        let (playing, _) = makeEngine(layout: layout) {
            $0.scrollMode = .finishIn
            $0.finishInSeconds = 120
        }
        playing.start()
        playing.speedStep(-2)
        #expect(abs(playing.preciseRemainingSeconds - 130) < 1e-9)
        #expect(abs(playing.pointsPerSecond - 2_000.0 / 120) < 1e-9)  // 120 s of scrolling + the 10 s hold
    }

    @Test func holdsLongerThanTheFinishInTimeScrollAtTheCap() {
        let layout = Self.withHolds(Self.uniform(lines: 20), [(5, 60), (10, 60)])
        let (engine, clock) = makeEngine(layout: layout) {
            $0.scrollMode = .finishIn
            $0.finishInSeconds = 60
        }
        // 2000 pt at the 250 pt/s cap is 8 s, plus 120 s of holds: honest, not 60 s.
        #expect(engine.remainingSeconds == 128)
        engine.start()
        #expect(engine.pointsPerSecond == 250)
        let elapsed = run(engine, clock, for: 140) { $0.state == .finished }
        #expect(abs(elapsed - 128) <= 0.1)
    }

    @Test func aHoldWithNoSecondsIsIgnored() {
        let (engine, clock) = makeEngine(layout: Self.withHolds(Self.uniform(lines: 10), [(3, 0)]))
        engine.start()
        run(engine, clock, for: 4)
        #expect(!engine.isHolding)
        #expect(abs(engine.position - 400) < 0.01)
    }

    @Test func aHoldOnTheLastLineHoldsThenFinishes() {
        let (engine, clock) = makeEngine(layout: Self.withHolds(Self.uniform(lines: 10), [(9, 2)]))
        let log = EventLog(engine)
        engine.start()
        let elapsed = run(engine, clock, for: 20) { $0.state == .finished }
        #expect(abs(elapsed - 12) <= 0.1)
        #expect(log.events == [.go, .finished])
    }
}

struct PrompterHUDHoldTextTests {
    @Test func holdWord() {
        #expect(PrompterHUD.stateWord(for: .playing, holdSeconds: 3) == "Pause 3")
        #expect(PrompterHUD.stateWord(for: .playing, holdSeconds: nil) == nil)
        #expect(PrompterHUD.stateWord(for: .paused, holdSeconds: nil) == "Paused")
        #expect(PrompterHUD.accessibilityText(state: .playing, remainingSeconds: 72, speedLabel: "140 wpm", holdSeconds: 2)
            == "Pause 2, 1:12 left, 140 wpm")
        #expect(PrompterHUD.accessibilityText(state: .playing, remainingSeconds: 72, speedLabel: "140 wpm")
            == "Playing, 1:12 left, 140 wpm")
    }
}
