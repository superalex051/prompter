import Foundation

/// Applies watch commands to the open prompter's engine and describes the engine as a `PrompterStatus`.
@MainActor
enum RemoteCommandRouter {
    /// Applies the command to the engine (nil engine → nothing happens). requestStatus does nothing.
    ///
    /// Only calls engine commands: the screen owns `engine.onEvent`, so state changes and jumps wake the display link
    /// and play sounds exactly as a touch would, and speed steps are saved to the settings by the screen.
    static func apply(_ command: RemoteCommand, to engine: ScrollEngine?) {
        guard let engine else { return }
        switch command {
        case .start: engine.start()
        case .pause: engine.pause()
        case .resume: engine.resume()
        case .togglePlay: engine.togglePlay()
        case .speedStep(let steps): engine.speedStep(steps)
        case .setSpeed(let value): engine.setSpeed(value)
        case .backToTop: engine.backToTop()
        case .jumpBack: engine.jumpBack()
        case .requestStatus: break
        }
    }

    /// True when `command` would set the text going from `state` (a countdown, playing or resuming), which only makes
    /// sense while the prompter is on screen: off screen nothing draws the countdown, so "go" would fire unseen on the
    /// way back. Pausing (also cancelling a countdown), steps, back to top and speed changes never need the screen.
    static func needsScreen(_ command: RemoteCommand, from state: PlaybackState) -> Bool {
        switch command {
        case .start, .resume:
            switch state {
            case .countdown, .playing: false        // nothing to start; the engine ignores it anyway
            case .idle, .paused, .finished: true
            }
        case .togglePlay:
            switch state {
            case .countdown, .playing: false        // toggling pauses or cancels
            case .idle, .paused, .finished: true
            }
        case .pause, .speedStep, .setSpeed, .backToTop, .jumpBack, .requestStatus:
            false
        }
    }

    /// The engine's state as the watch shows it; `PrompterStatus.noPrompter` (with this sequence) when there is no engine.
    /// `isOnScreen` false marks an open prompter the phone isn't showing (the status then says `isOnScreen == false`).
    static func status(
        engine: ScrollEngine?,
        scriptTitle: String,
        sequence: UInt64,
        isOnScreen: Bool = true
    ) -> PrompterStatus {
        guard let engine else {
            var status = PrompterStatus.noPrompter
            status.sequence = sequence
            return status
        }
        return PrompterStatus(
            hasPrompter: true,
            scriptTitle: scriptTitle,
            state: engine.state,
            progress: engine.progress,
            remainingSeconds: engine.remainingSeconds,
            speedLabel: engine.speedLabel,
            sequence: sequence,
            isOnScreen: isOnScreen ? nil : false
        )
    }
}
