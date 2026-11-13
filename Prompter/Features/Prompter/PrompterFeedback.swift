import AudioToolbox

/// Countdown sounds: a short tick for each countdown digit and a distinct sound when scrolling starts.
/// System sounds follow the ring/silent switch.
enum PrompterFeedback {
    enum Sound: Equatable, Sendable {
        case tick, go

        var systemSoundID: SystemSoundID {
            switch self {
            case .tick: 1057      // "Tink"
            case .go: 1117        // begin video recording
            }
        }
    }

    /// The sound for an engine event: only countdown digits and the go after a countdown, only with "Beep each second" on.
    static func sound(for event: ScrollEngine.Event, settings: PrompterSettings) -> Sound? {
        guard settings.countdownBeep, settings.countdownSeconds > 0 else { return nil }
        switch event {
        case .countdownTick: return .tick
        case .go: return .go
        case .paused, .resumed, .finished, .jumped: return nil
        }
    }

    static func play(for event: ScrollEngine.Event, settings: PrompterSettings) {
        guard let sound = sound(for: event, settings: settings) else { return }
        AudioServicesPlaySystemSound(sound.systemSoundID)
    }
}
