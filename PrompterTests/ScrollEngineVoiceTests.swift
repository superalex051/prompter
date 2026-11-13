import Foundation
import Testing
@testable import Prompter

/// Voice mode in the engine (see "Voice mode" on `ScrollEngine`): it waits for the reader, eases to the line speech says
/// they reached (never faster than 4 lines/s, never jumping), says "Listening…" after 2 s without a new match, ignores
/// `[pause N]` holds and speed steps, times the rest at the WPM setting, and falls back to WPM when voice can't listen.
///
/// Layouts are `uniform(lines: 10)`: 100 pt lines of 20 characters, so character 45 is on line 2 (y 200).
@MainActor
extension ScrollEngineTests {
    func makeVoiceEngine(
        layout: PrompterLayout = uniform(lines: 10),
        _ configure: (inout PrompterSettings) -> Void = { _ in }
    ) -> (ScrollEngine, ManualClock) {
        makeEngine(layout: layout) {
            $0.scrollMode = .voice
            configure(&$0)
        }
    }

    /// Ticks at 120 Hz for `seconds` and returns the largest move in one frame.
    func largestFrameMove(_ engine: ScrollEngine, _ clock: ManualClock, for seconds: Double) -> Double {
        var largest = 0.0
        let frames = Int((seconds / Self.frame).rounded())
        for _ in 0..<frames {
            let before = engine.position
            clock.now += Self.frame
            engine.tick(now: clock.now)
            largest = max(largest, abs(engine.position - before))
        }
        return largest
    }

    @Test func voiceModeWaitsForTheReader() {
        let (engine, clock) = makeVoiceEngine()
        #expect(engine.speedLabel == "Voice")
        #expect(engine.isFollowingVoice)
        #expect(!engine.wantsVoiceInput)
        engine.start()
        #expect(engine.state == .playing)
        #expect(engine.wantsVoiceInput)
        #expect(engine.isAwaitingVoice)          // "Listening…" from the first frame
        #expect(engine.needsFrames)
        run(engine, clock, for: 3)
        #expect(engine.position == 0)
        #expect(engine.isAwaitingVoice)
    }

    @Test func easesToTheMatchedLineAndStops() {
        let (engine, clock) = makeVoiceEngine()
        engine.start()
        engine.followVoice(.character(45))       // line 2
        #expect(!engine.isAwaitingVoice)
        let largest = largestFrameMove(engine, clock, for: 0.3)
        #expect(engine.position > 0 && engine.position < 200)
        #expect(largest <= ScrollTiming.voiceMaxLinesPerSecond * 100 * Self.frame + 1e-9)
        run(engine, clock, for: 1)
        #expect(engine.position == 200)
        #expect(engine.state == .playing)
        run(engine, clock, for: 0.5)
        #expect(engine.position == 200)          // rests there
    }

    @Test func neverFasterThanFourLinesASecond() {
        let (engine, clock) = makeVoiceEngine()
        engine.start()
        engine.followVoice(.character(185))      // line 9, 900 pt away
        let started = clock.now
        let largest = largestFrameMove(engine, clock, for: 2)
        #expect(largest <= 400 * Self.frame + 1e-9)
        #expect(engine.position < 900)           // 900 pt at ≤ 400 pt/s takes more than 2.25 s
        run(engine, clock, for: 3) { $0.position == 900 }
        #expect(engine.position == 900)
        #expect(clock.now - started >= 900.0 / 400)
    }

    @Test func listeningAfterTwoSecondsWithoutANewMatch() {
        let (engine, clock) = makeVoiceEngine()
        engine.start()
        engine.followVoice(.character(25))
        run(engine, clock, for: 1.9)
        #expect(!engine.isAwaitingVoice)
        #expect(engine.position == 100)
        run(engine, clock, for: 0.2)
        #expect(engine.isAwaitingVoice)
        #expect(engine.state == .playing)

        // Speech matches again: on it goes.
        engine.followVoice(.character(65))
        #expect(!engine.isAwaitingVoice)
        run(engine, clock, for: 1)
        #expect(engine.position == 300)
    }

    @Test func pauseStopsListeningAndResumeWaitsAgain() {
        let (engine, clock) = makeVoiceEngine()
        let changes = Counter()
        engine.onVoiceChange = { changes.count += 1 }
        engine.start()
        #expect(changes.count == 1)
        engine.followVoice(.character(45))
        run(engine, clock, for: 1)
        engine.pause()
        #expect(!engine.wantsVoiceInput)
        #expect(!engine.isAwaitingVoice)
        #expect(changes.count == 2)
        engine.followVoice(.character(85))       // late words after the pause: ignored
        run(engine, clock, for: 1)
        #expect(engine.position == 200)
        engine.resume()
        #expect(engine.wantsVoiceInput)
        #expect(engine.isAwaitingVoice)
        #expect(changes.count == 3)
        run(engine, clock, for: 1)
        #expect(engine.position == 200)          // the old target is gone; it waits for new words
    }

    @Test func timeRemainingIsTheRestAtTheWPMSetting() {
        // 140 words in 14 lines at 140 wpm: a minute for the whole script, and the [pause 5] cue doesn't count.
        let layout = Self.withHolds(Self.uniform(lines: 14, words: 140), [(3, 5)])
        let (engine, clock) = makeVoiceEngine(layout: layout) { $0.wordsPerMinute = 140 }
        #expect(engine.remainingSeconds == 60)
        engine.start()
        engine.followVoice(.character(7 * 20))   // half way
        run(engine, clock, for: 3)
        #expect(engine.position == 700)
        #expect(engine.remainingSeconds == 30)
        engine.settings.wordsPerMinute = 70
        #expect(engine.remainingSeconds == 60)
    }

    @Test func speedStepsDoNothing() {
        let (engine, _) = makeVoiceEngine()
        let before = engine.settings
        engine.speedStep(5)
        engine.speedStep(-1)
        engine.setSpeed(200)
        #expect(engine.settings == before)
        #expect(engine.speedLabel == "Voice")
    }

    @Test func pauseCuesDontHoldInVoiceMode() {
        let layout = Self.withHolds(Self.uniform(lines: 10), [(3, 3)])
        let (engine, clock) = makeVoiceEngine(layout: layout)
        engine.start()
        engine.followVoice(.character(5 * 20))
        run(engine, clock, for: 2)
        #expect(engine.position == 500)
        #expect(!engine.isHolding)
        #expect(engine.holdSecondsLeft == nil)
    }

    @Test func theLastWordFinishes() {
        let (engine, clock) = makeVoiceEngine()
        let log = EventLog(engine)
        engine.start()
        engine.followVoice(.end)
        run(engine, clock, for: 5) { $0.state == .finished }
        #expect(engine.state == .finished)
        #expect(engine.position == engine.maxPosition)
        #expect(!engine.wantsVoiceInput)
        #expect(log.events == [.go, .finished])
    }

    @Test func aRelayoutKeepsTheTargetLine() {
        let (engine, clock) = makeVoiceEngine()
        engine.start()
        engine.followVoice(.character(45))
        run(engine, clock, for: 0.1)
        engine.updateLayout(Self.uniform(lines: 10, pitch: 50))   // bigger text, smaller pitch… the same characters
        run(engine, clock, for: 2)
        #expect(engine.position == 100)
    }

    @Test func aMoveByHandDropsTheTargetAndIsCounted() {
        let (engine, clock) = makeVoiceEngine()
        engine.start()
        let moves = engine.manualMoveCount
        engine.followVoice(.character(5 * 20))
        run(engine, clock, for: 0.2)
        engine.stepLine(1)
        #expect(engine.manualMoveCount != moves)
        let landed = engine.position
        run(engine, clock, for: 2)
        #expect(engine.position == landed)       // stays where the step put it until speech says otherwise
        #expect(engine.state == .playing)
        #expect(engine.readingCharacterIndex == engine.layout.characterIndex(at: landed))

        let afterStep = engine.manualMoveCount
        engine.scrub(by: 30)
        #expect(engine.manualMoveCount != afterStep)
        let afterScrub = engine.manualMoveCount
        engine.backToTop()
        #expect(engine.manualMoveCount != afterScrub)
    }

    @Test func followVoiceIsIgnoredUnlessPlaying() {
        let (engine, clock) = makeVoiceEngine { $0.countdownSeconds = 3 }
        engine.followVoice(.character(45))       // idle
        engine.start()
        engine.followVoice(.character(45))       // counting down
        run(engine, clock, for: 3.5)
        #expect(engine.state == .playing)
        #expect(engine.position == 0)
    }

    @Test func otherModesIgnoreFollowVoice() {
        let (engine, clock) = makeEngine { $0.scrollMode = .wpm }
        engine.start()
        #expect(!engine.wantsVoiceInput)
        #expect(!engine.isFollowingVoice)
        let speed = engine.pointsPerSecond
        engine.followVoice(.character(185))
        run(engine, clock, for: 1)
        #expect(abs(engine.position - speed) < 0.01)
    }

    // MARK: Falling back to WPM

    @Test func aProblemFallsBackToWPM() {
        let layout = Self.uniform(lines: 14, words: 140)
        let (engine, clock) = makeVoiceEngine(layout: layout) { $0.wordsPerMinute = 140 }
        engine.setVoiceProblem(.microphoneDenied)
        #expect(!engine.isFollowingVoice)
        #expect(engine.isVoiceMode)
        #expect(engine.speedLabel == "140 wpm")
        #expect(engine.remainingSeconds == 60)
        engine.start()
        #expect(!engine.isAwaitingVoice)
        run(engine, clock, for: 6)
        #expect(abs(engine.position - 140) < 0.01)   // 1400 pt per minute
        engine.speedStep(5)
        #expect(engine.settings.wordsPerMinute == 150)
        #expect(engine.settings.scrollMode == .voice)
        #expect(engine.speedLabel == "150 wpm")
    }

    @Test func clearingTheProblemMidTakeWaitsForTheReader() {
        let (engine, clock) = makeVoiceEngine()
        engine.setVoiceProblem(.failed)
        engine.start()
        run(engine, clock, for: 1)
        let position = engine.position
        #expect(position > 0)
        engine.setVoiceProblem(nil)
        #expect(engine.isAwaitingVoice)
        #expect(engine.speedLabel == "Voice")
        run(engine, clock, for: 1)
        #expect(engine.position == position)
    }

    @Test func switchingModesMidTake() {
        let (engine, clock) = makeEngine { $0.scrollMode = .speed }   // 100 pt/s
        let changes = Counter()
        engine.onVoiceChange = { changes.count += 1 }
        engine.start()
        run(engine, clock, for: 1)
        engine.settings.scrollMode = .voice
        #expect(changes.count == 1)
        #expect(engine.wantsVoiceInput)
        #expect(engine.isAwaitingVoice)
        let position = engine.position
        run(engine, clock, for: 1)
        #expect(engine.position == position)     // voice took over: it waits
        engine.settings.scrollMode = .speed
        #expect(changes.count == 2)
        #expect(!engine.isAwaitingVoice)
        run(engine, clock, for: 1)
        #expect(abs(engine.position - position - 100) < 0.01)
    }

    @Test func voiceEndsAHoldInProgress() {
        let layout = Self.withHolds(Self.uniform(lines: 10), [(1, 5)])
        let (engine, clock) = makeEngine(layout: layout)
        engine.start()
        run(engine, clock, for: 1.5)
        #expect(engine.isHolding)
        engine.settings.scrollMode = .voice
        #expect(!engine.isHolding)
        #expect(engine.holdSecondsLeft == nil)
    }

    // MARK: Easing (pure)

    @Test func voiceStepAcceleratesCruisesAndBrakesWithoutOvershoot() {
        var position = 0.0
        var velocity = 0.0
        var peak = 0.0
        var previousVelocity = 0.0
        var steps = 0
        while position != 1000, steps < 2000 {
            let next = ScrollTiming.voiceStep(position: position, velocity: velocity, target: 1000, dt: Self.frame, linePitch: 100)
            #expect(next.position >= position)
            #expect(next.position <= 1000)
            // Speeding up and slowing down are both gentle (until it settles on the target).
            if next.position != 1000 {
                #expect(abs(next.velocity - previousVelocity) <= 1600 * Self.frame + 1e-6)
            }
            previousVelocity = next.velocity
            position = next.position
            velocity = next.velocity
            peak = max(peak, velocity)
            steps += 1
        }
        #expect(position == 1000)
        #expect(velocity == 0)
        #expect(peak <= 400 + 1e-9)
        #expect(peak > 390)                      // a long move does reach the cap
    }

    @Test func voiceStepTurnsRoundSmoothly() {
        // Moving forward fast, the target jumps behind: it brakes first, then comes back.
        var state = (position: 500.0, velocity: 400.0)
        var positions: [Double] = []
        for _ in 0..<240 {
            state = ScrollTiming.voiceStep(position: state.position, velocity: state.velocity, target: 300, dt: Self.frame, linePitch: 100)
            positions.append(state.position)
        }
        #expect(positions[0] > 500)              // still coasting forward for a moment
        #expect(positions.last == 300)
    }

    @Test func voiceStepEdgeCases() {
        let there = ScrollTiming.voiceStep(position: 100, velocity: 0, target: 100.3, dt: Self.frame, linePitch: 100)
        #expect(there.position == 100.3)
        #expect(there.velocity == 0)
        let still = ScrollTiming.voiceStep(position: 100, velocity: 0, target: 200, dt: 0, linePitch: 100)
        #expect(still.position == 100)
        let nan = ScrollTiming.voiceStep(position: 100, velocity: .nan, target: 200, dt: Self.frame, linePitch: .nan)
        #expect(nan.position.isFinite && nan.position >= 100)
        #expect(ScrollTiming.voiceStep(position: .nan, velocity: 0, target: 200, dt: Self.frame, linePitch: 100).velocity == 0)
    }

    @Test func voiceTimingFunctions() {
        var settings = PrompterSettings()
        settings.scrollMode = .voice
        #expect(ScrollTiming.speedLabel(for: settings) == "Voice")
        #expect(ScrollTiming.settings(settings, steppedBy: 5) == settings.clamped())
        #expect(ScrollTiming.settings(settings, withSpeed: 3) == settings.clamped())
        let layout = Self.uniform(lines: 14, words: 140)
        let remaining = ScrollTiming.remainingSeconds(
            settings: settings, layout: layout, remainingDistance: 700, budget: 0, holdSeconds: 9
        )
        #expect(abs(remaining - 30) < 1e-9)     // holds don't count in voice mode
    }
}

/// A mutable count a closure can bump.
@MainActor
final class Counter {
    var count = 0
}
