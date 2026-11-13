import Foundation
import Network
import Testing
@testable import PrompterMac

/// A presenting session over a throwaway library and settings, for the Apple Watch remote's Mac side.
@MainActor
final class RemoteSessionFixture {
    let directory: URL
    let suite: String
    let scriptStore: ScriptStore
    let settingsStore: SettingsStore
    let session: PresenterSession

    init(countdown: Int = 0) throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "MacRemoteTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scriptStore = ScriptStore(directory: directory, initialScripts: { _ in [] })
        let script = scriptStore.create(
            title: "Mac take",
            body: Array(repeating: "One two three four five six seven.", count: 30).joined(separator: "\n\n")
        )
        suite = "MacRemoteTests-\(UUID().uuidString)"
        settingsStore = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        settingsStore.settings.countdownSeconds = countdown
        session = PresenterSession(
            scriptID: script.id, scriptStore: scriptStore, settingsStore: settingsStore,
            outputScreenSize: CGSize(width: 1920, height: 1080)
        )
        session.isMuted = true
        // The layout an output canvas of that size would hand the engine.
        let style = PrompterTextStyle(settings: session.settings, canvasSize: session.outputScreenSize, isPad: true)
        session.engine.updateLayout(PrompterLayoutExtractor.layout(of: session.document, style: style))
    }

    func cleanUp() {
        session.close()
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}

/// `MacRemoteControl`: watch commands reach the Mac's prompter through `PresenterSession`, only while presenting.
@MainActor
struct MacRemoteControlTests {
    @Test func whilePresentingCommandsGoThroughTheSession() throws {
        let fixture = try RemoteSessionFixture()
        defer { fixture.cleanUp() }
        var published: [PrompterStatus] = []
        let remote = MacRemoteControl(
            deviceName: "Test Mac", session: { fixture.session }, publish: { published.append($0) }, sampleInterval: nil
        )
        let engine = fixture.session.engine

        let started = remote.handle(.start)
        #expect(engine.state == .playing, "no countdown set")
        #expect(started.state == .playing)
        #expect(started.hasPrompter)
        #expect(started.scriptTitle == "Mac take")
        #expect(started.deviceName == "Test Mac")
        #expect(started.isOnScreen == nil, "the Mac's prompter is on screen while it presents")
        #expect(published.last == started, "the answer goes to the other iPhones too")

        #expect(remote.handle(.pause).state == .paused)
        #expect(remote.handle(.resume).state == .playing)
        #expect(remote.handle(.togglePlay).state == .paused)

        // Speed steps are saved, like the Presenter view's.
        let before = fixture.settingsStore.settings.wordsPerMinute
        let faster = remote.handle(.speedStep(5))
        #expect(fixture.settingsStore.settings.wordsPerMinute == before + 10)
        #expect(faster.speedLabel == engine.speedLabel)
        _ = remote.handle(.setSpeed(200))
        #expect(fixture.settingsStore.settings.wordsPerMinute == 200)

        _ = remote.handle(.backToTop)
        #expect(engine.state == .idle)
        #expect(fixture.session.elapsedSeconds == 0)

        let sequence = remote.handle(.requestStatus).sequence
        #expect(remote.handle(.requestStatus).sequence > sequence)
    }

    @Test func resumeOnlyResumes() throws {
        let fixture = try RemoteSessionFixture()
        defer { fixture.cleanUp() }
        let remote = MacRemoteControl(deviceName: "Test Mac", session: { fixture.session }, publish: { _ in },
                                      sampleInterval: nil)
        #expect(remote.handle(.resume).state == .idle, "resuming from idle would start a take nobody started")
    }

    @Test func aCountdownStartsAndCancels() throws {
        let fixture = try RemoteSessionFixture(countdown: 3)
        defer { fixture.cleanUp() }
        let remote = MacRemoteControl(deviceName: "Test Mac", session: { fixture.session }, publish: { _ in },
                                      sampleInterval: nil)
        #expect(remote.handle(.start).state == .countdown(3))
        #expect(remote.handle(.pause).state == .idle)
    }

    @Test func withoutPresentingNothingHappensAndTheAnswerSaysSo() throws {
        let fixture = try RemoteSessionFixture()
        defer { fixture.cleanUp() }
        var published: [PrompterStatus] = []
        let remote = MacRemoteControl(deviceName: "Test Mac", session: { nil }, publish: { published.append($0) },
                                      sampleInterval: nil)
        for command in [RemoteCommand.start, .resume, .togglePlay, .speedStep(5), .backToTop] {
            let status = remote.handle(command)
            #expect(!status.hasPrompter)
            #expect(status.deviceName == "Test Mac")
        }
        #expect(fixture.session.engine.state == .idle, "the session nobody presents is untouched")
        #expect(published.isEmpty)
    }

    @Test func presentingChangesArePublishedAtOnce() throws {
        let fixture = try RemoteSessionFixture()
        defer { fixture.cleanUp() }
        var current: PresenterSession? = fixture.session
        var published: [PrompterStatus] = []
        let remote = MacRemoteControl(deviceName: "Test Mac", session: { current }, publish: { published.append($0) },
                                      sampleInterval: nil)
        remote.presentingChanged()
        #expect(published.last?.hasPrompter == true)
        current = nil
        remote.presentingChanged()
        #expect(published.last?.hasPrompter == false)
    }
}

/// The real thing over TLS on 127.0.0.1: a `SyncHost` with a `MacRemoteControl` over a presenting session, and a
/// `SyncClient` (the iPhone's side), as `SyncLoopbackTests` does for scripts.
@MainActor
@Suite(.serialized)
final class RemoteLoopbackTests {
    let mac: StoreFixture
    let phone: StoreFixture
    let host: SyncHost
    let client: SyncClient
    let presenting: RemoteSessionFixture
    var isPresenting = true
    var remote: MacRemoteControl!
    nonisolated let directories: [URL]

    init() throws {
        mac = try StoreFixture()
        phone = try StoreFixture()
        let macPairing = try makeSyncTestDirectory()
        let phonePairing = try makeSyncTestDirectory()
        directories = [mac.directory, phone.directory, macPairing, phonePairing]
        host = SyncHost(library: mac.store, pairing: PairingStore(directory: macPairing), name: "Test Mac", advertises: false)
        client = SyncClient(library: phone.store, pairing: PairingStore(directory: phonePairing), name: "Test iPhone")
        presenting = try RemoteSessionFixture()
        remote = MacRemoteControl(
            deviceName: host.name,
            session: { [unowned self] in self.isPresenting ? self.presenting.session : nil },
            publish: { [weak host] in host?.publishPresenterStatus($0) },
            sampleInterval: nil
        )
        host.remoteHandler = { [unowned self] in self.remote.handle($0) }
        host.presenterStatusProvider = { [unowned self] in self.remote.status() }
    }

    deinit {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
    }

    @discardableResult
    private func waitUntil(_ timeout: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition() {
            if Date.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func pairAndConnect() async throws {
        host.start()
        host.beginPairing(code: "123456789012")
        let ready = await waitUntil { if case .advertising = host.listenerState { true } else { false } }
        try #require(ready, "the listener should start")
        guard case .advertising(let port) = host.listenerState else { return }
        client.directEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        client.autoPairCode = "123456789012"
        client.setActive(true)
        let connected = await waitUntil { client.status == .connected && !host.connectedDeviceIDs.isEmpty }
        try #require(connected, "paired and connected (status \(client.status))")
    }

    private func shutDown() {
        client.setActive(false)
        host.stop()
        presenting.cleanUp()
    }

    /// Sends a command and waits for the Mac's answer.
    private func send(_ command: RemoteCommand) async -> PrompterStatus? {
        var answer: PrompterStatus??
        client.sendRemote(command) { answer = .some($0) }
        await waitUntil { answer != nil }
        return answer ?? nil
    }

    @Test func aCommandReachesTheMacsPrompterAndItsStatusComesBack() async throws {
        defer { shutDown() }
        try await pairAndConnect()

        // Connecting asks for the Mac's status, which comes at once.
        #expect(await waitUntil { client.presenterStatus != nil })
        #expect(client.presenterStatus?.hasPrompter == true)
        #expect(client.presenterStatus?.deviceName == "Test Mac")
        #expect(host.hasPresenterSubscribers)

        let sent = ContinuousClock.now
        let started = await send(.start)
        let roundTrip = ContinuousClock.now - sent
        #expect(started?.state == .playing)
        #expect(presenting.session.engine.state == .playing)
        #expect(roundTrip < .seconds(1), "round trip \(roundTrip)")

        let faster = await send(.speedStep(5))
        #expect(faster?.speedLabel == presenting.session.engine.speedLabel)

        // A change made on the Mac (the space bar) reaches the iPhone as a push.
        presenting.session.pause()
        remote.publishNow()
        #expect(await waitUntil { client.presenterStatus?.state == .paused })

        // Stopping presenting: the iPhone hears there's nothing to control, and commands change nothing.
        isPresenting = false
        remote.presentingChanged()
        #expect(await waitUntil { client.presenterStatus?.hasPrompter == false })
        let refused = await send(.start)
        #expect(refused?.hasPrompter == false)
        #expect(presenting.session.engine.state == .paused)
    }

    @Test func pushesGoOutOnlyWhenWhatTheWatchShowsChanges() async throws {
        defer { shutDown() }
        try await pairAndConnect()
        #expect(await waitUntil { client.presenterStatus != nil })
        var changes = 0
        client.onPresenterStatusChange = { changes += 1 }

        // Nothing moved: publishing again and again sends nothing.
        for _ in 0..<5 { remote.publishNow() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(changes == 0)

        // Something moved: one push.
        presenting.session.speedStep(5)
        remote.publishNow()
        remote.publishNow()
        #expect(await waitUntil { changes >= 1 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(changes == 1)
    }

    @Test func anIPhoneThatDidNotAskGetsNoPushes() async throws {
        defer { shutDown() }
        client.subscribesToPresenter = false
        try await pairAndConnect()
        presenting.session.speedStep(5)
        remote.publishNow()
        try await Task.sleep(for: .milliseconds(400))
        #expect(client.presenterStatus == nil)
        #expect(!host.hasPresenterSubscribers)
        // Commands still get their answer.
        #expect(await send(.start)?.state == .playing)
    }

    @Test func thePairingConnectionCannotSendCommands() async throws {
        defer { shutDown() }
        host.start()
        host.beginPairing(code: "123456789012")
        #expect(await waitUntil { if case .advertising = host.listenerState { true } else { false } })
        guard case .advertising(let port) = host.listenerState else { return }
        // Someone who knows the code but hasn't paired (no session): a remote command is ignored.
        let stranger = SyncConnection(
            to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
            keys: [SyncTransport.PresharedKey(identity: SyncPairing.pairingIdentity, key: SyncPairing.pairingKey(code: "123456789012"))]
        )
        var answers: [SyncMessage] = []
        stranger.onMessage = { answers.append($0) }
        stranger.onReady = { [weak stranger] in
            stranger?.send(.remoteSubscribe(true))
            stranger?.send(.remote(.start, id: 1))
        }
        stranger.start()
        try await Task.sleep(for: .milliseconds(600))
        #expect(answers.isEmpty)
        #expect(presenting.session.engine.state == .idle)
        stranger.cancel()
    }

    @Test func aDisconnectEndsWaitingCommandsAndForgetsTheStatus() async throws {
        defer { shutDown() }
        try await pairAndConnect()
        #expect(await waitUntil { client.presenterStatus != nil })
        client.setActive(false)
        #expect(client.presenterStatus == nil)
        var answer: PrompterStatus??
        client.sendRemote(.start) { answer = .some($0) }
        #expect(answer == .some(nil), "not connected: answered nil at once")
    }
}
