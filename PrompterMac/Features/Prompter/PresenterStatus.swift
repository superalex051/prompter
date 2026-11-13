import Foundation

/// The words the Presenter view and the output's HUD show for the engine's state. Pure.
enum PresenterStatus {
    /// What the state pill says and how it is coloured.
    enum Tone: Equatable, Sendable { case neutral, countdown, playing, paused, finished }

    /// "Ready", "Starting 3", "Playing", "Pause 3" (a `[pause 3]` cue holding the text), "Paused", "End".
    static func stateWord(for state: PlaybackState, holdSeconds: Int? = nil) -> String {
        switch state {
        case .idle: "Ready"
        case .countdown(let seconds): "Starting \(seconds)"
        case .playing: holdSeconds.map { "Pause \($0)" } ?? "Playing"
        case .paused: "Paused"
        case .finished: "End"
        }
    }

    static func tone(for state: PlaybackState) -> Tone {
        switch state {
        case .idle: .neutral
        case .countdown: .countdown
        case .playing: .playing
        case .paused: .paused
        case .finished: .finished
        }
    }

    /// The big transport button: what pressing it (or Space) does now.
    static func primaryAction(for state: PlaybackState) -> String {
        switch state {
        case .idle: "Start"
        case .countdown: "Cancel"
        case .playing: "Pause"
        case .paused: "Resume"
        case .finished: "Restart"
        }
    }

    /// What the Presenter view asks for while nothing runs: "Press Space or click Start" (nil while a take is running).
    static func startPrompt(for state: PlaybackState) -> String? {
        switch state {
        case .idle, .finished: "Press Space or click \(primaryAction(for: state))"
        case .countdown, .playing, .paused: nil
        }
    }

    /// The output's HUD word: what to do when idle ("Press Space to start"), "Paused", "End", "Pause 3" during a hold;
    /// nothing while counting down or scrolling (the text speaks for itself).
    static func hudWord(for state: PlaybackState, holdSeconds: Int? = nil) -> String? {
        switch state {
        case .idle: "Press Space to start"
        case .paused: "Paused"
        case .finished: "End"
        case .playing: holdSeconds.map { "Pause \($0)" }
        case .countdown: nil
        }
    }

    /// "62%": progress as a whole percentage (0…100).
    static func percent(_ progress: Double) -> String {
        guard progress.isFinite else { return "0%" }
        return "\(Int((min(max(progress, 0), 1) * 100).rounded(.down)))%"
    }
}
