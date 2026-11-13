import Foundation
import Testing
@testable import Prompter

/// A real scroll engine on a hand-built layout for the remote tests.
@MainActor
enum RemoteTestEngine {
    /// 10 lines of 100 pt with paragraphs at 0, 200, 500 and 800 (the end is 1000); speed mode at level 4, which is
    /// 100 pt/s here; a `countdown`-second countdown.
    static func make(countdown: Int = 0) -> (ScrollEngine, ManualClock) {
        var settings = PrompterSettings()
        settings.countdownSeconds = countdown
        settings.scrollMode = .speed
        settings.speedLevel = 4
        let clock = ManualClock()
        let engine = ScrollEngine(settings: settings, now: { clock.now })
        let paragraphs: Set<Int> = [0, 2, 5, 8]
        engine.updateLayout(PrompterLayout(
            lines: (0..<10).map {
                PrompterLayout.Line(
                    y: Double($0) * 100,
                    height: 100,
                    characterIndex: $0 * 20,
                    startsParagraph: paragraphs.contains($0)
                )
            },
            contentHeight: 1_000,
            wordCount: 40
        ))
        return (engine, clock)
    }

    /// Ticks at 10 Hz (the engine's longest step) for `seconds`.
    static func run(_ engine: ScrollEngine, _ clock: ManualClock, for seconds: Double) {
        for _ in 0..<Int((seconds * 10).rounded()) {
            clock.now += 0.1
            engine.tick(now: clock.now)
        }
    }

    /// Playing (no countdown), `seconds` in.
    static func playing(after seconds: Double = 2.5) -> (ScrollEngine, ManualClock) {
        let (engine, clock) = make()
        engine.start()
        run(engine, clock, for: seconds)
        return (engine, clock)
    }
}

@MainActor
struct RemoteCommandRouterTests {
    @Test func startFromIdleCountsDown() {
        let (engine, _) = RemoteTestEngine.make(countdown: 3)
        RemoteCommandRouter.apply(.start, to: engine)
        #expect(engine.state == .countdown(3))
    }

    @Test func pauseAndResume() {
        let (engine, _) = RemoteTestEngine.playing()
        #expect(engine.state == .playing)
        RemoteCommandRouter.apply(.pause, to: engine)
        #expect(engine.state == .paused)
        RemoteCommandRouter.apply(.resume, to: engine)
        #expect(engine.state == .playing)
    }

    @Test func togglePlay() {
        let (engine, _) = RemoteTestEngine.playing()
        RemoteCommandRouter.apply(.togglePlay, to: engine)
        #expect(engine.state == .paused)
        RemoteCommandRouter.apply(.togglePlay, to: engine)
        #expect(engine.state == .playing)
    }

    @Test func speedStepAndSetSpeed() {
        let (engine, _) = RemoteTestEngine.make()
        RemoteCommandRouter.apply(.speedStep(5), to: engine)
        #expect(engine.settings.speedLevel == 4.5)
        #expect(engine.speedLabel == "Speed 4.5")
        RemoteCommandRouter.apply(.speedStep(-1), to: engine)
        #expect(engine.settings.speedLevel == 4.4)
        RemoteCommandRouter.apply(.setSpeed(7), to: engine)
        #expect(engine.settings.speedLevel == 7)
        RemoteCommandRouter.apply(.setSpeed(.nan), to: engine)
        #expect(engine.settings.speedLevel == 7)
    }

    @Test func backToTop() {
        let (engine, _) = RemoteTestEngine.playing()
        #expect(engine.position > 0)
        RemoteCommandRouter.apply(.backToTop, to: engine)
        #expect(engine.state == .idle)
        #expect(engine.position == 0)
    }

    @Test func jumpBackGoesToTheParagraphStart() {
        let (engine, _) = RemoteTestEngine.make()
        engine.scrub(by: 550)                   // inside the paragraph that starts at 500
        engine.start()
        RemoteCommandRouter.apply(.jumpBack, to: engine)
        #expect(engine.position == 500)
        #expect(engine.state == .playing)
    }

    @Test func requestStatusChangesNothing() {
        let (engine, _) = RemoteTestEngine.playing()
        let before = (engine.state, engine.position, engine.settings)
        RemoteCommandRouter.apply(.requestStatus, to: engine)
        #expect(engine.state == before.0)
        #expect(engine.position == before.1)
        #expect(engine.settings == before.2)
    }

    @Test func statusMirrorsTheEngine() {
        let (engine, _) = RemoteTestEngine.playing()
        let status = RemoteCommandRouter.status(engine: engine, scriptTitle: "Intro", sequence: 42)
        #expect(status == PrompterStatus(
            hasPrompter: true,
            scriptTitle: "Intro",
            state: .playing,
            progress: engine.progress,
            remainingSeconds: engine.remainingSeconds,
            speedLabel: "Speed 4.0",
            sequence: 42
        ))
        #expect(status.progress == 0.25)
        #expect(status.remainingSeconds == 8)
    }

    /// Voice mode: the watch shows "Voice", and its speed buttons and Crown change nothing.
    @Test func voiceModeShowsVoiceAndIgnoresSpeedSteps() {
        let (engine, _) = RemoteTestEngine.make()
        engine.settings.scrollMode = .voice
        let before = engine.settings
        RemoteCommandRouter.apply(.speedStep(5), to: engine)
        RemoteCommandRouter.apply(.speedStep(-1), to: engine)
        RemoteCommandRouter.apply(.setSpeed(200), to: engine)
        #expect(engine.settings == before)
        let status = RemoteCommandRouter.status(engine: engine, scriptTitle: "Intro", sequence: 1)
        #expect(status.speedLabel == "Voice")
        RemoteCommandRouter.apply(.start, to: engine)
        #expect(engine.state == .playing)
        #expect(engine.wantsVoiceInput)
    }

    /// Which commands would set the text going, and so need the prompter on screen: start and resume from idle, paused
    /// or finished, and toggling from those. Pausing (also cancelling a countdown), steps, speed and status never do.
    @Test func onlyCommandsThatSetTheTextGoingNeedTheScreen() {
        let states: [PlaybackState] = [.idle, .countdown(3), .playing, .paused, .finished]
        for state in states {
            let stopped = state == .idle || state == .paused || state == .finished
            for command in allRemoteCommands {
                let expected = switch command {
                case .start, .resume, .togglePlay: stopped
                default: false
                }
                #expect(RemoteCommandRouter.needsScreen(command, from: state) == expected, "\(command) from \(state)")
            }
        }
    }

    @Test func statusMarksAPrompterThatIsOffScreen() {
        let (engine, _) = RemoteTestEngine.make()
        #expect(RemoteCommandRouter.status(engine: engine, scriptTitle: "Intro", sequence: 1).isOnScreen == nil)
        let off = RemoteCommandRouter.status(engine: engine, scriptTitle: "Intro", sequence: 2, isOnScreen: false)
        #expect(off.isOnScreen == false)
        #expect(!off.isLive)
        #expect(off.hasPrompter)
        // No prompter: nothing to be off screen.
        #expect(RemoteCommandRouter.status(engine: nil, scriptTitle: "", sequence: 3, isOnScreen: false).isOnScreen == nil)
    }

    /// Review focus 4: the phone is on the library; commands do nothing and the status says there is no prompter.
    @Test func noEngineReturnsNoPrompterStatus() {
        for command in allRemoteCommands {
            RemoteCommandRouter.apply(command, to: nil)
        }
        let status = RemoteCommandRouter.status(engine: nil, scriptTitle: "Intro", sequence: 7)
        #expect(!status.hasPrompter)
        #expect(status.scriptTitle.isEmpty)
        #expect(status.state == .idle)
        #expect(status.sequence == 7)
        var expected = PrompterStatus.noPrompter
        expected.sequence = 7
        #expect(status == expected)
    }
}
