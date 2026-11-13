import Foundation
import Testing
@testable import Prompter

/// Stands in for the paired Mac over sync: a test sets its status and answers forwarded commands by hand.
@MainActor
final class FakeMacRelay: MacRemoteRelay {
    var macPresenterStatus: PrompterStatus?
    var isMacPaired = true
    var onMacStatusChange: () -> Void = {}
    /// Commands forwarded and not answered yet, oldest first.
    private(set) var forwarded: [(command: RemoteCommand, reply: (PrompterStatus?) -> Void)] = []

    var forwardedCommands: [RemoteCommand] { forwarded.map(\.command) }

    func forward(_ command: RemoteCommand, reply: @escaping (PrompterStatus?) -> Void) {
        forwarded.append((command, reply))
    }

    /// The Mac pushes a status (or the connection drops: nil).
    func push(_ status: PrompterStatus?) {
        macPresenterStatus = status
        onMacStatusChange()
    }

    /// The Mac answers the oldest forwarded command with `status` (nil: no answer in time); like `SyncClient`, the
    /// status is stored first.
    func answer(_ status: PrompterStatus?) {
        guard !forwarded.isEmpty else { return }
        let next = forwarded.removeFirst()
        if let status { push(status) }
        next.reply(status)
    }
}

/// A status as Prompter for Mac sends it while presenting.
func macStatus(_ state: PlaybackState = .playing, remaining: Double = 90, speed: String = "140 wpm") -> PrompterStatus {
    PrompterStatus(
        hasPrompter: true, scriptTitle: "Mac script", state: state, progress: 0.25, remainingSeconds: remaining,
        speedLabel: speed, sequence: 5, deviceName: "Sam's MacBook Pro"
    )
}

/// The Mac connected but not presenting.
func macIdleStatus() -> PrompterStatus {
    var status = PrompterStatus.noPrompter
    status.deviceName = "Sam's MacBook Pro"
    return status
}

struct RemoteTargetTests {
    @Test func anIPhonePrompterAlwaysWins() {
        for active in [true, false] {
            #expect(RemoteTarget.choose(
                hasPhonePrompter: true, macStatus: macStatus(), isMacPaired: true, isAppActive: active
            ) == .phone)
        }
    }

    @Test func aPresentingMacIsNextWhileTheAppIsInTheForeground() {
        let mac = macStatus()
        #expect(RemoteTarget.choose(hasPhonePrompter: false, macStatus: mac, isMacPaired: true, isAppActive: true)
            == .mac(mac))
    }

    @Test func inTheBackgroundTheBridgeIsDown() {
        #expect(RemoteTarget.choose(hasPhonePrompter: false, macStatus: macStatus(), isMacPaired: true, isAppActive: false)
            == .none(.phoneInBackground))
        #expect(RemoteTarget.choose(hasPhonePrompter: false, macStatus: nil, isMacPaired: true, isAppActive: false)
            == .none(.phoneInBackground))
        // No Mac paired: the background changes nothing the watch needs to know.
        #expect(RemoteTarget.choose(hasPhonePrompter: false, macStatus: nil, isMacPaired: false, isAppActive: false)
            == .none(nil))
    }

    @Test func aConnectedMacThatIsNotPresentingSuggestsEitherDevice() {
        #expect(RemoteTarget.choose(hasPhonePrompter: false, macStatus: macIdleStatus(), isMacPaired: true, isAppActive: true)
            == .none(.macConnected))
    }

    @Test func noPrompterAnywhere() {
        #expect(RemoteTarget.choose(hasPhonePrompter: false, macStatus: nil, isMacPaired: true, isAppActive: true)
            == .none(nil))
        #expect(RemoteTarget.choose(hasPhonePrompter: false, macStatus: nil, isMacPaired: false, isAppActive: true)
            == .none(nil))
    }
}

@MainActor
struct MacBridgeHubTests {
    func makeHub(mac: PrompterStatus? = nil) -> (PrompterRemoteHub, FakeSessionLink, FakeMacRelay) {
        let link = FakeSessionLink()
        let relay = FakeMacRelay()
        relay.macPresenterStatus = mac
        let hub = PrompterRemoteHub(link: link, sampleInterval: nil)
        hub.connectMac(relay)
        hub.activate()
        link.report(reachable: true)
        return (hub, link, relay)
    }

    @Test func watchCommandsGoToAPresentingMacAndTheReplyWaitsForItsAnswer() throws {
        let (hub, link, relay) = makeHub(mac: macStatus(.idle))
        #expect(hub.target == .mac(macStatus(.idle)))

        #expect(link.receive(.start) == nil, "no reply until the Mac answers")
        #expect(relay.forwardedCommands == [.start])
        let before = link.replies.count
        relay.answer(macStatus(.countdown(3)))
        #expect(link.replies.count == before + 1)
        let reply = try #require(link.replies.last)
        #expect(reply.state == .countdown(3))
        #expect(reply.deviceName == "Sam's MacBook Pro")
        #expect(reply.scriptTitle == "Mac script")
        #expect(reply.isOnScreen == nil)
        // Re-stamped with the phone's clock, so the watch's gate orders it with everything the phone sent before.
        #expect(reply.sequence > 5)
        #expect(link.contexts.last?.state == .countdown(3))
        #expect(link.contexts.last?.deviceName == "Sam's MacBook Pro")
        withExtendedLifetime(hub) {}   // the WatchConnectivity callback holds the hub weakly, as in the app
    }

    @Test func everyKindOfCommandIsForwardedInOrder() {
        let (hub, link, relay) = makeHub(mac: macStatus())
        let commands: [RemoteCommand] = [.pause, .resume, .speedStep(5), .speedStep(-1), .backToTop, .jumpBack,
                                         .togglePlay, .setSpeed(150), .start]
        for command in commands { _ = link.receive(command) }
        #expect(relay.forwardedCommands == commands)
        withExtendedLifetime(hub) {}   // the WatchConnectivity callback holds the hub weakly, as in the app
    }

    @Test func aStatusRequestIsAnsweredFromTheMacsLastPushWithoutARoundTrip() throws {
        let (hub, link, relay) = makeHub(mac: macStatus(.paused))
        let reply = try #require(link.receive(.requestStatus))
        #expect(relay.forwardedCommands.isEmpty)
        #expect(reply.state == .paused)
        #expect(reply.deviceName == "Sam's MacBook Pro")
        withExtendedLifetime(hub) {}   // the WatchConnectivity callback holds the hub weakly, as in the app
    }

    @Test func aMacThatDoesNotAnswerStillGetsTheWatchAReply() throws {
        let (hub, link, relay) = makeHub(mac: macStatus(.paused))
        _ = link.receive(.resume)
        relay.answer(nil)
        let reply = try #require(link.replies.last)
        #expect(reply.state == .paused, "the last status the Mac sent")
        withExtendedLifetime(hub) {}   // the WatchConnectivity callback holds the hub weakly, as in the app
    }

    @Test func anOpenIPhonePrompterKeepsTheWatchExactlyAsBefore() throws {
        let (hub, link, relay) = makeHub(mac: macStatus())
        let (engine, _) = RemoteTestEngine.make(countdown: 3)
        hub.attach(engine: engine, scriptTitle: "Intro")
        let reply = try #require(link.receive(.start))
        #expect(relay.forwardedCommands.isEmpty)
        #expect(engine.state == .countdown(3))
        #expect(reply.deviceName == nil)
        #expect(reply.scriptTitle == "Intro")

        // The prompter closes: the watch goes back to the Mac at once.
        hub.detach(engine: engine)
        #expect(link.sent.last?.deviceName == "Sam's MacBook Pro")
        #expect(link.contexts.last?.deviceName == "Sam's MacBook Pro")
        withExtendedLifetime(hub) {}   // the WatchConnectivity callback holds the hub weakly, as in the app
    }

    @Test func macPushesReachTheWatchOnlyWhenWhatItShowsChanges() {
        let (hub, link, relay) = makeHub(mac: macStatus(.idle))
        let sentBefore = link.sent.count
        relay.push(macStatus(.playing, remaining: 90))
        #expect(link.sent.count == sentBefore + 1)
        #expect(link.sent.last?.state == .playing)
        #expect(link.sent.last?.deviceName == "Sam's MacBook Pro")
        // The same thing again (a new Mac sequence only): nothing goes out.
        var same = macStatus(.playing, remaining: 90)
        same.sequence = 99
        relay.push(same)
        #expect(link.sent.count == sentBefore + 1)
        // A second less: out it goes.
        relay.push(macStatus(.playing, remaining: 89))
        #expect(link.sent.count == sentBefore + 2)
        withExtendedLifetime(hub) {}   // the WatchConnectivity callback holds the hub weakly, as in the app
    }

    @Test func aMacThatStopsPresentingOrDisconnectsTellsTheWatch() {
        let (hub, link, relay) = makeHub(mac: macStatus())
        relay.push(macIdleStatus())
        #expect(hub.target == .none(.macConnected))
        #expect(link.sent.last?.hasPrompter == false)
        #expect(link.sent.last?.note == .macConnected)
        #expect(RemoteDisplayModel(status: link.sent.last, isReachable: true).stateText == "Tap Prompt on your iPhone or Mac")

        // A command now isn't forwarded: nothing presents.
        _ = link.receive(.start)
        #expect(relay.forwardedCommands.isEmpty)

        relay.push(nil)
        #expect(hub.target == .none(nil))
        #expect(link.contexts.last?.note == nil)
        #expect(link.contexts.last?.hasPrompter == false)
        withExtendedLifetime(hub) {}   // the WatchConnectivity callback holds the hub weakly, as in the app
    }

    @Test func inTheBackgroundTheWatchHearsTheBridgeIsDown() throws {
        let (hub, link, relay) = makeHub(mac: macStatus())
        hub.appActivityChanged(false)
        #expect(link.contexts.last?.note == .phoneInBackground)
        let reply = try #require(link.receive(.start))
        #expect(relay.forwardedCommands.isEmpty)
        #expect(reply.note == .phoneInBackground)
        #expect(RemoteDisplayModel(status: reply, isReachable: true).stateText == "iPhone app in the background")

        hub.appActivityChanged(true)
        #expect(link.contexts.last?.deviceName == "Sam's MacBook Pro")
        withExtendedLifetime(hub) {}   // the WatchConnectivity callback holds the hub weakly, as in the app
    }

    @Test func intentsStillOnlyControlTheIPhone() {
        let (hub, _, relay) = makeHub(mac: macStatus(.idle))
        #expect(PrompterIntentRunner.run(.start, hub: hub) == .noPrompter)
        #expect(relay.forwardedCommands.isEmpty)
        withExtendedLifetime(hub) {}   // the WatchConnectivity callback holds the hub weakly, as in the app
    }
}

struct MacBridgeStatusTests {
    @Test func theDeviceAndTheNoteTravelAndAreLeftOutWhenNil() throws {
        var status = sampleStatus
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any]
        #expect(plain?["deviceName"] == nil)
        #expect(plain?["note"] == nil)

        status.deviceName = "Sam's MacBook Pro"
        status.note = .macConnected
        let decoded = try #require(RemoteMessageCoder.status(from: RemoteMessageCoder.message(for: status)))
        #expect(decoded == status)
    }

    @Test func aNoteFromANewerAppReadsAsUnknown() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(sampleStatus)) as? [String: Any])
        object["note"] = "somethingNew"
        let data = try JSONSerialization.data(withJSONObject: object)
        let status = try JSONDecoder().decode(PrompterStatus.self, from: data)
        #expect(status.note == .unknown)
        #expect(status.scriptTitle == sampleStatus.scriptTitle, "the rest of the status still reads")
        var none = PrompterStatus.noPrompter
        none.note = .unknown
        #expect(RemoteDisplayModel(status: none, isReachable: true).stateText == "Tap Prompt on your iPhone")
    }

    @Test func theWatchSaysWhichDeviceItControls() {
        let model = RemoteDisplayModel(status: macStatus(), isReachable: true)
        #expect(model.deviceText == "On Sam's MacBook Pro")
        #expect(model.controlsEnabled)
        #expect(model.stateText == "Playing")
        #expect(RemoteDisplayModel(status: sampleStatus, isReachable: true).deviceText == nil)
        // Not reachable: nothing live, no device either.
        #expect(RemoteDisplayModel(status: macStatus(), isReachable: false).deviceText == nil)
    }

    @Test func noPrompterTexts() {
        #expect(RemoteDisplayModel.noPrompterText(note: nil) == "Tap Prompt on your iPhone")
        #expect(RemoteDisplayModel.noPrompterText(note: .unknown) == "Tap Prompt on your iPhone")
        #expect(RemoteDisplayModel.noPrompterText(note: .macConnected) == "Tap Prompt on your iPhone or Mac")
        #expect(RemoteDisplayModel.noPrompterText(note: .phoneInBackground) == "iPhone app in the background")
        // Unreachable wins over any note.
        var status = PrompterStatus.noPrompter
        status.note = .macConnected
        #expect(RemoteDisplayModel(status: status, isReachable: false).stateText == "Open Prompter on your iPhone")
    }

    @Test func theLiveGateCountsTheDeviceAndTheNote() {
        var other = sampleStatus
        other.deviceName = "Mac"
        #expect(LivePushGate.showsDifferently(other, from: sampleStatus))
        var noted = PrompterStatus.noPrompter
        noted.note = .phoneInBackground
        #expect(LivePushGate.showsDifferently(noted, from: .noPrompter))
    }

    @Test func remoteForMacWords() {
        #expect(MacRemoteText.keepOpen == "Keep this open; your Apple Watch controls the Mac through this iPhone.")
        #expect(MacRemoteText.connection(status: .connected, macName: "Studio") == "Connected to Studio")
        #expect(MacRemoteText.connection(status: .searching, macName: "Studio") == "Looking for Studio…")
        #expect(MacRemoteText.watch(isReachable: true, isPaired: true) == "Apple Watch connected.")
        #expect(MacRemoteText.watch(isReachable: false, isPaired: true) == "Open Prompter on your Apple Watch.")
        #expect(MacRemoteText.watch(isReachable: false, isPaired: false) == "No Apple Watch paired with this iPhone.")
    }

    @Test func theRemoteForMacRouteParses() {
        #expect(LaunchOptions(arguments: ["-route", "macRemote"]).route == .macRemote)
        var route = LaunchRoute(route: .macRemote)
        #expect(route.next(isLoading: false, scripts: []) == .openMacRemote)
    }
}
