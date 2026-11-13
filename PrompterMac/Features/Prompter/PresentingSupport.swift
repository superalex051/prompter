import AppKit
import IOKit.pwr_mgt

/// Keeps the displays awake while presenting (the person may not touch the Mac for the whole take).
@MainActor
final class DisplaySleepBlocker {
    private var assertionID: IOPMAssertionID = 0
    private(set) var isActive = false

    func begin(reason: String = "Prompter is presenting") {
        guard !isActive else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        isActive = result == kIOReturnSuccess
    }

    func end() {
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isActive = false
    }

    isolated deinit {
        end()
    }
}

/// Countdown sounds on the Mac: a tick for each countdown digit and a distinct sound when scrolling starts, only with
/// "Beep each second" on (the same rule as the iPhone's `PrompterFeedback`).
enum MacPrompterFeedback {
    enum Sound: Equatable, Sendable {
        case tick, go

        var systemSoundName: String {
            switch self {
            case .tick: "Tink"
            case .go: "Hero"
            }
        }
    }

    static func sound(for event: ScrollEngine.Event, settings: PrompterSettings) -> Sound? {
        guard settings.countdownBeep, settings.countdownSeconds > 0 else { return nil }
        switch event {
        case .countdownTick: return .tick
        case .go: return .go
        case .paused, .resumed, .finished, .jumped: return nil
        }
    }

    @MainActor
    static func play(for event: ScrollEngine.Event, settings: PrompterSettings) {
        guard let sound = sound(for: event, settings: settings) else { return }
        // A fresh copy each time: the shared named instance can't play again until it has finished.
        (NSSound(named: sound.systemSoundName)?.copy() as? NSSound)?.play()
    }
}
