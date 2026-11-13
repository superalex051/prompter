import Foundation
import Testing
@testable import Prompter

/// Stands in for WCSession: records what the hub sends and lets a test play the watch.
@MainActor
final class FakeSessionLink: RemoteSessionLink {
    enum Kind: Equatable { case message, context, reply }

    private(set) var events: RemoteSessionEvents?
    private(set) var activationCount = 0
    /// Everything the phone emitted, in order.
    private(set) var log: [(kind: Kind, status: PrompterStatus)] = []

    var sent: [PrompterStatus] { log.filter { $0.kind == .message }.map(\.status) }
    var contexts: [PrompterStatus] { log.filter { $0.kind == .context }.map(\.status) }
    /// The watch acknowledges every live message at once (a fast link). Off: the test answers with `ack()` / `fail()`.
    var acknowledgesAtOnce = true
    /// Live messages waiting for the watch's answer, oldest first.
    private(set) var unanswered: [(status: PrompterStatus, ended: @MainActor @Sendable (Bool) -> Void)] = []

    func activate(events: RemoteSessionEvents) {
        activationCount += 1
        self.events = events
    }
    func send(_ status: PrompterStatus, ended: @escaping @MainActor @Sendable (Bool) -> Void) {
        log.append((.message, status))
        if acknowledgesAtOnce {
            ended(true)
        } else {
            unanswered.append((status, ended))
        }
    }
    func updateContext(_ status: PrompterStatus) { log.append((.context, status)) }

    /// The watch acknowledges the oldest unanswered live message.
    func ack() {
        guard !unanswered.isEmpty else { return }
        unanswered.removeFirst().ended(true)
    }

    /// The oldest unanswered live message fails (WatchConnectivity's error handler).
    func fail() {
        guard !unanswered.isEmpty else { return }
        unanswered.removeFirst().ended(false)
    }

    /// The session's state as the delegate would report it.
    func report(reachable: Bool, activated: Bool = true, watchAppInstalled: Bool = true) {
        events?.stateChanged(RemoteSessionState(
            isActivated: activated, isReachable: reachable, isPaired: true, isWatchAppInstalled: watchAppInstalled
        ))
    }

    /// The watch sends a command with a reply handler (nil: a message the phone couldn't read). Returns the reply when
    /// the hub answered at once (the iPhone's own prompter); a reply that comes later (the Mac's) is logged when it does.
    func receive(_ command: RemoteCommand?) -> PrompterStatus? {
        guard let events else { return nil }
        var immediate: PrompterStatus?
        var isReceiving = true
        events.commandReceived(command) { [weak self] reply in
            self?.log.append((.reply, reply))
            self?.replies.append(reply)
            if isReceiving { immediate = reply }
        }
        isReceiving = false
        return immediate
    }

    /// Every reply, in the order they were sent (later ones too).
    private(set) var replies: [PrompterStatus] = []
}

@MainActor
struct PrompterRemoteHubTests {
    func makeHub(
        reachable: Bool = true,
        sampleInterval: Duration? = nil,
        ackTimeout: Duration = PrompterRemoteHub.defaultAckTimeout
    ) -> (PrompterRemoteHub, FakeSessionLink) {
        let link = FakeSessionLink()
        let hub = PrompterRemoteHub(link: link, sampleInterval: sampleInterval, ackTimeout: ackTimeout)
        hub.activate()
        link.report(reachable: reachable)
        return (hub, link)
    }

    @Test func samplesFourTimesASecondAndGivesUpOnAnAnswerAfterThreeSeconds() {
        #expect(PrompterRemoteHub.defaultSampleInterval == .milliseconds(250))
        #expect(PrompterRemoteHub.defaultAckTimeout == .seconds(3))
    }

    @Test func activationReportsTheSessionAndReplacesTheContext() throws {
        let link = FakeSessionLink()
        let hub = PrompterRemoteHub(link: link, sampleInterval: nil)
        #expect(link.activationCount == 0)          // init alone doesn't touch the session
        hub.activate()
        hub.activate()
        #expect(link.activationCount == 1)
        #expect(!hub.isReachable)

        link.report(reachable: true)
        #expect(hub.isReachable)
        #expect(hub.isPaired)
        #expect(hub.isWatchAppInstalled)
        // Whatever an earlier run left in the application context (say "Playing") is replaced right away.
        let context = try #require(link.contexts.last)
        #expect(!context.hasPrompter)
        #expect(context.sequence > 0)
    }

    @Test func commandReachesTheEngineAndTheReplyCarriesTheFreshStatus() throws {
        let (hub, link) = makeHub()
        let (engine, _) = RemoteTestEngine.make(countdown: 3)
        hub.attach(engine: engine, scriptTitle: "Intro")

        let reply = try #require(link.receive(.start))
        #expect(engine.state == .countdown(3))
        #expect(reply.hasPrompter)
        #expect(reply.scriptTitle == "Intro")
        #expect(reply.state == .countdown(3))
        #expect(reply.progress == engine.progress)
        #expect(reply.remainingSeconds == engine.remainingSeconds)
        #expect(reply.speedLabel == "Speed 4.0")
        // A state change reaches the application context at once, not on the next tick.
        #expect(link.contexts.last?.state == .countdown(3))

        let cancelled = hub.handle(.pause)
        #expect(engine.state == .idle)
        #expect(cancelled.state == .idle)
        #expect(cancelled.sequence > reply.sequence)

        let faster = try #require(link.receive(.speedStep(5)))
        #expect(engine.settings.speedLevel == 4.5)
        #expect(faster.speedLabel == "Speed 4.5")
    }

    @Test func unreadableMessageGetsTheStatusWithoutTouchingTheEngine() throws {
        let (hub, link) = makeHub()
        let (engine, _) = RemoteTestEngine.make()
        hub.attach(engine: engine, scriptTitle: "Intro")
        let reply = try #require(link.receive(nil))
        #expect(engine.state == .idle)
        #expect(reply.hasPrompter)
        #expect(reply.state == .idle)
    }

    // MARK: Prompter off screen

    /// The phone app went to the background (or the phone locked) with the prompter open. A start from the watch used to
    /// count down invisibly, and "go" fired the moment the presenter came back. Now starting is refused until the prompter is on
    /// screen again; the reply says why.
    @Test(arguments: [RemoteCommand.start, .resume, .togglePlay])
    func startingIsRefusedWhileThePrompterIsOffScreen(_ command: RemoteCommand) throws {
        let (hub, link) = makeHub()
        let (engine, _) = RemoteTestEngine.make(countdown: 3)
        hub.attach(engine: engine, scriptTitle: "Intro")
        hub.prompterVisibilityChanged(false)
        #expect(!hub.isPrompterOnScreen)

        let reply = try #require(link.receive(command))
        #expect(engine.state == .idle)
        #expect(reply.hasPrompter)
        #expect(reply.isOnScreen == false)
        #expect(reply.state == .idle)

        hub.prompterVisibilityChanged(true)
        let started = try #require(link.receive(command))
        #expect(engine.state == .countdown(3))
        #expect(started.isOnScreen == nil)      // on screen: left out, as older phone apps sent it
    }

    @Test func resumingFromPausedIsRefusedOffScreenButPausingStillWorks() throws {
        let (hub, link) = makeHub()
        let (engine, clock) = RemoteTestEngine.make()
        hub.attach(engine: engine, scriptTitle: "Intro")
        engine.start()
        RemoteTestEngine.run(engine, clock, for: 1)
        hub.prompterVisibilityChanged(false)

        // Pausing, steps, speed and back to top need no screen.
        #expect(try #require(link.receive(.pause)).state == .paused)
        #expect(try #require(link.receive(.resume)).state == .paused)
        #expect(try #require(link.receive(.start)).state == .paused)
        #expect(try #require(link.receive(.togglePlay)).state == .paused)
        let position = engine.position
        _ = link.receive(.jumpBack)
        #expect(engine.position < position)
        _ = link.receive(.speedStep(5))
        #expect(engine.settings.speedLevel == 4.5)
        _ = link.receive(.backToTop)
        #expect(engine.state == .idle)
        #expect(engine.position == 0)
    }

    @Test func pausingAPlayingTakeOffScreenWorksThroughToggleToo() throws {
        let (hub, link) = makeHub()
        let (engine, _) = RemoteTestEngine.make(countdown: 3)
        hub.attach(engine: engine, scriptTitle: "Intro")
        _ = link.receive(.start)
        hub.prompterVisibilityChanged(false)
        // A countdown still running off screen (the screen pauses it on the way out; this is the hub on its own).
        #expect(try #require(link.receive(.togglePlay)).state == .idle)
    }

    /// The watch hears at once that the prompter left the screen, live and in the application context.
    @Test func visibilityChangesReachTheWatchAtOnce() throws {
        let (hub, link) = makeHub()
        let (engine, _) = RemoteTestEngine.make()
        hub.attach(engine: engine, scriptTitle: "Intro")
        let contextsBefore = link.contexts.count

        hub.prompterVisibilityChanged(false)
        #expect(link.sent.last?.isOnScreen == false)
        #expect(link.contexts.last?.isOnScreen == false)
        #expect(link.contexts.count == contextsBefore + 1)

        hub.prompterVisibilityChanged(true)
        #expect(link.sent.last?.isOnScreen == nil)
        #expect(link.contexts.last?.isOnScreen == nil)
        #expect(link.contexts.count == contextsBefore + 2)

        // Same again: nothing the watch shows changed, so nothing goes out.
        let sentBefore = link.sent.count
        hub.prompterVisibilityChanged(true)
        #expect(link.sent.count == sentBefore)
        #expect(link.contexts.count == contextsBefore + 2)
    }

    @Test func waitingForThePrompterEndsWhenItComesOnScreenOrTimesOut() async {
        let (hub, _) = makeHub()
        // No prompter: nothing to wait for.
        hub.prompterVisibilityChanged(false)
        var started = ContinuousClock.now
        await hub.waitUntilPrompterOnScreen(timeout: .seconds(5))
        #expect(ContinuousClock.now - started < .seconds(1))

        let (engine, _) = RemoteTestEngine.make()
        hub.attach(engine: engine, scriptTitle: "Intro")
        // Times out.
        started = ContinuousClock.now
        await hub.waitUntilPrompterOnScreen(timeout: .milliseconds(50))
        #expect(ContinuousClock.now - started >= .milliseconds(50))
        #expect(!hub.isPrompterOnScreen)

        // Ends as soon as the prompter is back, long before the timeout.
        started = ContinuousClock.now
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            hub.prompterVisibilityChanged(true)
        }
        await hub.waitUntilPrompterOnScreen(timeout: .seconds(10))
        #expect(hub.isPrompterOnScreen)
        #expect(ContinuousClock.now - started < .seconds(5))

        // Already on screen: returns at once.
        started = ContinuousClock.now
        await hub.waitUntilPrompterOnScreen(timeout: .seconds(5))
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test func withoutAPrompterCommandsAreIgnored() throws {
        let (hub, link) = makeHub()
        let reply = try #require(link.receive(.start))
        #expect(!reply.hasPrompter)
        #expect(reply.sequence > 0)
        #expect(!hub.handle(.togglePlay).hasPrompter)
    }

    @Test func contextIsPushedOnStateChangesButNotOnProgressTicks() {
        let (hub, link) = makeHub()
        let (engine, clock) = RemoteTestEngine.make()   // no countdown: start plays at once
        hub.attach(engine: engine, scriptTitle: "Intro")
        #expect(link.contexts.last?.hasPrompter == true)
        #expect(link.contexts.last?.state == .idle)

        engine.start()
        hub.publishStatus()
        let contextsWhilePlaying = link.contexts.count
        #expect(link.contexts.last?.state == .playing)

        let sentBefore = link.sent.count
        for _ in 0..<8 {
            RemoteTestEngine.run(engine, clock, for: 0.1)
            hub.publishStatus()
        }
        #expect(link.sent.count == sentBefore + 8)
        #expect(link.contexts.count == contextsWhilePlaying)
        let progress = link.sent.suffix(8).map(\.progress)
        #expect(progress == progress.sorted())
        #expect(progress.first! < progress.last!)

        engine.pause()
        hub.publishStatus()
        #expect(link.contexts.count == contextsWhilePlaying + 1)
        #expect(link.contexts.last?.state == .paused)

        engine.speedStep(5)
        hub.publishStatus()
        #expect(link.contexts.count == contextsWhilePlaying + 2)
        #expect(link.contexts.last?.speedLabel == "Speed 4.5")

        hub.publishStatus()
        #expect(link.contexts.count == contextsWhilePlaying + 2)
    }

    @Test func liveStatusIsOnlySentWhileReachable() {
        let (hub, link) = makeHub(reachable: false)
        let (engine, _) = RemoteTestEngine.make()
        hub.attach(engine: engine, scriptTitle: "Intro")
        hub.publishStatus()
        #expect(!hub.isReachable)
        #expect(link.sent.isEmpty)
        #expect(link.contexts.last?.hasPrompter == true)

        link.report(reachable: true)
        #expect(hub.isReachable)
        #expect(link.sent.count == 1)            // sent as soon as the watch is reachable
        hub.publishStatus()
        #expect(link.sent.count == 1)            // nothing changed
        engine.start()
        hub.publishStatus()
        #expect(link.sent.count == 2)
        #expect(link.sent.last?.state == .playing)
    }

    /// The M3 end-to-end failure: the phone's WCSession said the watch app wasn't installed (so never reachable) for a
    /// whole take while the watch was open. Nothing the phone sends on its own gets through then; the watch's
    /// `requestStatus` polls do, and each reply must carry the live numbers, not a stale or empty status.
    @Test func statusRequestsGetLiveNumbersWhileTheSessionCannotPush() throws {
        let link = FakeSessionLink()
        let hub = PrompterRemoteHub(link: link, sampleInterval: nil)
        hub.activate()
        link.report(reachable: false, watchAppInstalled: false)
        let (engine, clock) = RemoteTestEngine.make()
        hub.attach(engine: engine, scriptTitle: "Intro")
        #expect(!hub.isReachable)
        #expect(!hub.isWatchAppInstalled)

        let started = try #require(link.receive(.start))
        #expect(started.state == .playing)
        var replies = [started]
        for _ in 0..<4 {
            RemoteTestEngine.run(engine, clock, for: 1)
            hub.publishStatus()
            replies.append(try #require(link.receive(.requestStatus)))
        }
        #expect(link.sent.isEmpty)                       // no live messages to a watch the session can't reach
        #expect(replies.allSatisfy { $0.hasPrompter && $0.state == .playing && $0.scriptTitle == "Intro" })
        let progress = replies.map(\.progress)
        let remaining = replies.map(\.remainingSeconds)
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0 < $1 }, "progress: \(progress)")
        #expect(zip(remaining, remaining.dropFirst()).allSatisfy { $0 > $1 }, "remaining: \(remaining)")
        let sequences = replies.map(\.sequence)
        #expect(zip(sequences, sequences.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func detachPushesNoPrompter() throws {
        let (hub, link) = makeHub()
        let (engine, _) = RemoteTestEngine.make()
        hub.attach(engine: engine, scriptTitle: "Intro")
        engine.start()
        hub.publishStatus()
        let lastLive = try #require(link.sent.last)
        #expect(lastLive.state == .playing)

        hub.detach(engine: engine)
        let message = try #require(link.sent.last)
        let context = try #require(link.contexts.last)
        #expect(!message.hasPrompter)
        #expect(!context.hasPrompter)
        #expect(message.sequence > lastLive.sequence)
        #expect(context.sequence > lastLive.sequence)

        // The prompter is gone: commands no longer reach that engine.
        let reply = try #require(link.receive(.pause))
        #expect(!reply.hasPrompter)
        #expect(engine.state == .playing)
    }

    @Test func detachingAnOlderEngineKeepsTheNewOne() throws {
        let (hub, link) = makeHub()
        let (old, _) = RemoteTestEngine.make()
        let (new, _) = RemoteTestEngine.make()
        hub.attach(engine: old, scriptTitle: "Old")
        hub.attach(engine: new, scriptTitle: "New")
        let sentBefore = link.sent.count
        hub.detach(engine: old)
        #expect(link.sent.count == sentBefore)

        let reply = try #require(link.receive(.start))
        #expect(reply.scriptTitle == "New")
        #expect(new.state == .playing)
        #expect(old.state == .idle)
    }

    @Test func sequenceStrictlyIncreases() throws {
        let (hub, link) = makeHub()
        let (engine, clock) = RemoteTestEngine.make(countdown: 3)
        hub.attach(engine: engine, scriptTitle: "Intro")
        hub.publishStatus()
        _ = link.receive(.start)
        hub.publishStatus()
        _ = hub.handle(.requestStatus)
        clock.now += 3
        engine.tick(now: clock.now)
        hub.publishStatus()
        _ = link.receive(.speedStep(1))
        _ = link.receive(nil)
        hub.publishStatus()
        RemoteTestEngine.run(engine, clock, for: 1)
        hub.publishStatus()
        hub.detach(engine: engine)
        _ = link.receive(.requestStatus)

        let live = link.log.filter { $0.kind != .context }.map(\.status.sequence)
        #expect(live.count >= 9)
        #expect(zip(live, live.dropFirst()).allSatisfy { $0 < $1 }, "messages and replies: \(live)")
        let contexts = link.contexts.map(\.sequence)
        #expect(zip(contexts, contexts.dropFirst()).allSatisfy { $0 < $1 }, "contexts: \(contexts)")
        // A context reuses the sequence of the status it came with, so the whole log never goes backwards.
        let all = link.log.map(\.status.sequence)
        #expect(zip(all, all.dropFirst()).allSatisfy { $0 <= $1 }, "log: \(all)")
    }

    @Test func theHubDoesNotKeepTheEngineAlive() throws {
        let (hub, link) = makeHub(sampleInterval: .milliseconds(10))
        weak var released: ScrollEngine?
        do {
            let (engine, _) = RemoteTestEngine.make()
            hub.attach(engine: engine, scriptTitle: "Intro")
            released = engine
            #expect(released != nil)
        }
        #expect(released == nil)
        // The screen went away without detaching: the next tick reports that there is no prompter.
        hub.publishStatus()
        #expect(link.sent.last?.hasPrompter == false)
        #expect(link.contexts.last?.hasPrompter == false)
    }

    @Test func samplingLoopSendsChangesWhileAttachedAndStopsOnDetach() async throws {
        let (hub, link) = makeHub(sampleInterval: .milliseconds(10))
        let (engine, _) = RemoteTestEngine.make()
        let beforeAttach = link.sent.count
        try await Task.sleep(for: .milliseconds(60))
        #expect(link.sent.count == beforeAttach)    // nothing attached: no loop

        hub.attach(engine: engine, scriptTitle: "Intro")
        #expect(link.sent.count == beforeAttach + 1)
        try await Task.sleep(for: .milliseconds(80))
        #expect(link.sent.count == beforeAttach + 1)   // idle: the loop looks, but nothing changed

        // A change made on the phone (no command from the watch): the loop notices it and sends it.
        engine.speedStep(5)
        let deadline = ContinuousClock.now + .seconds(5)
        while link.sent.count < beforeAttach + 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(link.sent.count == beforeAttach + 2)
        #expect(link.sent.last?.speedLabel == "Speed 4.5")

        hub.detach(engine: engine)
        let afterDetach = link.sent.count
        #expect(link.sent.last?.hasPrompter == false)
        engine.speedStep(5)
        try await Task.sleep(for: .milliseconds(80))
        #expect(link.sent.count == afterDetach)
    }

    // MARK: Live messages: only on change, one in flight

    /// Before, the hub sent four messages a second whatever happened, also while idle before Start. Now a status goes
    /// out only when what the watch shows changed.
    @Test func nothingGoesOutWhileNothingChanges() throws {
        let (hub, link) = makeHub()
        let (engine, clock) = RemoteTestEngine.make()
        hub.attach(engine: engine, scriptTitle: "Intro")
        let base = link.sent.count                      // the attach status (after the one sent on reaching the watch)
        #expect(link.unanswered.count <= 1)
        for _ in 0..<20 { hub.publishStatus() }
        #expect(link.sent.count == base)                   // idle before Start

        engine.start()
        RemoteTestEngine.run(engine, clock, for: 1)
        engine.pause()
        hub.publishStatus()
        let paused = try #require(link.sent.last)
        #expect(paused.state == .paused)
        let sentWhilePaused = link.sent.count
        for _ in 0..<20 { hub.publishStatus() }
        #expect(link.sent.count == sentWhilePaused)     // paused
    }

    @Test func whilePlayingTheTimeLeftAndProgressGoOut() {
        let (hub, link) = makeHub()
        let (engine, clock) = RemoteTestEngine.make()   // 10 s of text at 100 pt/s
        hub.attach(engine: engine, scriptTitle: "Intro")
        engine.start()
        hub.publishStatus()
        let sentBefore = link.sent.count
        for _ in 0..<12 {
            RemoteTestEngine.run(engine, clock, for: 0.25)
            hub.publishStatus()
        }
        let live = link.sent.dropFirst(sentBefore)
        #expect(live.count == 12)                         // each sample moved 2.5 % here
        #expect(live.last?.remainingSeconds == engine.remainingSeconds)
        #expect(live.last?.progress == engine.progress)
    }

    /// The core of the fix: never more than one live message in flight. While one is, only the newest status waits,
    /// and it goes out the moment the watch acknowledges.
    @Test func oneMessageInFlightAndOnlyTheNewestWaits() throws {
        let (hub, link) = makeHub()
        link.acknowledgesAtOnce = false
        let (engine, clock) = RemoteTestEngine.make()
        hub.attach(engine: engine, scriptTitle: "Intro")
        let base = link.sent.count                      // the attach status (after the one sent on reaching the watch)
        #expect(link.unanswered.count <= 1)
        engine.start()
        for _ in 0..<6 {
            RemoteTestEngine.run(engine, clock, for: 0.25)
            hub.publishStatus()
        }
        #expect(link.sent.count == base)                     // the first is still on its way
        #expect(link.unanswered.count == 1)
        let newest = hub.handle(.requestStatus)

        link.ack()
        #expect(link.sent.count == base + 1)
        let second = try #require(link.sent.last)
        #expect(second.state == .playing)
        #expect(second.progress == engine.progress)      // the newest sample, not the first one after Start
        #expect(second.sequence < newest.sequence)       // (sampled before that request)
        #expect(link.unanswered.count == 1)

        link.ack()
        #expect(link.sent.count == base + 1)                     // nothing newer was waiting
        #expect(link.unanswered.isEmpty)
    }

    @Test func aFailedMessageAlsoLetsTheNewestGo() throws {
        let (hub, link) = makeHub()
        link.acknowledgesAtOnce = false
        let (engine, clock) = RemoteTestEngine.make()
        hub.attach(engine: engine, scriptTitle: "Intro")
        let base = link.sent.count
        engine.start()
        RemoteTestEngine.run(engine, clock, for: 0.5)
        hub.publishStatus()
        RemoteTestEngine.run(engine, clock, for: 0.5)
        hub.publishStatus()
        #expect(link.sent.count == base)

        link.fail()
        #expect(link.sent.count == base + 1)
        #expect(link.sent.last?.progress == engine.progress)
    }

    /// A message the watch never answers (and WatchConnectivity never fails) doesn't stop the updates for good.
    @Test func anUnansweredMessageIsGivenUpOnAfterTheTimeout() async throws {
        let (hub, link) = makeHub(ackTimeout: .milliseconds(50))
        link.acknowledgesAtOnce = false
        let (engine, _) = RemoteTestEngine.make()
        hub.attach(engine: engine, scriptTitle: "Intro")
        let base = link.sent.count
        engine.speedStep(5)
        hub.publishStatus()
        #expect(link.sent.count == base)

        let deadline = ContinuousClock.now + .seconds(5)
        while link.sent.count < base + 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(link.sent.count == base + 1)
        #expect(link.sent.last?.speedLabel == "Speed 4.5")
        // The first one's answer, late: it doesn't release a third message (nothing is waiting anyway).
        link.ack()
        #expect(link.sent.count == base + 1)
    }

    /// The application context doesn't wait for live acknowledgements: state changes reach it at once.
    @Test func contextFollowsStateChangesWhileAMessageIsInFlight() {
        let (hub, link) = makeHub()
        link.acknowledgesAtOnce = false
        let (engine, _) = RemoteTestEngine.make()
        hub.attach(engine: engine, scriptTitle: "Intro")
        let base = link.sent.count
        let contextsBefore = link.contexts.count

        engine.start()
        hub.publishStatus()
        #expect(link.contexts.count == contextsBefore + 1)
        #expect(link.contexts.last?.state == .playing)
        engine.pause()
        hub.publishStatus()
        #expect(link.contexts.count == contextsBefore + 2)
        #expect(link.contexts.last?.state == .paused)
        #expect(link.sent.count == base)                     // live still waits for the first acknowledgement
    }

    /// Out of reach, WatchConnectivity fails what was in flight; back in reach the watch gets the status at once, even
    /// one it may already have seen, and an old unanswered message doesn't hold it back.
    @Test func aWatchBackInReachGetsTheStatusAtOnce() {
        let (hub, link) = makeHub()
        link.acknowledgesAtOnce = false
        let (engine, _) = RemoteTestEngine.make()
        hub.attach(engine: engine, scriptTitle: "Intro")
        let base = link.sent.count                      // the attach status (after the one sent on reaching the watch)
        #expect(link.unanswered.count <= 1)

        link.report(reachable: false)
        link.report(reachable: true)
        #expect(link.sent.count == base + 1)
        #expect(link.sent.last?.hasPrompter == true)
        // The first message's failure, late: it releases nothing.
        link.fail()
        engine.speedStep(5)
        hub.publishStatus()
        #expect(link.sent.count == base + 1)                     // the second is in flight; the change waits for it
        link.ack()
        #expect(link.sent.count == base + 2)
        #expect(link.sent.last?.speedLabel == "Speed 4.5")
    }
}
