import AppIntents

// Siri, Shortcuts and the Action button drive the prompter through the same `PrompterRemoteHub` the Apple Watch uses.
//
// The hub is handed to the intents with App Intents dependency injection: `PrompterApp.init` registers it with
// `AppDependencyManager.shared.add(dependency:)` before the system can run any intent, and each intent reads it with
// `@Dependency`. The intents run in the app's own process, in the foreground (`supportedModes`), so that hub is the one
// attached to the prompter on screen. The app may still be coming to the foreground when `perform()` runs, so each intent
// first waits (up to 2 s) for the prompter to be on screen: the hub refuses to start a prompter it can't show.

/// Counts down, then starts the open script scrolling (paused: resumes; finished: starts again from the top).
struct StartPrompterIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Prompter"
    static let description = IntentDescription("Counts down, then starts scrolling the script that is open in Prompter.")
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Dependency var hub: PrompterRemoteHub

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(await PrompterIntentRunner.perform(.start, hub: hub).dialog))
    }
}

/// Pauses the script (during the countdown: cancels it).
struct PausePrompterIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Prompter"
    static let description = IntentDescription("Pauses the script that is playing in Prompter.")
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Dependency var hub: PrompterRemoteHub

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(await PrompterIntentRunner.perform(.pause, hub: hub).dialog))
    }
}

/// Carries on from where a paused script stopped.
struct ResumePrompterIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Prompter"
    static let description = IntentDescription("Carries on scrolling the script that is paused in Prompter.")
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Dependency var hub: PrompterRemoteHub

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(await PrompterIntentRunner.perform(.resume, hub: hub).dialog))
    }
}

/// The phrases Siri understands and the tiles Shortcuts and the Action button offer, without any set-up.
struct PrompterShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartPrompterIntent(),
            phrases: ["Start \(.applicationName)"],
            shortTitle: "Start Prompter",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PausePrompterIntent(),
            phrases: ["Pause \(.applicationName)"],
            shortTitle: "Pause Prompter",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: ResumePrompterIntent(),
            phrases: ["Resume \(.applicationName)"],
            shortTitle: "Resume Prompter",
            systemImageName: "playpause.fill"
        )
    }
}
