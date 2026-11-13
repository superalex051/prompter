import Foundation
import Observation
import Synchronization
import Testing
@testable import Prompter

// MARK: - Test support

/// A clock that only moves when a test moves it (seconds, like `CACurrentMediaTime()`).
final class ManualClock {
    var now: TimeInterval
    init(_ start: TimeInterval = 1_000) { now = start }
}

/// Records every engine event in order.
@MainActor
final class EventLog {
    private(set) var events: [ScrollEngine.Event] = []
    init(_ engine: ScrollEngine) {
        engine.onEvent = { self.events.append($0) }
    }
}

/// Set from an observation `onChange` handler.
final class ChangeFlag: Sendable {
    private let flag = Mutex(false)
    var isSet: Bool { flag.withLock { $0 } }
    func set() { flag.withLock { $0 = true } }
}

struct RemainingCase: Sendable, CustomTestStringConvertible {
    let mode: PrompterSettings.ScrollMode
    let value: Double
    let lines: Int
    let words: Int?
    let position: Double
    let expected: Double

    init(_ mode: PrompterSettings.ScrollMode, _ value: Double, lines: Int, words: Int? = nil, position: Double, expected: Double) {
        self.mode = mode
        self.value = value
        self.lines = lines
        self.words = words
        self.position = position
        self.expected = expected
    }

    var testDescription: String { "\(mode) \(value), \(lines) lines, at \(position) → \(expected) s" }
}

struct StepCase: Sendable, CustomTestStringConvertible {
    enum Action: Sendable { case line(Int), paragraph(Int), jumpBack }
    let from: Double
    let action: Action
    let expected: Double

    init(_ from: Double, _ action: Action, _ expected: Double) {
        self.from = from
        self.action = action
        self.expected = expected
    }

    var testDescription: String { "\(action) from \(from) → \(expected)" }
}

struct SpeedCase: Sendable, CustomTestStringConvertible {
    let mode: PrompterSettings.ScrollMode
    let from: Double
    let input: Double
    let expected: Double

    init(_ mode: PrompterSettings.ScrollMode, _ from: Double, _ input: Double, _ expected: Double) {
        self.mode = mode
        self.from = from
        self.input = input
        self.expected = expected
    }

    var testDescription: String { "\(mode) \(from) with \(input) → \(expected)" }
}

enum EngineSetup: String, Sendable {
    case idle, countdown, playing, paused, finished
}

enum EngineCommand: String, Sendable {
    case start, pause, resume, togglePlay, backToTop
    case lineForward, lineBack, paragraphForward, paragraphBack, jumpBack
    case scrubBegan, scrubBack
}

struct CommandCase: Sendable, CustomTestStringConvertible {
    let setup: EngineSetup
    let command: EngineCommand
    let state: PlaybackState
    let position: Double

    init(_ setup: EngineSetup, _ command: EngineCommand, _ state: PlaybackState, _ position: Double) {
        self.setup = setup
        self.command = command
        self.state = state
        self.position = position
    }

    var testDescription: String { "\(setup.rawValue) + \(command.rawValue) → \(state) at \(position)" }
}

/// The state table from the M2 plan ("Engine semantics"), on the step layout (10 lines of 100 pt, paragraphs at
/// 0, 200, 500 and 800, end at 1000) with a 3 s countdown. Every setup except `finished` starts at 250 pt (inside line 2,
/// paragraph 200); `finished` sits at the end. "scrubBack" is `scrub(by: -50)`.
private let commandTable: [CommandCase] = [
    // idle
    .init(.idle, .start, .countdown(3), 250),
    .init(.idle, .pause, .idle, 250),
    .init(.idle, .resume, .countdown(3), 250),
    .init(.idle, .togglePlay, .countdown(3), 250),
    .init(.idle, .backToTop, .idle, 0),
    .init(.idle, .lineForward, .idle, 300),
    .init(.idle, .lineBack, .idle, 200),
    .init(.idle, .paragraphForward, .idle, 500),
    .init(.idle, .paragraphBack, .idle, 200),
    .init(.idle, .jumpBack, .idle, 200),
    .init(.idle, .scrubBegan, .idle, 250),
    .init(.idle, .scrubBack, .idle, 200),
    // countdown
    .init(.countdown, .start, .countdown(3), 250),
    .init(.countdown, .pause, .idle, 250),
    .init(.countdown, .resume, .countdown(3), 250),
    .init(.countdown, .togglePlay, .idle, 250),
    .init(.countdown, .backToTop, .idle, 0),
    .init(.countdown, .lineForward, .countdown(3), 300),
    .init(.countdown, .lineBack, .countdown(3), 200),
    .init(.countdown, .paragraphForward, .countdown(3), 500),
    .init(.countdown, .paragraphBack, .countdown(3), 200),
    .init(.countdown, .jumpBack, .countdown(3), 200),
    .init(.countdown, .scrubBegan, .idle, 250),
    .init(.countdown, .scrubBack, .idle, 200),
    // playing
    .init(.playing, .start, .playing, 250),
    .init(.playing, .pause, .paused, 250),
    .init(.playing, .resume, .playing, 250),
    .init(.playing, .togglePlay, .paused, 250),
    .init(.playing, .backToTop, .idle, 0),
    .init(.playing, .lineForward, .playing, 300),
    .init(.playing, .lineBack, .playing, 200),
    .init(.playing, .paragraphForward, .playing, 500),
    .init(.playing, .paragraphBack, .playing, 200),
    .init(.playing, .jumpBack, .playing, 200),
    .init(.playing, .scrubBegan, .paused, 250),
    .init(.playing, .scrubBack, .paused, 200),
    // paused
    .init(.paused, .start, .playing, 250),
    .init(.paused, .pause, .paused, 250),
    .init(.paused, .resume, .playing, 250),
    .init(.paused, .togglePlay, .playing, 250),
    .init(.paused, .backToTop, .idle, 0),
    .init(.paused, .lineForward, .paused, 300),
    .init(.paused, .lineBack, .paused, 200),
    .init(.paused, .paragraphForward, .paused, 500),
    .init(.paused, .paragraphBack, .paused, 200),
    .init(.paused, .jumpBack, .paused, 200),
    .init(.paused, .scrubBegan, .paused, 250),
    .init(.paused, .scrubBack, .paused, 200),
    // finished (at 1000)
    .init(.finished, .start, .countdown(3), 0),
    .init(.finished, .pause, .finished, 1_000),
    .init(.finished, .resume, .countdown(3), 0),
    .init(.finished, .togglePlay, .countdown(3), 0),
    .init(.finished, .backToTop, .idle, 0),
    .init(.finished, .lineForward, .finished, 1_000),    // nothing after the end, so it stays finished
    .init(.finished, .lineBack, .paused, 900),
    .init(.finished, .paragraphForward, .finished, 1_000),
    .init(.finished, .paragraphBack, .paused, 800),
    .init(.finished, .jumpBack, .paused, 800),
    .init(.finished, .scrubBegan, .paused, 1_000),
    .init(.finished, .scrubBack, .paused, 950),
]

// MARK: - Engine

@MainActor
struct ScrollEngineTests {
    static let frame = 1.0 / 120

    /// `count` lines of `pitch` points with `charactersPerLine` UTF-16 characters each; paragraphs start at the given lines.
    static func uniform(
        lines count: Int,
        pitch: Double = 100,
        charactersPerLine: Int = 20,
        paragraphs: Set<Int> = [0],
        words: Int? = nil
    ) -> PrompterLayout {
        PrompterLayout(
            lines: (0..<count).map {
                PrompterLayout.Line(
                    y: Double($0) * pitch,
                    height: pitch,
                    characterIndex: $0 * charactersPerLine,
                    startsParagraph: paragraphs.contains($0)
                )
            },
            contentHeight: Double(count) * pitch,
            wordCount: words ?? count * 4
        )
    }

    /// 10 lines of 100 pt; paragraphs start at 0, 200, 500 and 800; the end is 1000.
    static let stepLayout = uniform(lines: 10, paragraphs: [0, 2, 5, 8])

    /// Defaults: no countdown, speed mode at level 4 (with 100 pt lines that is 100 pt/s), 10 lines of 100 pt.
    func makeEngine(
        layout: PrompterLayout = uniform(lines: 10),
        _ configure: (inout PrompterSettings) -> Void = { _ in }
    ) -> (ScrollEngine, ManualClock) {
        var settings = PrompterSettings()
        settings.countdownSeconds = 0
        settings.scrollMode = .speed
        settings.speedLevel = 4
        configure(&settings)
        let clock = ManualClock()
        let engine = ScrollEngine(settings: settings, now: { clock.now })
        engine.updateLayout(layout)
        return (engine, clock)
    }

    /// Ticks at 120 Hz for `seconds`, stopping early once `stop` is true. Returns the seconds that passed.
    @discardableResult
    func run(
        _ engine: ScrollEngine,
        _ clock: ManualClock,
        for seconds: Double,
        until stop: (ScrollEngine) -> Bool = { _ in false }
    ) -> Double {
        let start = clock.now
        let frames = max(Int((seconds / Self.frame).rounded()), 1)
        for frame in 1...frames {
            clock.now = start + Double(frame) * Self.frame
            engine.tick(now: clock.now)
            if stop(engine) { break }
        }
        return clock.now - start
    }

    // MARK: Countdown

    @Test func countdownFiresEachDigitOnceThenGo() {
        let (engine, clock) = makeEngine(layout: Self.uniform(lines: 100)) { $0.countdownSeconds = 5 }
        let log = EventLog(engine)
        let started = clock.now
        engine.start()
        #expect(engine.state == .countdown(5))
        #expect(engine.needsFrames)

        var goAfter: Double?
        run(engine, clock, for: 6) { engine in
            if goAfter == nil, engine.state == .playing { goAfter = clock.now - started }
            return false
        }
        #expect(log.events == [.countdownTick(5), .countdownTick(4), .countdownTick(3), .countdownTick(2), .countdownTick(1), .go])
        #expect(engine.state == .playing)
        #expect(abs((goAfter ?? 0) - 5) <= Self.frame + 1e-9)
        // Scrolling starts at the 5 s mark: one second at 100 pt/s since then.
        #expect(abs(engine.position - 100) < 0.01)
    }

    @Test func countdownDigitChangesOnTheSecond() {
        let (engine, clock) = makeEngine { $0.countdownSeconds = 3 }
        engine.start()
        clock.now += 0.99
        engine.tick(now: clock.now)
        #expect(engine.state == .countdown(3))
        clock.now += 0.02
        engine.tick(now: clock.now)
        #expect(engine.state == .countdown(2))
    }

    @Test func countdownZeroStartsPlayingImmediately() {
        let (engine, _) = makeEngine()
        let log = EventLog(engine)
        engine.start()
        #expect(engine.state == .playing)
        #expect(engine.needsFrames)
        #expect(log.events == [.go])
    }

    @Test func pauseDuringCountdownCancelsToIdle() {
        let (engine, clock) = makeEngine { $0.countdownSeconds = 5 }
        let log = EventLog(engine)
        engine.start()
        run(engine, clock, for: 1.5)
        engine.pause()
        #expect(engine.state == .idle)
        #expect(!engine.needsFrames)
        run(engine, clock, for: 10)
        #expect(engine.state == .idle)
        #expect(engine.position == 0)
        #expect(log.events == [.countdownTick(5), .countdownTick(4)])
    }

    /// A countdown started while nothing draws it (a remote start with the app in the background, where the display link
    /// doesn't run) used to fire "go" on the first frame back. A first frame more than a second late counts the whole
    /// countdown again from there.
    @Test func aCountdownNobodySawStartsAgainOnItsFirstFrame() {
        let (engine, clock) = makeEngine(layout: Self.uniform(lines: 100)) { $0.countdownSeconds = 5 }
        let log = EventLog(engine)
        engine.start()
        clock.now += 30                         // back on screen long after the countdown would have ended
        engine.tick(now: clock.now)
        #expect(engine.state == .countdown(5))
        #expect(engine.position == 0)
        #expect(log.events == [.countdownTick(5), .countdownTick(5)])

        let restarted = clock.now
        var goAfter: Double?
        run(engine, clock, for: 6) { engine in
            if goAfter == nil, engine.state == .playing { goAfter = clock.now - restarted }
            return false
        }
        #expect(abs((goAfter ?? 0) - 5) <= Self.frame + 1e-9)
        #expect(log.events.filter { $0 == .go }.count == 1)
    }

    /// A first frame within a second is normal (the display link wakes a frame or two later): the countdown keeps its
    /// original timing.
    @Test func aCountdownSeenWithinASecondKeepsItsTiming() {
        let (engine, clock) = makeEngine { $0.countdownSeconds = 3 }
        let log = EventLog(engine)
        engine.start()
        clock.now += 0.9
        engine.tick(now: clock.now)
        #expect(engine.state == .countdown(3))
        clock.now += 2.1                        // 3 s after start(): go
        engine.tick(now: clock.now)
        #expect(engine.state == .playing)
        #expect(log.events == [.countdownTick(3), .go])
    }

    // MARK: Modes

    @Test func speedModeScrollsAQuarterLinePerLevel() {
        let (engine, clock) = makeEngine()      // level 4, 100 pt lines
        #expect(engine.pointsPerSecond == 100)
        engine.start()
        run(engine, clock, for: 2)
        #expect(abs(engine.position - 200) < 0.01)
    }

    @Test func wpmModeReadsTheWholeScriptAtThatPace() {
        // 140 words over 1400 pt at 140 wpm: one minute.
        let (engine, clock) = makeEngine(layout: Self.uniform(lines: 14, words: 140)) {
            $0.scrollMode = .wpm
            $0.wordsPerMinute = 140
        }
        #expect(abs(engine.preciseRemainingSeconds - 60) < 1e-6)
        #expect(engine.remainingSeconds == 60)
        engine.start()
        let elapsed = run(engine, clock, for: 70) { $0.state == .finished }
        #expect(engine.state == .finished)
        #expect(abs(elapsed - 60) <= 0.1)
    }

    /// `lines` text lines of 100 pt, each followed by a 55 pt note line when `notes` (the notes carry no words): 10 words
    /// per text line.
    static func textWithNotes(lines: Int, notes: Bool) -> PrompterLayout {
        var result: [PrompterLayout.Line] = []
        var timed = Set<Int>()
        var y = 0.0
        for _ in 0..<lines {
            timed.insert(result.count)
            result.append(PrompterLayout.Line(y: y, height: 100, characterIndex: result.count * 20, startsParagraph: true))
            y += 100
            if notes {
                result.append(PrompterLayout.Line(y: y, height: 55, characterIndex: result.count * 20, startsParagraph: true))
                y += 55
            }
        }
        let timedHeight = PrompterLayout.timedHeight(of: result, contentHeight: y) { line in
            timed.contains(line.characterIndex / 20)
        }
        return PrompterLayout(lines: result, contentHeight: y, wordCount: lines * 10, timedHeight: timedHeight)
    }

    /// The WPM pace used to spread the words over the whole height, notes and cues included, so with a note under every
    /// paragraph the spoken lines went by faster than the set pace (about 158–175 wpm at 140). Now the words are spread
    /// over the text lines only: a spoken line takes as long with notes as without, and the notes add their own time.
    @Test func wpmSpokenLinesTakeTheSameTimeWithOrWithoutNotes() {
        let configure: (inout PrompterSettings) -> Void = {
            $0.scrollMode = .wpm
            $0.wordsPerMinute = 140
        }
        let (plain, plainClock) = makeEngine(layout: Self.textWithNotes(lines: 14, notes: false), configure)
        let (noted, notedClock) = makeEngine(layout: Self.textWithNotes(lines: 14, notes: true), configure)
        #expect(noted.layout.timedHeight == 1_400)
        #expect(noted.layout.contentHeight == 1_400 + 14 * 55)

        // 140 words at 140 wpm: a minute of speaking either way; 10 words (one text line) every 4.29 s.
        #expect(abs(plain.pointsPerSecond - noted.pointsPerSecond) < 1e-9)
        let perSpokenLine = 100 / noted.pointsPerSecond
        #expect(abs(perSpokenLine - 60.0 / 14) < 1e-9)

        // The time left is the truth: the plain script in a minute, the noted one a minute plus its notes' time.
        #expect(abs(plain.preciseRemainingSeconds - 60) < 1e-6)
        let notedTotal = noted.preciseRemainingSeconds
        #expect(abs(notedTotal - (60 + 14 * 55 / noted.pointsPerSecond)) < 1e-6)
        plain.start()
        noted.start()
        let plainElapsed = run(plain, plainClock, for: 200) { $0.state == .finished }
        let notedElapsed = run(noted, notedClock, for: 200) { $0.state == .finished }
        #expect(abs(plainElapsed - 60) <= 0.1)
        #expect(abs(notedElapsed - notedTotal) <= 0.1)
    }

    /// Voice mode's time estimate uses the same pace.
    @Test func voiceEstimateIgnoresNotesToo() {
        let (engine, _) = makeEngine(layout: Self.textWithNotes(lines: 14, notes: true)) {
            $0.scrollMode = .voice
            $0.wordsPerMinute = 140
        }
        #expect(abs(engine.pointsPerSecond - 1_400.0 / 60) < 1e-9)
    }

    /// Only notes and cues, no words to read: the pace used to come out as the whole height per word, so the script
    /// scrolled away in under a second. It scrolls at a calm default instead (speed level 3's 0.75 lines per second).
    @Test(arguments: [PrompterSettings.ScrollMode.wpm, .voice])
    func aScriptWithNoWordsToReadScrollsAtACalmPace(mode: PrompterSettings.ScrollMode) {
        let lines = (0..<6).map {
            PrompterLayout.Line(y: Double($0) * 55, height: 55, characterIndex: $0 * 20, startsParagraph: true)
        }
        let layout = PrompterLayout(lines: lines, contentHeight: 330, wordCount: 0, timedHeight: 0)
        let (engine, clock) = makeEngine(layout: layout) {
            $0.scrollMode = mode
            $0.wordsPerMinute = 300
        }
        #expect(abs(engine.pointsPerSecond - 0.75 * 55) < 1e-9)
        #expect(abs(engine.preciseRemainingSeconds - 8) < 1e-6)     // 6 lines at 0.75 lines per second
        guard mode == .wpm else { return }
        engine.start()
        let elapsed = run(engine, clock, for: 20) { $0.state == .finished }
        #expect(abs(elapsed - 8) <= 0.1)
    }

    @Test func finishInModeFinishesOnTime() {
        let (engine, clock) = makeEngine(layout: Self.uniform(lines: 20)) {
            $0.scrollMode = .finishIn
            $0.finishInSeconds = 120
        }
        #expect(engine.remainingSeconds == 120)
        engine.start()
        let elapsed = run(engine, clock, for: 130) { $0.state == .finished }
        #expect(engine.state == .finished)
        #expect(abs(elapsed - 120) <= 0.1)
    }

    @Test func finishInRecomputesSpeedAfterScrubbingBack() {
        let (engine, clock) = makeEngine(layout: Self.uniform(lines: 20)) {
            $0.scrollMode = .finishIn
            $0.finishInSeconds = 120
        }
        engine.start()
        run(engine, clock, for: 60)
        #expect(abs(engine.position - 1_000) < 1)
        engine.scrubBegan()
        engine.scrub(by: -1_000)                // back half the script, 60 s left
        #expect(engine.state == .paused)
        let remainingDistance = 2_000 - engine.position
        #expect(abs(engine.pointsPerSecond - remainingDistance / 60) < 0.01)
        #expect(abs(engine.preciseRemainingSeconds - 60) < 0.05)
        engine.resume()
        let elapsed = run(engine, clock, for: 70) { $0.state == .finished }
        #expect(abs(elapsed - 60) <= 0.1)
    }

    @Test func finishInCapIsAReadablePace() {
        #expect(ScrollTiming.maxFinishInLinesPerSecond <= 2.5)
        // No faster than the fastest speed-mode level.
        #expect(ScrollTiming.maxFinishInLinesPerSecond
            <= PrompterSettings.speedLevelRange.upperBound * ScrollTiming.linesPerSecondPerLevel)
        #expect(ScrollTiming.maxFinishInSpeed(for: Self.uniform(lines: 20)) == 250)
    }

    /// Scrubbing all the way back with 1 s of a 2:00 take left: 2000 pt in 1 s can't be read, so the take resumes at the
    /// pace it was set up for (the whole script in 2:00), not at the cap, and the HUD says so before it resumes.
    @Test func finishInScrubbedBackLateResumesAtTheChosenPace() {
        let (engine, clock) = makeEngine(layout: Self.uniform(lines: 20)) {
            $0.scrollMode = .finishIn
            $0.finishInSeconds = 120
        }
        engine.start()
        run(engine, clock, for: 119)
        engine.scrub(by: -5_000)                // all the way back with 1 s left
        #expect(engine.position == 0)
        #expect(engine.state == .paused)
        #expect(abs(engine.pointsPerSecond - 2_000.0 / 120) < 1e-9)   // the chosen pace, not 2000 pt/s nor the cap
        #expect(abs(engine.preciseRemainingSeconds - 120) < 1e-9)     // honest: what resuming will take
        #expect(engine.remainingSeconds == 120)
        engine.resume()
        #expect(abs(engine.pointsPerSecond - 2_000.0 / 120) < 1e-6)
        let elapsed = run(engine, clock, for: 130) { $0.state == .finished }
        #expect(abs(elapsed - 120) <= 0.1)
    }

    /// Jumping back while playing just before the deadline: it plays on at the cap (2.5 lines a second, never faster),
    /// runs past the deadline, and after a pause it resumes at the chosen pace for the rest instead of the cap.
    @Test func finishInPastTheDeadlineResumesAtAReadablePace() {
        let (engine, clock) = makeEngine(layout: Self.uniform(lines: 20)) {
            $0.scrollMode = .finishIn
            $0.finishInSeconds = 120
        }
        engine.start()
        run(engine, clock, for: 115)
        engine.jumpBack()                       // the only paragraph starts at 0: back to the top, still playing
        #expect(engine.state == .playing)
        #expect(engine.position == 0)
        #expect(engine.pointsPerSecond == 250)  // 2000 pt in 5 s would be 400 pt/s; capped at 2.5 lines of 100 pt
        #expect(abs(engine.preciseRemainingSeconds - 8) < 1e-6)       // honest: 2000 pt at 250 pt/s
        run(engine, clock, for: 5)              // the deadline passes with 750 pt to go
        #expect(engine.state == .playing)
        #expect(abs(engine.position - 1_250) < 0.01)
        #expect(engine.pointsPerSecond == 250)
        engine.pause()
        // Resuming takes the rest's share of 2:00 (750 / 2000 of it), at the pace the take was set up for.
        let share = 120 * (2_000 - engine.position) / 2_000
        #expect(abs(engine.preciseRemainingSeconds - share) < 1e-6)
        #expect(abs(engine.pointsPerSecond - 2_000.0 / 120) < 1e-6)
        engine.resume()
        #expect(abs(engine.pointsPerSecond - 2_000.0 / 120) < 1e-6)
        let elapsed = run(engine, clock, for: 60) { $0.state == .finished }
        #expect(engine.state == .finished)
        #expect(abs(elapsed - share) <= 0.1)
    }

    /// A finish-in time too short for the script: it plays at the cap from the start and says how long that takes.
    @Test func finishInImpossibleDeadlinePlaysAtTheCap() {
        let (engine, clock) = makeEngine(layout: Self.uniform(lines: 100)) {
            $0.scrollMode = .finishIn
            $0.finishInSeconds = 10
        }
        #expect(engine.remainingSeconds == 40)  // 10 000 pt at 250 pt/s, not 10 s
        engine.start()
        #expect(engine.pointsPerSecond == 250)
        #expect(engine.remainingSeconds == 40)
        let elapsed = run(engine, clock, for: 50) { $0.state == .finished }
        #expect(abs(elapsed - 40) <= 0.1)
    }

    /// A countdown started near the end, then a step back to the top before "go": playing starts at a readable pace.
    @Test func finishInGoAfterSteppingBackDuringTheCountdownIsReadable() {
        let (engine, clock) = makeEngine(layout: Self.uniform(lines: 20)) {
            $0.scrollMode = .finishIn
            $0.finishInSeconds = 120
            $0.countdownSeconds = 3
        }
        engine.scrub(by: 1_900)
        engine.start()                          // a budget of 6 s: the last 100 pt's share of 2:00
        engine.stepLine(-19)                    // back to the top during the countdown
        #expect(engine.position == 0)
        #expect(engine.state == .countdown(3))
        #expect(abs(engine.preciseRemainingSeconds - 120) < 1e-6)
        engine.tick(now: clock.now)             // the countdown's first frame
        clock.now += 3
        engine.tick(now: clock.now)
        #expect(engine.state == .playing)
        #expect(abs(engine.pointsPerSecond - 2_000.0 / 120) < 1e-6)
    }

    @Test(arguments: [
        // (budget, remaining distance, expected) on 20 lines of 100 pt (cap 250 pt/s), finish in 120 s
        (60.0, 2_000.0, 60.0),                  // 33 pt/s: kept, even though it is faster than the chosen pace
        (8.0, 2_000.0, 8.0),                    // exactly the cap: kept
        (1.0, 2_000.0, 120.0),                  // can't be met: the whole 2:00 again
        (0.0, 750.0, 45.0),                     // past the deadline: the rest's share of 2:00
        (0.0, 0.0, 0.0),                        // nothing left
    ])
    func readableBudget(budget: Double, remaining: Double, expected: Double) {
        var settings = PrompterSettings()
        settings.scrollMode = .finishIn
        settings.finishInSeconds = 120
        let result = ScrollTiming.readableBudget(
            budget, settings: settings, layout: Self.uniform(lines: 20), remainingDistance: remaining
        )
        #expect(abs(result - expected) < 1e-9)
    }

    @Test func readableBudgetNeverGoesBelowTheCap() {
        // 10 s for 10 000 pt: the share (10 s) is itself too fast, so it is the time at the cap.
        var settings = PrompterSettings()
        settings.finishInSeconds = 10
        let result = ScrollTiming.readableBudget(
            1, settings: settings, layout: Self.uniform(lines: 100), remainingDistance: 10_000
        )
        #expect(result == 40)
    }

    @Test(arguments: [
        RemainingCase(.speed, 4, lines: 10, position: 0, expected: 10),
        RemainingCase(.speed, 4, lines: 10, position: 300, expected: 7),
        RemainingCase(.speed, 4, lines: 10, position: 1_000, expected: 0),
        RemainingCase(.wpm, 140, lines: 14, words: 140, position: 0, expected: 60),
        RemainingCase(.wpm, 140, lines: 14, words: 140, position: 700, expected: 30),
        // Voice: the rest of the timed words at the WPM setting.
        RemainingCase(.voice, 140, lines: 14, words: 140, position: 0, expected: 60),
        RemainingCase(.voice, 140, lines: 14, words: 140, position: 700, expected: 30),
        RemainingCase(.finishIn, 300, lines: 10, position: 0, expected: 300),
        RemainingCase(.finishIn, 300, lines: 10, position: 500, expected: 150),
        RemainingCase(.finishIn, 300, lines: 10, position: 1_000, expected: 0),
        // 10 s for 10 000 pt is beyond the 250 pt/s cap, so it honestly says 40 s.
        RemainingCase(.finishIn, 10, lines: 100, position: 0, expected: 40),
    ])
    func timeRemainingPerMode(_ c: RemainingCase) {
        let (engine, _) = makeEngine(layout: Self.uniform(lines: c.lines, words: c.words)) {
            $0.scrollMode = c.mode
            switch c.mode {
            case .speed: $0.speedLevel = c.value
            case .wpm, .voice: $0.wordsPerMinute = c.value
            case .finishIn: $0.finishInSeconds = c.value
            }
        }
        engine.scrub(by: c.position)
        #expect(engine.state == .idle)
        #expect(abs(engine.preciseRemainingSeconds - c.expected) < 1e-6)
        #expect(engine.remainingSeconds == c.expected)
    }

    @Test func remainingSecondsRoundsUpToWholeSeconds() {
        let (engine, _) = makeEngine()          // 100 pt/s over 1000 pt
        engine.scrub(by: 50)                    // 9.5 s left
        #expect(engine.preciseRemainingSeconds == 9.5)
        #expect(engine.remainingSeconds == 10)
    }

    @Test func pauseStopsPositionAndBudget() {
        let (engine, clock) = makeEngine(layout: Self.uniform(lines: 20)) {
            $0.scrollMode = .finishIn
            $0.finishInSeconds = 120
        }
        let log = EventLog(engine)
        engine.start()
        run(engine, clock, for: 30)
        engine.pause()
        #expect(engine.state == .paused)
        #expect(!engine.needsFrames)
        let position = engine.position
        let remaining = engine.preciseRemainingSeconds
        #expect(abs(remaining - 90) < 0.05)

        clock.now += 20                         // paused a while; stray ticks must not move anything
        run(engine, clock, for: 1)
        #expect(engine.position == position)
        #expect(engine.preciseRemainingSeconds == remaining)

        engine.resume()
        #expect(engine.state == .playing)
        let elapsed = run(engine, clock, for: 100) { $0.state == .finished }
        #expect(abs(elapsed - 90) <= 0.1)
        #expect(log.events == [.go, .paused, .resumed, .finished])
    }

    @Test func largeTickGapIsClamped() {
        let (engine, clock) = makeEngine()      // 100 pt/s
        engine.start()
        clock.now += 0.05
        engine.tick(now: clock.now)
        #expect(abs(engine.position - 5) < 1e-9)
        clock.now += 3                          // a 3 s hitch (or the app was in the background)
        engine.tick(now: clock.now)
        #expect(abs(engine.position - 15) < 1e-9)
    }

    @Test func largeTickGapOnlySpendsATenthOfASecondOfBudget() {
        let (engine, clock) = makeEngine { $0.scrollMode = .finishIn; $0.finishInSeconds = 100 }
        engine.start()
        clock.now += 3
        engine.tick(now: clock.now)
        #expect(abs(engine.preciseRemainingSeconds - 99.9) < 1e-9)
    }

    @Test func clockGoingBackwardsDoesNotMoveTheText() {
        let (engine, clock) = makeEngine()
        engine.start()
        engine.tick(now: clock.now - 1)
        #expect(engine.position == 0)
        engine.tick(now: clock.now + 0.05)
        #expect(abs(engine.position - 5) < 1e-9)
    }

    @Test func reachingTheEndFinishes() {
        let (engine, clock) = makeEngine()
        let log = EventLog(engine)
        engine.start()
        run(engine, clock, for: 11) { $0.state == .finished }
        #expect(engine.state == .finished)
        #expect(engine.position == 1_000)
        #expect(engine.progress == 1)
        #expect(engine.remainingSeconds == 0)
        #expect(!engine.needsFrames)
        run(engine, clock, for: 1)              // stray ticks after the end do nothing
        #expect(log.events == [.go, .finished])
    }

    @Test func switchingToFinishInMidTakeBudgetsTheRest() {
        let (engine, clock) = makeEngine()      // speed mode, 100 pt/s over 1000 pt
        engine.start()
        run(engine, clock, for: 5)              // half way
        var settings = engine.settings
        settings.scrollMode = .finishIn
        settings.finishInSeconds = 120
        engine.settings = settings
        #expect(engine.state == .playing)
        #expect(abs(engine.preciseRemainingSeconds - 60) < 0.05)
    }

    // MARK: Steps

    @Test(arguments: [
        StepCase(0, .line(1), 100),
        StepCase(0, .line(-1), 0),
        StepCase(250, .line(1), 300),
        StepCase(250, .line(-1), 200),
        StepCase(100.3, .line(1), 200),         // within half a point of line 1 counts as on it
        StepCase(99.7, .line(1), 200),
        StepCase(100.3, .line(-1), 0),
        StepCase(950, .line(1), 1_000),         // no line starts after → the end
        StepCase(1_000, .line(1), 1_000),
        StepCase(950, .line(-1), 900),
        StepCase(250, .line(2), 400),
        StepCase(250, .line(-2), 100),
        StepCase(250, .line(0), 250),
        StepCase(250, .paragraph(1), 500),
        StepCase(250, .paragraph(-1), 200),
        StepCase(200, .paragraph(-1), 0),
        StepCase(100, .paragraph(-1), 0),
        StepCase(850, .paragraph(1), 1_000),
        StepCase(520, .jumpBack, 200),          // just after a paragraph began → the one before it
        StepCase(600, .jumpBack, 500),
        StepCase(30, .jumpBack, 0),
        StepCase(1_000, .jumpBack, 800),
    ])
    func stepTargets(_ c: StepCase) {
        let (engine, _) = makeEngine(layout: Self.stepLayout)
        engine.scrub(by: c.from)
        switch c.action {
        case .line(let n): engine.stepLine(n)
        case .paragraph(let n): engine.stepParagraph(n)
        case .jumpBack: engine.jumpBack()
        }
        #expect(engine.position == c.expected)
        #expect(engine.state == .idle)
    }

    @Test func stepsReportJumpsOnlyWhenTheyMove() {
        let (engine, _) = makeEngine(layout: Self.stepLayout)
        let log = EventLog(engine)
        engine.stepLine(-1)                     // already at the top
        engine.jumpBack()
        engine.backToTop()
        #expect(log.events.isEmpty)
        engine.stepLine(1)
        engine.stepParagraph(1)
        engine.jumpBack()
        #expect(log.events == [.jumped, .jumped, .jumped])
    }

    @Test func steppingToTheEndWhilePlayingFinishes() {
        let (engine, _) = makeEngine(layout: Self.stepLayout)
        let log = EventLog(engine)
        engine.scrub(by: 950)
        engine.start()
        engine.stepLine(1)
        #expect(engine.state == .finished)
        #expect(engine.position == 1_000)
        #expect(log.events == [.go, .jumped, .finished])
    }

    @Test func startAtTheEndWhileIdleStartsFromTheTop() {
        let (engine, _) = makeEngine()
        engine.scrub(by: 5_000)                 // idle, scrubbed to the end
        #expect(engine.position == 1_000)
        engine.start()
        #expect(engine.state == .playing)
        #expect(engine.position == 0)
    }

    @Test func startFromWhereverIdleWasLeft() {
        let (engine, clock) = makeEngine()
        engine.stepLine(1)
        engine.stepLine(1)
        engine.start()
        run(engine, clock, for: 1)
        #expect(abs(engine.position - 300) < 0.01)
    }

    @Test func backToTopResetsStateAndBudget() {
        let (engine, clock) = makeEngine(layout: Self.uniform(lines: 20)) {
            $0.scrollMode = .finishIn
            $0.finishInSeconds = 120
        }
        let log = EventLog(engine)
        engine.start()
        run(engine, clock, for: 30)
        engine.backToTop()
        #expect(engine.state == .idle)
        #expect(engine.position == 0)
        #expect(engine.progress == 0)
        #expect(engine.preciseRemainingSeconds == 120)
        #expect(engine.remainingSeconds == 120)
        #expect(log.events == [.go, .jumped])
        engine.start()
        let elapsed = run(engine, clock, for: 130) { $0.state == .finished }
        #expect(abs(elapsed - 120) <= 0.1)
    }

    // MARK: Speed steps

    @Test(arguments: [
        SpeedCase(.speed, 3, 5, 3.5),
        SpeedCase(.speed, 3, -1, 2.9),
        SpeedCase(.speed, 9.8, 5, 10),
        SpeedCase(.speed, 1.2, -5, 1),
        SpeedCase(.speed, 10, 1, 10),
        SpeedCase(.wpm, 140, 5, 150),
        SpeedCase(.wpm, 140, -1, 138),
        SpeedCase(.wpm, 296, 5, 300),
        SpeedCase(.wpm, 64, -5, 60),
        SpeedCase(.finishIn, 300, 5, 275),      // faster = shorter
        SpeedCase(.finishIn, 300, -1, 305),
        SpeedCase(.finishIn, 20, 5, 10),
        SpeedCase(.finishIn, 7_190, -5, 7_200),
        SpeedCase(.voice, 140, 5, 140),         // the reader sets the pace
        SpeedCase(.voice, 140, -5, 140),
    ])
    func speedStepPerModeIsClamped(_ c: SpeedCase) {
        let (engine, _) = makeEngine { settings in
            settings.scrollMode = c.mode
            Self.setValue(c.from, in: &settings)
        }
        engine.speedStep(Int(c.input))
        #expect(Self.value(in: engine.settings) == c.expected)
    }

    @Test(arguments: [
        SpeedCase(.speed, 3, 12, 10),
        SpeedCase(.speed, 3, 0, 1),
        SpeedCase(.speed, 3, 4.25, 4.25),
        SpeedCase(.wpm, 140, 500, 300),
        SpeedCase(.wpm, 140, 180, 180),
        SpeedCase(.finishIn, 300, 5, 10),
        SpeedCase(.finishIn, 300, 90, 90),
        SpeedCase(.speed, 3, .nan, 3),
        SpeedCase(.wpm, 140, .infinity, 140),
        SpeedCase(.voice, 140, 200, 140),
    ])
    func setSpeedSetsTheActiveModeClamped(_ c: SpeedCase) {
        let (engine, _) = makeEngine { settings in
            settings.scrollMode = c.mode
            Self.setValue(c.from, in: &settings)
        }
        engine.setSpeed(c.input)
        #expect(Self.value(in: engine.settings) == c.expected)
    }

    @Test func smallSpeedStepsLandOnExactTenths() {
        let (engine, _) = makeEngine { $0.speedLevel = 3 }
        for _ in 0..<10 { engine.speedStep(1) }
        #expect(engine.settings.speedLevel == 4)
        #expect(engine.speedLabel == "Speed 4.0")
        engine.speedStep(-3)
        #expect(engine.settings.speedLevel == 3.7)
    }

    @Test func speedStepDoesNotTouchTheOtherModes() {
        let (engine, _) = makeEngine { $0.scrollMode = .wpm }
        engine.speedStep(5)
        #expect(engine.settings.wordsPerMinute == 150)
        #expect(engine.settings.speedLevel == 4)
        #expect(engine.settings.finishInSeconds == PrompterSettings().finishInSeconds)
    }

    @Test func finishInSpeedStepScalesTheRemainingBudget() {
        let (engine, clock) = makeEngine(layout: Self.uniform(lines: 20)) {
            $0.scrollMode = .finishIn
            $0.finishInSeconds = 120
        }
        engine.start()
        run(engine, clock, for: 60)
        engine.speedStep(-2)                    // slower: 120 s → 130 s, so the remaining 60 s become 65 s
        #expect(engine.settings.finishInSeconds == 130)
        #expect(abs(engine.preciseRemainingSeconds - 65) < 0.05)
        #expect(engine.speedLabel == "Finish in 2:10")
        let elapsed = run(engine, clock, for: 70) { $0.state == .finished }
        #expect(abs(elapsed - 65) <= 0.1)
    }

    @Test(arguments: [
        (PrompterSettings.ScrollMode.speed, 3.0, "Speed 3.0"),
        (.speed, 10, "Speed 10.0"),
        (.speed, 4.25, "Speed 4.3"),
        (.wpm, 140, "140 wpm"),
        (.finishIn, 300, "Finish in 5:00"),
        (.finishIn, 3_725, "Finish in 1:02:05"),
        (.voice, 140, "Voice"),
    ])
    func speedLabelPerMode(mode: PrompterSettings.ScrollMode, value: Double, expected: String) {
        let (engine, _) = makeEngine { settings in
            settings.scrollMode = mode
            Self.setValue(value, in: &settings)
        }
        #expect(engine.speedLabel == expected)
    }

    @Test func speedLabelFollowsSettingsChanges() {
        let (engine, _) = makeEngine()
        #expect(engine.speedLabel == "Speed 4.0")
        var settings = engine.settings
        settings.scrollMode = .wpm
        settings.wordsPerMinute = 160
        engine.settings = settings
        #expect(engine.speedLabel == "160 wpm")
    }

    static func setValue(_ value: Double, in settings: inout PrompterSettings) {
        switch settings.scrollMode {
        case .speed: settings.speedLevel = value
        case .wpm, .voice: settings.wordsPerMinute = value
        case .finishIn: settings.finishInSeconds = value
        }
    }

    static func value(in settings: PrompterSettings) -> Double {
        switch settings.scrollMode {
        case .speed: settings.speedLevel
        case .wpm, .voice: settings.wordsPerMinute
        case .finishIn: settings.finishInSeconds
        }
    }

    // MARK: Relayout

    @Test func relayoutKeepsAnchorCharacter() {
        // 10 lines of 100 pt with 20 characters each; the reading line is 30 % into line 4 (characters 80…99).
        let (engine, _) = makeEngine()
        engine.scrub(by: 430)
        engine.start()
        #expect(engine.state == .playing)

        // Pinch to bigger text: 150 pt lines with 12 characters each, so character 80 now sits on line 6 (72…83).
        let bigger = Self.uniform(lines: 20, pitch: 150, charactersPerLine: 12)
        engine.updateLayout(bigger)
        #expect(engine.state == .playing)
        #expect(bigger.lineIndex(at: engine.position) == 6)
        #expect(abs(engine.position - (900 + 0.3 * 150)) < 1e-9)
        // Time remaining follows the new layout (speed mode scales with the line pitch: 150 pt/s now).
        #expect(engine.pointsPerSecond == 150)
        #expect(abs(engine.preciseRemainingSeconds - (3_000 - engine.position) / 150) < 1e-9)
        #expect(engine.progress == ((900 + 45) / 3_000 * 1_000).rounded() / 1_000)
    }

    @Test func relayoutAtTheEndStaysFinished() {
        let (engine, clock) = makeEngine(layout: Self.uniform(lines: 5)) { $0.speedLevel = 10 }
        engine.start()
        run(engine, clock, for: 5) { $0.state == .finished }
        #expect(engine.state == .finished)
        engine.updateLayout(Self.uniform(lines: 10, pitch: 150, charactersPerLine: 10))
        #expect(engine.state == .finished)
        #expect(engine.position == 1_500)
        #expect(engine.progress == 1)
        #expect(engine.remainingSeconds == 0)
    }

    @Test func aTransientEmptyLayoutKeepsThePlace() {
        let (engine, _) = makeEngine()
        engine.scrub(by: 430)
        engine.updateLayout(.empty)
        #expect(engine.position == 0)
        #expect(engine.progress == 0)
        engine.updateLayout(Self.uniform(lines: 20, pitch: 150, charactersPerLine: 12))
        #expect(abs(engine.position - 945) < 1e-9)
    }

    @Test func playingWithAnEmptyLayoutNeitherMovesNorFinishes() {
        let (engine, clock) = makeEngine()
        engine.start()
        engine.updateLayout(.empty)
        run(engine, clock, for: 1)
        #expect(engine.state == .playing)
        #expect(engine.position == 0)
    }

    // MARK: Empty and tiny scripts

    @Test(arguments: PrompterSettings.ScrollMode.allCases)
    func emptyLayoutNeverProducesNaN(mode: PrompterSettings.ScrollMode) {
        let (engine, clock) = makeEngine(layout: .empty) { $0.scrollMode = mode }
        func expectZeroes() {
            #expect(engine.position == 0)
            #expect(engine.progress == 0)
            #expect(engine.remainingSeconds == 0)
            #expect(engine.preciseRemainingSeconds == 0)
            #expect(engine.pointsPerSecond.isFinite)
            #expect(!engine.speedLabel.isEmpty)
        }
        expectZeroes()
        engine.start()
        run(engine, clock, for: 1)
        expectZeroes()
        engine.stepLine(1)
        engine.stepLine(-1)
        engine.stepParagraph(1)
        engine.stepParagraph(-1)
        engine.jumpBack()
        engine.scrubBegan()
        engine.scrub(by: 100)
        engine.scrub(by: .nan)
        engine.speedStep(5)
        engine.speedStep(-5)
        engine.setSpeed(.nan)
        engine.togglePlay()
        run(engine, clock, for: 1)
        expectZeroes()
        engine.backToTop()
        expectZeroes()
        #expect(engine.state == .idle)
    }

    @Test func oneWordScriptPlaysAndFinishes() {
        let oneLine = PrompterLayout(
            lines: [.init(y: 0, height: 115, characterIndex: 0, startsParagraph: true)],
            contentHeight: 115,
            wordCount: 1
        )
        let (engine, clock) = makeEngine(layout: oneLine) { $0.scrollMode = .wpm }
        #expect(engine.preciseRemainingSeconds.isFinite)
        engine.start()
        run(engine, clock, for: 5) { $0.state == .finished }
        #expect(engine.state == .finished)
        #expect(engine.progress == 1)
        #expect(engine.remainingSeconds == 0)
    }

    @Test func startBeforeLayoutWaits() {
        let (engine, _) = makeEngine(layout: .empty) { $0.countdownSeconds = 3 }
        let log = EventLog(engine)
        engine.start()
        #expect(engine.state == .idle)
        #expect(engine.isWaitingForLayout)
        #expect(!engine.needsFrames)
        #expect(log.events.isEmpty)
        engine.updateLayout(Self.uniform(lines: 10))
        #expect(engine.state == .countdown(3))
        #expect(!engine.isWaitingForLayout)
        #expect(log.events == [.countdownTick(3)])
    }

    @Test func pauseOrBackToTopCancelsAWaitingStart() {
        let (paused, _) = makeEngine(layout: .empty)
        paused.start()
        paused.pause()
        paused.updateLayout(Self.uniform(lines: 10))
        #expect(paused.state == .idle)

        let (reset, _) = makeEngine(layout: .empty)
        reset.start()
        reset.backToTop()
        reset.updateLayout(Self.uniform(lines: 10))
        #expect(reset.state == .idle)
    }

    // MARK: State table

    /// Puts an engine on the step layout into `setup` (see `commandTable`).
    func prepared(_ setup: EngineSetup) -> ScrollEngine {
        let (engine, clock) = makeEngine(layout: Self.stepLayout) {
            $0.countdownSeconds = 3
            $0.speedLevel = 10
        }
        engine.scrub(by: 250)
        if setup != .idle { engine.start() }
        if setup == .playing || setup == .paused || setup == .finished {
            engine.tick(now: clock.now)         // the countdown's first frame
            clock.now += 3                      // exactly the end of the countdown: playing, still at 250
            engine.tick(now: clock.now)
        }
        if setup == .paused { engine.pause() }
        if setup == .finished { run(engine, clock, for: 10) { $0.state == .finished } }
        return engine
    }

    @Test(arguments: commandTable)
    func commandsInEveryState(_ c: CommandCase) {
        let engine = prepared(c.setup)
        let expectedSetup: PlaybackState = switch c.setup {
        case .idle: .idle
        case .countdown: .countdown(3)
        case .playing: .playing
        case .paused: .paused
        case .finished: .finished
        }
        #expect(engine.state == expectedSetup)

        switch c.command {
        case .start: engine.start()
        case .pause: engine.pause()
        case .resume: engine.resume()
        case .togglePlay: engine.togglePlay()
        case .backToTop: engine.backToTop()
        case .lineForward: engine.stepLine(1)
        case .lineBack: engine.stepLine(-1)
        case .paragraphForward: engine.stepParagraph(1)
        case .paragraphBack: engine.stepParagraph(-1)
        case .jumpBack: engine.jumpBack()
        case .scrubBegan: engine.scrubBegan()
        case .scrubBack: engine.scrub(by: -50)
        }

        #expect(engine.state == c.state)
        #expect(engine.position == c.position)
        #expect(engine.needsFrames == (c.state == .playing || c.state == .countdown(3)))
    }

    // MARK: Observation budget

    @Test func ticksThatDoNotChangeTheHUDDoNotNotifyObservers() {
        // 1000 lines: one 120 Hz frame at 100 pt/s moves 0.83 pt, which changes neither the progress (to 0.001)
        // nor the whole seconds remaining.
        let (engine, clock) = makeEngine(layout: Self.uniform(lines: 1_000))
        engine.start()
        let changed = ChangeFlag()
        withObservationTracking {
            _ = engine.state
            _ = engine.progress
            _ = engine.remainingSeconds
            _ = engine.speedLabel
            _ = engine.settings
            _ = engine.layout
        } onChange: {
            changed.set()
        }
        run(engine, clock, for: Self.frame)
        #expect(engine.position > 0)
        #expect(!changed.isSet)
    }

    @Test func ticksThatChangeTheHUDNotifyObservers() {
        let (engine, clock) = makeEngine()      // 1000 pt: one frame (0.83 pt) moves the progress to 0.001
        engine.start()
        let changed = ChangeFlag()
        withObservationTracking {
            _ = engine.progress
        } onChange: {
            changed.set()
        }
        run(engine, clock, for: Self.frame)
        #expect(changed.isSet)
    }

    @Test func settingTheSameSettingsDoesNotNotify() {
        let (engine, _) = makeEngine()
        let changed = ChangeFlag()
        withObservationTracking {
            _ = engine.settings
            _ = engine.speedLabel
            _ = engine.remainingSeconds
        } onChange: {
            changed.set()
        }
        engine.settings = engine.settings
        engine.updateLayout(engine.layout)
        #expect(!changed.isSet)
    }
}

// MARK: - PlaybackState

struct PlaybackStateTests {
    @Test(arguments: [PlaybackState.idle, .countdown(3), .playing, .paused, .finished])
    func roundTripsThroughJSON(state: PlaybackState) throws {
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(PlaybackState.self, from: data) == state)
    }
}
