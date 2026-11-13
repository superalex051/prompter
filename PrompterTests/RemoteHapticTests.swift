import Foundation
import Testing
@testable import Prompter

struct RemoteHapticTests {
    private func status(_ state: PlaybackState, hasPrompter: Bool = true) -> PrompterStatus {
        PrompterStatus(
            hasPrompter: hasPrompter,
            scriptTitle: hasPrompter ? "Intro" : "",
            state: state,
            progress: 0,
            remainingSeconds: 60,
            speedLabel: "Speed 3.0",
            sequence: 1
        )
    }

    private func cue(_ old: PlaybackState?, _ new: PlaybackState) -> RemoteHaptic? {
        RemoteHaptic.cue(from: old.map { status($0) }, to: status(new))
    }

    @Test func clickOnEveryNewCountdownDigit() {
        #expect(cue(.idle, .countdown(3)) == .countdownTick)
        #expect(cue(.countdown(3), .countdown(2)) == .countdownTick)
        #expect(cue(.countdown(2), .countdown(1)) == .countdownTick)
        #expect(cue(.finished, .countdown(3)) == .countdownTick)
    }

    @Test func repeatsOfTheSameStateAreSilent() {
        #expect(cue(.countdown(2), .countdown(2)) == nil)
        #expect(cue(.playing, .playing) == nil)
        #expect(cue(.finished, .finished) == nil)
        #expect(cue(.idle, .idle) == nil)
    }

    @Test func goWhenTheTextStartsMoving() {
        #expect(cue(.countdown(1), .playing) == .go)
        // Countdown turned off in the settings, or a 4 Hz update skipped the last digit.
        #expect(cue(.idle, .playing) == .go)
        #expect(cue(.countdown(2), .playing) == .go)
    }

    @Test func resumingIsSilent() {
        #expect(cue(.paused, .playing) == nil)
    }

    @Test func successAtTheEnd() {
        #expect(cue(.playing, .finished) == .finished)
        #expect(cue(.paused, .finished) == .finished)
    }

    @Test func pausingAndGoingBackAreSilent() {
        #expect(cue(.playing, .paused) == nil)
        #expect(cue(.countdown(2), .idle) == nil)
        #expect(cue(.finished, .idle) == nil)
    }

    @Test func firstStatusIsSilent() {
        // The watch just opened: the application context may be from a while ago.
        #expect(cue(nil, .finished) == nil)
        #expect(cue(nil, .countdown(3)) == nil)
        #expect(RemoteHaptic.cue(from: status(.playing), to: nil) == nil)
    }

    @Test func noPrompterIsSilent() {
        #expect(RemoteHaptic.cue(from: status(.playing), to: status(.idle, hasPrompter: false)) == nil)
        #expect(RemoteHaptic.cue(from: status(.idle, hasPrompter: false), to: status(.idle, hasPrompter: false)) == nil)
    }

    @Test func aPrompterOpeningMidCountdownStillClicks() {
        // The phone opened a script with auto-start while the watch showed "Tap Prompt on your iPhone".
        let none = status(.idle, hasPrompter: false)
        #expect(RemoteHaptic.cue(from: none, to: status(.countdown(3))) == .countdownTick)
        #expect(RemoteHaptic.cue(from: none, to: status(.idle)) == nil)
    }
}

struct RemoteHapticGateTests {
    private func status(_ state: PlaybackState, sequence: UInt64) -> PrompterStatus {
        PrompterStatus(
            hasPrompter: true,
            scriptTitle: "Intro",
            state: state,
            progress: 0,
            remainingSeconds: 60,
            speedLabel: "Speed 3.0",
            sequence: sequence
        )
    }

    @Test func catchingUpOnLaunchIsSilent() {
        // Seen on the simulator: the stored context (playing), then a newer pending one (finished), at activation.
        var gate = RemoteHapticGate()
        let old = status(.playing, sequence: 1)
        let newer = status(.finished, sequence: 2)
        #expect(gate.haptic(from: nil, to: old, isLive: false) == nil)
        #expect(gate.haptic(from: old, to: newer, isLive: false) == nil)
        #expect(!gate.isArmed)
    }

    @Test func theFirstLiveStatusArmsWithoutPlaying() {
        var gate = RemoteHapticGate()
        let context = status(.idle, sequence: 1)
        let reply = status(.countdown(3), sequence: 2)
        #expect(gate.haptic(from: context, to: reply, isLive: true) == nil)
        #expect(gate.isArmed)
        #expect(gate.haptic(from: reply, to: status(.countdown(2), sequence: 3), isLive: true) == .countdownTick)
    }

    @Test func onceArmedTheContextCanCarryTheChange() {
        // The phone pushes the same status as a live message and as the context; whichever arrives first is accepted.
        var gate = RemoteHapticGate()
        _ = gate.haptic(from: nil, to: status(.idle, sequence: 1), isLive: true)
        let change = gate.haptic(from: status(.idle, sequence: 1), to: status(.countdown(3), sequence: 2), isLive: false)
        #expect(change == .countdownTick)
    }

    @Test func goingOutOfReachDisarms() {
        var gate = RemoteHapticGate()
        _ = gate.haptic(from: nil, to: status(.playing, sequence: 1), isLive: true)
        gate.disarm()
        // Wrist back up: the reply says the take ended a while ago. No buzz for that.
        #expect(gate.haptic(from: status(.playing, sequence: 1), to: status(.finished, sequence: 9), isLive: true) == nil)
        #expect(gate.isArmed)
    }
}
