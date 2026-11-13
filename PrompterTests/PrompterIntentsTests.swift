import AppIntents
import Foundation
import Testing
@testable import Prompter

@MainActor
struct PrompterIntentsTests {
    func makeHub() -> PrompterRemoteHub {
        PrompterRemoteHub(link: nil, sampleInterval: nil)
    }

    func text(_ outcome: PrompterIntentOutcome) -> String {
        String(localized: outcome.dialog)
    }

    @Test func startWithoutPrompterExplains() {
        let hub = makeHub()
        for command in [RemoteCommand.start, .pause, .resume] {
            let outcome = PrompterIntentRunner.run(command, hub: hub)
            #expect(outcome == .noPrompter)
            #expect(text(outcome) == "Tap Prompt on a script in Prompter first.")
        }
    }

    /// With no prompter there is nothing to wait for: the intent answers at once.
    @Test func performWithoutPrompterDoesNotWait() async {
        let hub = makeHub()
        hub.prompterVisibilityChanged(false)
        let started = ContinuousClock.now
        let outcome = await PrompterIntentRunner.perform(.start, hub: hub, timeout: .seconds(5))
        #expect(outcome == .noPrompter)
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    /// The system brings Prompter to the foreground to run the intent, but the scene may not be back yet: the intent
    /// waits for the prompter to be on screen, then starts it.
    @Test func performWaitsForThePrompterToComeOnScreen() async {
        let hub = makeHub()
        let (engine, _) = RemoteTestEngine.make(countdown: 3)
        hub.attach(engine: engine, scriptTitle: "Intro")
        hub.prompterVisibilityChanged(false)

        async let outcome = PrompterIntentRunner.perform(.start, hub: hub, timeout: .seconds(10))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(engine.state == .idle)          // still waiting: nothing started off screen
        hub.prompterVisibilityChanged(true)
        let result = await outcome
        #expect(result == .state(.countdown(3)))
        #expect(engine.state == .countdown(3))
    }

    /// The prompter never came on screen (the phone stayed locked): after the wait the start is refused, and the intent
    /// says so instead of claiming it started.
    @Test func performGivesUpWhenThePrompterStaysOffScreen() async {
        let hub = makeHub()
        let (engine, _) = RemoteTestEngine.make(countdown: 3)
        hub.attach(engine: engine, scriptTitle: "Intro")
        hub.prompterVisibilityChanged(false)

        let outcome = await PrompterIntentRunner.perform(.start, hub: hub, timeout: .milliseconds(50))
        #expect(outcome == .notOnScreen)
        #expect(text(outcome) == "Open Prompter, then try again.")
        #expect(engine.state == .idle)
    }

    /// Pausing needs no screen: it applies off screen too.
    @Test func pauseAppliesOffScreen() async {
        let hub = makeHub()
        let (engine, _) = RemoteTestEngine.make()
        hub.attach(engine: engine, scriptTitle: "Intro")
        engine.start()
        hub.prompterVisibilityChanged(false)
        #expect(PrompterIntentRunner.run(.pause, hub: hub) == .state(.paused))
        #expect(PrompterIntentRunner.run(.resume, hub: hub) == .notOnScreen)
        #expect(engine.state == .paused)
    }

    @Test func closingThePrompterBringsTheExplanationBack() {
        let hub = makeHub()
        let (engine, _) = RemoteTestEngine.make(countdown: 3)
        hub.attach(engine: engine, scriptTitle: "Intro")
        #expect(PrompterIntentRunner.run(.start, hub: hub) == .state(.countdown(3)))

        hub.detach(engine: engine)
        #expect(PrompterIntentRunner.run(.pause, hub: hub) == .noPrompter)
    }

    @Test func startBeginsTheCountdown() {
        let hub = makeHub()
        let (engine, _) = RemoteTestEngine.make(countdown: 3)
        hub.attach(engine: engine, scriptTitle: "Intro")

        let outcome = PrompterIntentRunner.run(.start, hub: hub)
        #expect(engine.state == .countdown(3))
        #expect(outcome == .state(.countdown(3)))
        #expect(text(outcome) == "Starting")
    }

    @Test func startWithoutACountdownPlaysAtOnce() {
        let hub = makeHub()
        let (engine, _) = RemoteTestEngine.make()
        hub.attach(engine: engine, scriptTitle: "Intro")

        let outcome = PrompterIntentRunner.run(.start, hub: hub)
        #expect(engine.state == .playing)
        #expect(text(outcome) == "Playing")
    }

    @Test func pausePausesAndResumeResumes() {
        let hub = makeHub()
        let (engine, clock) = RemoteTestEngine.make()
        hub.attach(engine: engine, scriptTitle: "Intro")
        _ = PrompterIntentRunner.run(.start, hub: hub)
        RemoteTestEngine.run(engine, clock, for: 2)
        let position = engine.position

        let paused = PrompterIntentRunner.run(.pause, hub: hub)
        #expect(engine.state == .paused)
        #expect(paused == .state(.paused))
        #expect(text(paused) == "Paused")
        RemoteTestEngine.run(engine, clock, for: 2)
        #expect(engine.position == position)

        let resumed = PrompterIntentRunner.run(.resume, hub: hub)
        #expect(engine.state == .playing)
        #expect(resumed == .state(.playing))
        #expect(text(resumed) == "Playing")
        RemoteTestEngine.run(engine, clock, for: 1)
        #expect(engine.position > position)
    }

    @Test func pauseDuringTheCountdownCancelsIt() {
        let hub = makeHub()
        let (engine, _) = RemoteTestEngine.make(countdown: 3)
        hub.attach(engine: engine, scriptTitle: "Intro")
        _ = PrompterIntentRunner.run(.start, hub: hub)

        let outcome = PrompterIntentRunner.run(.pause, hub: hub)
        #expect(engine.state == .idle)
        #expect(text(outcome) == "Ready")
    }

    @Test func everyStateHasAShortSentence() {
        let expected: [(PlaybackState, String)] = [
            (.idle, "Ready"), (.countdown(2), "Starting"), (.playing, "Playing"), (.paused, "Paused"), (.finished, "Finished"),
        ]
        for (state, sentence) in expected {
            #expect(text(.state(state)) == sentence)
        }
    }

    /// The intents themselves. Outside the system's perform flow `@Dependency` is empty (reading it would trap), so the
    /// test sets it by hand, which is what the system does from `AppDependencyManager` when it runs an intent.
    @Test func intentsActThroughTheirHub() async throws {
        let hub = makeHub()
        let (engine, _) = RemoteTestEngine.make(countdown: 3)
        hub.attach(engine: engine, scriptTitle: "Intro")

        let start = StartPrompterIntent()
        start.hub = hub
        let pause = PausePrompterIntent()
        pause.hub = hub
        let resume = ResumePrompterIntent()
        resume.hub = hub

        _ = try await start.perform()
        #expect(engine.state == .countdown(3))
        _ = try await pause.perform()
        #expect(engine.state == .idle)
        _ = try await start.perform()
        #expect(engine.state == .countdown(3))

        hub.detach(engine: engine)
        _ = try await resume.perform()
        #expect(engine.state == .countdown(3))   // the prompter is closed: nothing reaches the old engine
    }
}
