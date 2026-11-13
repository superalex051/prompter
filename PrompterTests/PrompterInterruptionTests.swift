import QuartzCore
import SwiftUI
import Testing
@testable import Prompter

/// A phone call, Siri, Control Center or the side button takes the scene out of `.active`: the take stops where it is,
/// and the watch hears about it at once.
@MainActor
struct PrompterInterruptionTests {
    private static let interruptions: [ScenePhase] = [.inactive, .background]

    /// A controller whose engine has 10 lines of 100 pt laid out; speed mode at level 4 (100 pt/s).
    private func makeController(countdown: Int) -> PrompterController {
        var settings = PrompterSettings()
        settings.countdownSeconds = countdown
        settings.scrollMode = .speed
        settings.speedLevel = 4
        let controller = PrompterController(scriptTitle: "Take", body: "One", settings: settings)
        controller.engine.updateLayout(ScrollEngineTests.uniform(lines: 10))
        return controller
    }

    @Test func anInterruptionCancelsTheCountdownAndNoGoFiresOnTheWayBack() {
        for phase in Self.interruptions {
            let controller = makeController(countdown: 5)
            let engine = controller.engine
            let log = EventLog(engine)
            engine.start()
            #expect(engine.state == .countdown(5))

            #expect(controller.sceneChanged(to: phase))
            #expect(engine.state == .idle)
            #expect(!engine.needsFrames)
            // Back in the foreground long after the countdown would have ended: the first frame changes nothing.
            #expect(!controller.sceneChanged(to: .active))
            engine.tick(now: CACurrentMediaTime() + 30)
            #expect(engine.state == .idle)
            #expect(engine.position == 0)
            #expect(log.events == [.countdownTick(5)])
        }
    }

    @Test func anInterruptionPausesPlaybackWhereItIs() {
        for phase in Self.interruptions {
            let controller = makeController(countdown: 0)
            let engine = controller.engine
            let log = EventLog(engine)
            engine.start()
            let start = CACurrentMediaTime()
            engine.tick(now: start + 0.05)
            let position = engine.position
            #expect(engine.state == .playing)

            #expect(controller.sceneChanged(to: phase))
            #expect(engine.state == .paused)
            #expect(!controller.sceneChanged(to: .active))   // coming back doesn't resume by itself
            engine.tick(now: start + 30)
            #expect(engine.state == .paused)
            #expect(engine.position == position)
            #expect(log.events == [.go, .paused])
        }
    }

    @Test func becomingActiveLeavesATakeAlone() {
        let controller = makeController(countdown: 0)
        controller.engine.start()
        #expect(!controller.sceneChanged(to: .active))
        #expect(controller.engine.state == .playing)
    }

    /// What `PrompterStage` does on an interruption: pause, then publish at once. The watch sees "Paused" in the live
    /// status and in the application context, without waiting for the push loop.
    @Test func theWatchHearsPausedStraightAway() throws {
        let link = FakeSessionLink()
        let hub = PrompterRemoteHub(link: link, sampleInterval: nil)
        hub.activate()
        link.report(reachable: true)
        let controller = makeController(countdown: 0)
        hub.attach(engine: controller.engine, scriptTitle: "Take")
        controller.engine.start()
        hub.publishStatus()
        #expect(link.contexts.last?.state == .playing)

        if controller.sceneChanged(to: .inactive) { hub.publishStatus() }
        let live = try #require(link.sent.last)
        let context = try #require(link.contexts.last)
        #expect(live.state == .paused)
        #expect(context.state == .paused)
        #expect(live.hasPrompter)
    }
}
