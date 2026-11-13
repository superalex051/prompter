import Foundation

/// What an intent tells the person once it ran. Kept free of AppIntents types so tests can check it directly.
enum PrompterIntentOutcome: Equatable, Sendable {
    /// No script is open in the prompter, so nothing happened.
    case noPrompter
    /// A script is open but Prompter isn't on screen (it didn't come back to the foreground in time), so the prompter
    /// wasn't started.
    case notOnScreen
    /// The prompter's state after the command.
    case state(PlaybackState)

    /// The sentence Siri speaks and Shortcuts shows.
    var dialog: LocalizedStringResource {
        switch self {
        case .noPrompter: "Tap Prompt on a script in Prompter first."
        case .notOnScreen: "Open Prompter, then try again."
        case .state(.idle): "Ready"
        case .state(.countdown): "Starting"
        case .state(.playing): "Playing"
        case .state(.paused): "Paused"
        case .state(.finished): "Finished"
        }
    }
}

/// The logic behind the Start, Pause and Resume intents: the same hub call the Apple Watch makes, so a Shortcut or the
/// Action button behaves exactly like the watch's buttons.
@MainActor
enum PrompterIntentRunner {
    /// How long an intent waits for Prompter to come on screen (the system brings the app to the foreground to run it).
    static let screenTimeout: Duration = .seconds(2)

    /// What the intents call: waits (up to `timeout`) for the prompter to be on screen, so a start isn't refused while the
    /// app is still coming to the foreground, then runs `command`. With no prompter open it doesn't wait.
    static func perform(
        _ command: RemoteCommand,
        hub: PrompterRemoteHub,
        timeout: Duration = screenTimeout
    ) async -> PrompterIntentOutcome {
        await hub.waitUntilPrompterOnScreen(timeout: timeout)
        return run(command, hub: hub)
    }

    /// Applies `command` to the open prompter at once. With no prompter open nothing happens and the outcome says so, so
    /// the intent never reports a success it didn't achieve; the same goes for a start refused because the prompter
    /// isn't on screen.
    static func run(_ command: RemoteCommand, hub: PrompterRemoteHub) -> PrompterIntentOutcome {
        let status = hub.handle(command)
        // Intents control the iPhone's prompter only: a status describing the Mac (the watch's target) didn't move it.
        guard status.hasPrompter, status.deviceName == nil else { return .noPrompter }
        if status.isOnScreen == false, RemoteCommandRouter.needsScreen(command, from: status.state) {
            return .notOnScreen
        }
        return .state(status.state)
    }
}
