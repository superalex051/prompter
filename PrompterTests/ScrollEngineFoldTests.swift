import Foundation
import Testing
@testable import Prompter

/// A fold mid-take (iPhone Duo): the text view relays out with `anchoring: .readingPoint`. The take keeps playing, the
/// exact place at the reading line stays, and the pace keeps to its mode: the same words per minute, the same finish-in
/// time, the same lines per second.
///
/// Layouts are `uniform(...)` (no text length) or `PrompterLayoutReadingPointTests.wrapped(...)` (text length known).
@MainActor
extension ScrollEngineTests {
    @Test func readingPointRelayoutKeepsPlayingWithoutEvents() {
        // 10 lines of 100 pt with 20 characters each; the reading line is 30 % into line 4, at character 86.
        let (engine, _) = makeEngine()
        engine.scrub(by: 430)
        engine.start()
        #expect(engine.state == .playing)
        let log = EventLog(engine)
        let moves = engine.manualMoveCount

        // 150 pt lines of 12 characters: character 86 is 2 / 12 through line 7 (84…95).
        let wider = Self.uniform(lines: 20, pitch: 150, charactersPerLine: 12)
        engine.updateLayout(wider, anchoring: .readingPoint)
        #expect(engine.state == .playing)
        #expect(abs(engine.position - (7 * 150 + 2.0 / 12 * 150)) < 1e-9)
        #expect(log.events.isEmpty)
        #expect(engine.manualMoveCount == moves)
    }

    @Test func aFoldsChainOfWidthsKeepsTheCharacterAndPlays() throws {
        let (engine, clock) = makeEngine(layout: PrompterLayoutReadingPointTests.wrapped(1_000, perLine: 10))
        engine.start()
        run(engine, clock, for: 1)
        let before = try #require(engine.layout.readingPoint(at: engine.position))
        // Unfolding: three widths inside one frame, then the open one.
        for perLine in [8, 10, 21] {
            engine.updateLayout(PrompterLayoutReadingPointTests.wrapped(1_000, perLine: perLine), anchoring: .readingPoint)
        }
        #expect(engine.state == .playing)
        #expect(abs(try #require(engine.layout.readingPoint(at: engine.position)) - before) < 1e-9)
        // And it keeps moving.
        let position = engine.position
        run(engine, clock, for: 0.5)
        #expect(engine.position > position)
    }

    @Test func wpmKeepsTheWordsPerMinuteAcrossAFold() throws {
        let narrow = Self.uniform(lines: 30, pitch: 100, charactersPerLine: 20, words: 120)
        let (engine, clock) = makeEngine(layout: narrow) { $0.scrollMode = .wpm; $0.wordsPerMinute = 140 }
        engine.start()
        run(engine, clock, for: 3)
        func wordsPerMinute() -> Double {
            engine.pointsPerSecond * 60 * Double(engine.layout.wordCount) / engine.layout.timedHeight
        }
        #expect(abs(wordsPerMinute() - 140) < 1e-9)
        // Unfolded: wider lines, so fewer of them, and each holds more words.
        engine.updateLayout(Self.uniform(lines: 20, pitch: 110, charactersPerLine: 30, words: 120), anchoring: .readingPoint)
        #expect(engine.state == .playing)
        #expect(abs(wordsPerMinute() - 140) < 1e-9)
        let position = engine.position
        run(engine, clock, for: 1)
        #expect(abs(engine.position - (position + engine.pointsPerSecond)) < 0.01)
    }

    @Test func finishInKeepsTheDeadlineAcrossAFold() {
        let (engine, clock) = makeEngine(layout: Self.uniform(lines: 30)) {
            $0.scrollMode = .finishIn
            $0.finishInSeconds = 120
        }
        engine.start()
        run(engine, clock, for: 10)
        let remaining = engine.preciseRemainingSeconds
        #expect(abs(remaining - 110) < 0.05)
        engine.updateLayout(Self.uniform(lines: 22, pitch: 110, charactersPerLine: 28), anchoring: .readingPoint)
        #expect(engine.state == .playing)
        #expect(abs(engine.preciseRemainingSeconds - remaining) < 1e-6)
        let elapsed = run(engine, clock, for: 200) { $0.state == .finished }
        #expect(abs(10 + elapsed - 120) < 0.05)
    }

    @Test func speedKeepsTheLinesPerSecondAcrossAFold() {
        let (engine, clock) = makeEngine()              // speed 4: one line a second
        engine.start()
        run(engine, clock, for: 1)
        #expect(abs(engine.pointsPerSecond / engine.layout.averageLinePitch - 1) < 1e-9)
        engine.updateLayout(Self.uniform(lines: 7, pitch: 140, charactersPerLine: 29), anchoring: .readingPoint)
        #expect(abs(engine.pointsPerSecond / engine.layout.averageLinePitch - 1) < 1e-9)
    }

    @Test func aFoldDuringAHoldKeepsHolding() {
        let (engine, clock) = makeEngine(layout: Self.withHolds(Self.uniform(lines: 10), [(3, 3)]))
        engine.start()
        run(engine, clock, for: 4)              // the cue starts at character 60; 2 s of the hold left
        let bigger = Self.withHolds(Self.uniform(lines: 20, pitch: 150, charactersPerLine: 12), [(5, 3)])
        engine.updateLayout(bigger, anchoring: .readingPoint)
        #expect(engine.position == 750)
        #expect(engine.isHolding)
        #expect(engine.holdSecondsLeft == 2)
    }

    @Test func aFoldKeepsTheVoiceTarget() {
        let (engine, clock) = makeVoiceEngine()
        engine.start()
        engine.followVoice(.character(45))
        run(engine, clock, for: 0.1)
        engine.updateLayout(Self.uniform(lines: 10, pitch: 50), anchoring: .readingPoint)
        run(engine, clock, for: 2)
        #expect(engine.position == 100)
    }

    @Test func pausedStaysPausedOnTheSameCharacter() throws {
        let (engine, clock) = makeEngine(layout: PrompterLayoutReadingPointTests.wrapped(600, perLine: 15))
        engine.start()
        run(engine, clock, for: 2.3)
        engine.pause()
        let before = try #require(engine.layout.readingPoint(at: engine.position))
        engine.updateLayout(PrompterLayoutReadingPointTests.wrapped(600, perLine: 21), anchoring: .readingPoint)
        engine.updateLayout(PrompterLayoutReadingPointTests.wrapped(600, perLine: 15), anchoring: .readingPoint)
        #expect(engine.state == .paused)
        #expect(abs(try #require(engine.layout.readingPoint(at: engine.position)) - before) < 1e-9)
    }

    @Test func lineStartStaysTheDefault() {
        // The same relayout without asking for the reading point: today's line-start anchor (30 % through line 6).
        let (engine, _) = makeEngine()
        engine.scrub(by: 430)
        engine.updateLayout(Self.uniform(lines: 20, pitch: 150, charactersPerLine: 12))
        #expect(abs(engine.position - (900 + 0.3 * 150)) < 1e-9)
    }
}
