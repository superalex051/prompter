import Foundation
import Testing
@testable import Prompter

struct RemoteMessageCoderTests {
    /// What WCSession does to a message or application context: it must survive as a property list.
    static func throughPropertyList(_ message: [String: Any]) throws -> [String: Any] {
        let data = try PropertyListSerialization.data(fromPropertyList: message, format: .binary, options: 0)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(object as? [String: Any])
    }

    @Test(arguments: allRemoteCommands)
    func commandRoundTrips(_ command: RemoteCommand) throws {
        let message = RemoteMessageCoder.message(for: command)
        #expect(message.keys.sorted() == [RemoteMessageCoder.commandKey])
        #expect(RemoteMessageCoder.command(from: try Self.throughPropertyList(message)) == command)
    }

    @Test func statusRoundTrips() throws {
        let message = RemoteMessageCoder.message(for: sampleStatus)
        #expect(message.keys.sorted() == [RemoteMessageCoder.statusKey])
        #expect(RemoteMessageCoder.status(from: try Self.throughPropertyList(message)) == sampleStatus)
    }

    /// Review focus 3: a watch opened mid-take reads the phone's last application context and shows it right away.
    @Test func applicationContextRoundTrip() throws {
        var status = sampleStatus
        status.state = .playing
        let context = try Self.throughPropertyList(RemoteMessageCoder.message(for: status))
        let decoded = try #require(RemoteMessageCoder.status(from: context))
        #expect(decoded == status)
        var gate = StatusGate()
        let accepted = gate.accept(decoded)
        #expect(accepted)
        #expect(RemoteDisplayModel(status: gate.latest, isReachable: true).stateText == "Playing")
    }

    @Test func nonFiniteNumbersStillEncode() throws {
        let message = RemoteMessageCoder.message(for: RemoteCommand.setSpeed(.infinity))
        #expect(RemoteMessageCoder.command(from: try Self.throughPropertyList(message)) == .setSpeed(.infinity))

        var status = sampleStatus
        status.remainingSeconds = .infinity
        #expect(RemoteMessageCoder.status(from: RemoteMessageCoder.message(for: status)) == status)
    }

    /// Review focus 5: anything an older or newer app (or a bug) might send is ignored, never a crash.
    @Test func garbageDecodesToNil() {
        let unknownCase = Data(#"{"selfDestruct":{}}"#.utf8)
        let wrongPayload = Data(#"{"speedStep":{"_0":"fast"}}"#.utf8)
        let commandMessage = RemoteMessageCoder.message(for: RemoteCommand.start)
        let statusMessage = RemoteMessageCoder.message(for: sampleStatus)
        let garbage: [[String: Any]] = [
            [:],
            ["command": Data()],
            [RemoteMessageCoder.commandKey: "start"],
            [RemoteMessageCoder.commandKey: 42],
            [RemoteMessageCoder.commandKey: Data("not json".utf8)],
            [RemoteMessageCoder.commandKey: Data()],
            [RemoteMessageCoder.commandKey: unknownCase],
            [RemoteMessageCoder.commandKey: wrongPayload],
            statusMessage,
        ]
        for message in garbage {
            #expect(RemoteMessageCoder.command(from: message) == nil)
        }

        let missingField = Data(#"{"hasPrompter":true,"scriptTitle":"x"}"#.utf8)
        let badState = Data(
            #"{"hasPrompter":true,"scriptTitle":"x","state":{"rewinding":{}},"progress":0,"remainingSeconds":0,"speedLabel":"","sequence":1}"#.utf8
        )
        let negativeSequence = Data(
            #"{"hasPrompter":true,"scriptTitle":"x","state":{"idle":{}},"progress":0,"remainingSeconds":0,"speedLabel":"","sequence":-1}"#.utf8
        )
        let garbageStatuses: [[String: Any]] = [
            [:],
            [RemoteMessageCoder.statusKey: "playing"],
            [RemoteMessageCoder.statusKey: [1, 2, 3]],
            [RemoteMessageCoder.statusKey: Data("{".utf8)],
            [RemoteMessageCoder.statusKey: missingField],
            [RemoteMessageCoder.statusKey: badState],
            [RemoteMessageCoder.statusKey: negativeSequence],
            commandMessage,
        ]
        for message in garbageStatuses {
            #expect(RemoteMessageCoder.status(from: message) == nil)
        }
    }

    @Test func extraKeysAreIgnored() {
        var message = RemoteMessageCoder.message(for: RemoteCommand.jumpBack)
        message["fromTheFuture"] = true
        #expect(RemoteMessageCoder.command(from: message) == .jumpBack)

        let newerStatus = Data(
            #"{"hasPrompter":true,"scriptTitle":"x","state":{"paused":{}},"progress":0.5,"remainingSeconds":9,"speedLabel":"Speed 3.0","sequence":7,"mood":"great"}"#.utf8
        )
        let status = RemoteMessageCoder.status(from: [RemoteMessageCoder.statusKey: newerStatus])
        #expect(status?.state == .paused)
        #expect(status?.sequence == 7)
    }
}
