import Foundation
import Testing
@testable import Prompter

/// Every command the watch can send, one per case (with sample payloads).
let allRemoteCommands: [RemoteCommand] = [
    .start, .pause, .resume, .togglePlay,
    .speedStep(1), .speedStep(-5), .speedStep(0),
    .setSpeed(3.5), .setSpeed(140),
    .backToTop, .jumpBack, .requestStatus,
]

/// A status as the phone sends it mid-take.
let sampleStatus = PrompterStatus(
    hasPrompter: true,
    scriptTitle: "Episode 12 — intro",
    state: .countdown(3),
    progress: 0.42,
    remainingSeconds: 176,
    speedLabel: "140 wpm",
    sequence: 812_345_678_901
)

struct RemoteProtocolTests {
    @Test(arguments: allRemoteCommands)
    func commandRoundTripsThroughJSON(_ command: RemoteCommand) throws {
        let data = try JSONEncoder().encode(command)
        #expect(try JSONDecoder().decode(RemoteCommand.self, from: data) == command)
    }

    @Test(arguments: [PlaybackState.idle, .countdown(5), .playing, .paused, .finished])
    func statusRoundTripsThroughJSON(state: PlaybackState) throws {
        var status = sampleStatus
        status.state = state
        let data = try JSONEncoder().encode(status)
        #expect(try JSONDecoder().decode(PrompterStatus.self, from: data) == status)
    }

    /// `isOnScreen`: false travels; nil (on screen) is left out, so a status reads the same to an older watch app, and a
    /// status from an older phone app (no key) decodes as on screen.
    @Test func isOnScreenIsOptionalOnTheWire() throws {
        var offScreen = sampleStatus
        offScreen.isOnScreen = false
        let data = try JSONEncoder().encode(offScreen)
        #expect(try JSONDecoder().decode(PrompterStatus.self, from: data) == offScreen)

        let onScreenJSON = try #require(String(data: JSONEncoder().encode(sampleStatus), encoding: .utf8))
        #expect(!onScreenJSON.contains("isOnScreen"))

        let older = """
            {"hasPrompter":true,"scriptTitle":"Intro","state":{"playing":{}},"progress":0.5,"remainingSeconds":30,
            "speedLabel":"140 wpm","sequence":9}
            """
        let decoded = try JSONDecoder().decode(PrompterStatus.self, from: Data(older.utf8))
        #expect(decoded.isOnScreen == nil)
        #expect(decoded.isLive)
        #expect(decoded.state == .playing)
    }

    @Test func noPrompterIsAnEmptyIdleStatus() {
        let status = PrompterStatus.noPrompter
        #expect(!status.hasPrompter)
        #expect(status.scriptTitle.isEmpty)
        #expect(status.state == .idle)
        #expect(status.progress == 0)
        #expect(status.remainingSeconds == 0)
        #expect(status.speedLabel.isEmpty)
        #expect(status.sequence == 0)
    }

    @Test func commandsAreHashable() {
        #expect(Set(allRemoteCommands).count == allRemoteCommands.count)
    }
}
