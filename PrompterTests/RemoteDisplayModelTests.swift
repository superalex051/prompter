import Foundation
import Testing
@testable import Prompter

struct DisplayCase: Sendable, CustomTestStringConvertible {
    let state: PlaybackState
    let isReachable: Bool
    let hasPrompter: Bool

    var testDescription: String { "\(state), reachable \(isReachable), prompter \(hasPrompter)" }

    static let all: [DisplayCase] = [PlaybackState.idle, .countdown(3), .playing, .paused, .finished].flatMap { state in
        [true, false].flatMap { reachable in
            [true, false].map { DisplayCase(state: state, isReachable: reachable, hasPrompter: $0) }
        }
    }
}

struct RemoteDisplayModelTests {
    /// What the watch shows for a live prompter in each state.
    struct Expected {
        var stateText: String
        var buttonTitle: String
        var command: RemoteCommand
        var symbol: String
        var digit: Int?
    }

    static func expected(for state: PlaybackState) -> Expected {
        switch state {
        case .idle: Expected(stateText: "Ready", buttonTitle: "Start", command: .start, symbol: "play.fill")
        case .countdown(let n): Expected(stateText: "\(n)", buttonTitle: "Cancel", command: .pause, symbol: "xmark", digit: n)
        case .playing: Expected(stateText: "Playing", buttonTitle: "Pause", command: .pause, symbol: "pause.fill")
        case .paused: Expected(stateText: "Paused", buttonTitle: "Resume", command: .resume, symbol: "play.fill")
        case .finished: Expected(stateText: "Finished", buttonTitle: "Start again", command: .start, symbol: "play.fill")
        }
    }

    static func status(_ state: PlaybackState, hasPrompter: Bool = true) -> PrompterStatus {
        guard hasPrompter else { return .noPrompter }
        var status = sampleStatus
        status.state = state
        status.progress = 0.25
        status.remainingSeconds = 176
        status.speedLabel = "Speed 3.0"
        return status
    }

    @Test(arguments: DisplayCase.all)
    func everyStateReachabilityAndPrompter(_ c: DisplayCase) {
        let model = RemoteDisplayModel(status: Self.status(c.state, hasPrompter: c.hasPrompter), isReachable: c.isReachable)
        let live = c.isReachable && c.hasPrompter
        #expect(model.controlsEnabled == live)

        if live {
            let expected = Self.expected(for: c.state)
            #expect(model.title == sampleStatus.scriptTitle)
            #expect(model.stateText == expected.stateText)
            #expect(model.primaryButtonTitle == expected.buttonTitle)
            #expect(model.primaryCommand == expected.command)
            #expect(model.primarySymbol == expected.symbol)
            #expect(model.countdownDigit == expected.digit)
            #expect(model.progress == 0.25)
            #expect(model.timeText == "2:56")
            #expect(model.speedLabel == "Speed 3.0")
            #expect(model.speedControlsEnabled)
            #expect(model.timeAccessibilityValue == (expected.digit.map(String.init) ?? "2:56"))
        } else {
            #expect(model.title == "Prompter")
            #expect(model.stateText == (c.isReachable ? "Tap Prompt on your iPhone" : "Open Prompter on your iPhone"))
            #expect(model.primaryButtonTitle == "Start")
            #expect(model.primaryCommand == .start)
            #expect(model.primarySymbol == "play.fill")
            #expect(model.countdownDigit == nil)
            #expect(model.progress == 0)
            #expect(model.timeText == "--:--")
            #expect(model.speedLabel.isEmpty)
            #expect(!model.speedControlsEnabled)
            #expect(model.timeAccessibilityValue == "No time")
        }
    }

    @Test(arguments: [true, false])
    func noStatusYet(isReachable: Bool) {
        let model = RemoteDisplayModel(status: nil, isReachable: isReachable)
        #expect(!model.controlsEnabled)
        #expect(model.title == "Prompter")
        #expect(model.stateText == (isReachable ? "Tap Prompt on your iPhone" : "Open Prompter on your iPhone"))
        #expect(model.timeText == "--:--")
        #expect(model.timeAccessibilityValue == "No time")
        #expect(model.progress == 0)
        #expect(model.countdownDigit == nil)
    }

    /// The phone has a prompter open but isn't showing it (in the background, or locked): it won't start from the watch,
    /// so the watch asks for the phone to be opened and its controls are off, whatever the state.
    @Test(arguments: [PlaybackState.idle, .countdown(3), .playing, .paused, .finished])
    func prompterOffScreenAsksToOpenThePhone(state: PlaybackState) {
        var status = Self.status(state)
        status.isOnScreen = false
        let model = RemoteDisplayModel(status: status, isReachable: true)
        #expect(!model.controlsEnabled)
        #expect(!model.speedControlsEnabled)
        #expect(model.stateText == "Open Prompter on your iPhone")
        #expect(model.timeText == "--:--")
        #expect(model.countdownDigit == nil)

        // Back on screen (or an older phone app that never says): live again.
        status.isOnScreen = nil
        #expect(RemoteDisplayModel(status: status, isReachable: true).controlsEnabled)
        status.isOnScreen = true
        #expect(RemoteDisplayModel(status: status, isReachable: true).controlsEnabled)
    }

    /// In voice mode the reader sets the pace and the phone ignores speed steps: − / + and the Crown are off, the rest on.
    @Test func voiceModeTurnsTheSpeedControlsOff() {
        var status = Self.status(.playing)
        status.speedLabel = "Voice"
        let voice = RemoteDisplayModel(status: status, isReachable: true)
        #expect(voice.controlsEnabled)
        #expect(!voice.speedControlsEnabled)
        #expect(voice.speedLabel == "Voice")

        // Voice that can't listen falls back to WPM, and its speed steps work.
        status.speedLabel = "140 wpm"
        #expect(RemoteDisplayModel(status: status, isReachable: true).speedControlsEnabled)
    }

    @Test func untitledScriptShowsAppName() {
        var status = Self.status(.playing)
        status.scriptTitle = ""
        #expect(RemoteDisplayModel(status: status, isReachable: true).title == "Prompter")
    }

    @Test(arguments: [
        (0.0, "0:00"),
        (0.2, "0:01"),
        (59.0, "0:59"),
        (59.01, "1:00"),
        (3_725, "1:02:05"),
        (-3, "0:00"),
        (Double.nan, "0:00"),
        (Double.infinity, "0:00"),
    ])
    func timeTextRoundsUp(seconds: Double, expected: String) {
        var status = Self.status(.playing)
        status.remainingSeconds = seconds
        #expect(RemoteDisplayModel(status: status, isReachable: true).timeText == expected)
    }

    @Test(arguments: [(-0.5, 0.0), (0.5, 0.5), (1.7, 1.0), (Double.nan, 0.0), (Double.infinity, 1.0)])
    func progressIsClamped(progress: Double, expected: Double) {
        var status = Self.status(.playing)
        status.progress = progress
        #expect(RemoteDisplayModel(status: status, isReachable: true).progress == expected)
    }
}
