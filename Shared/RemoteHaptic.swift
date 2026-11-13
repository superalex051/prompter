import Foundation

/// The haptic the watch plays when the prompter's state changes. Decided only on a change of state, never on a repeat
/// of the same state, so repeated live updates (time left, progress) don't buzz the wrist.
enum RemoteHaptic: Equatable, Sendable {
    /// A new countdown digit (WatchKit `.click`).
    case countdownTick
    /// The text started moving after a countdown or from the top (`.start`). Resuming from a pause plays nothing.
    case go
    /// The end of the script (`.success`).
    case finished

    /// What to play when the accepted status goes from `old` to `new`. nil for the first status the watch hears (it may
    /// be an old application context), for no change, and when `new` has no prompter.
    static func cue(from old: PrompterStatus?, to new: PrompterStatus?) -> RemoteHaptic? {
        guard let old, let new, new.hasPrompter else { return nil }
        let before: PlaybackState? = old.hasPrompter ? old.state : nil
        guard before != new.state else { return nil }
        switch new.state {
        case .countdown: return .countdownTick
        case .playing: return before == .paused ? nil : .go
        case .finished: return .finished
        case .idle, .paused: return nil
        }
    }
}

/// Decides when the watch may buzz at all: only for changes it saw happen live. It starts disarmed and is disarmed again
/// whenever the phone goes out of reach; the first live message or command reply after that arms it without playing
/// anything. So catching up (an old application context when the app opens, a reply after the wrist comes back up)
/// never buzzes, while every change after that does, whichever way its status arrives first.
struct RemoteHapticGate: Sendable {
    private(set) var isArmed = false

    init() {}

    /// The phone went out of reach: whatever arrives next is catching up.
    mutating func disarm() {
        isArmed = false
    }

    /// The haptic for an accepted status. `isLive`: it came as a live message or a command reply, not the application
    /// context.
    mutating func haptic(from old: PrompterStatus?, to new: PrompterStatus, isLive: Bool) -> RemoteHaptic? {
        guard isArmed else {
            if isLive { isArmed = true }
            return nil
        }
        return RemoteHaptic.cue(from: old, to: new)
    }
}
