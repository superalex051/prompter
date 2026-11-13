import Foundation

/// Everything the watch shows, derived from the latest status and whether the phone is reachable.
///
/// Live values (title, progress, time, speed, countdown digit) only show while `controlsEnabled`; otherwise the watch
/// shows "Prompter", an empty ring and "--:--", so it never presents stale numbers as current.
struct RemoteDisplayModel: Equatable, Sendable {
    /// The script title, or "Prompter".
    var title: String
    /// "On Sam's MacBook Pro" while the watch controls Prompter for Mac through the iPhone; nil for the iPhone's own
    /// prompter (and whenever nothing is live).
    var deviceText: String?
    /// "Open Prompter on your iPhone" (unreachable, or the prompter is open but not on screen), "Tap Prompt on your
    /// iPhone" (no prompter), "Tap Prompt on your iPhone or Mac" (no prompter, the paired Mac is connected), "iPhone app
    /// in the background" (no prompter, the bridge to the Mac is down), or "Ready", "3", "Playing", "Paused", "Finished".
    var stateText: String
    /// "Start" (idle), "Start again" (finished), "Cancel" (countdown), "Pause" (playing), "Resume" (paused).
    var primaryButtonTitle: String
    /// What the primary button sends: .start, .pause (also cancels a countdown), .resume.
    var primaryCommand: RemoteCommand
    /// SF Symbol for the primary button: "play.fill", "xmark", "pause.fill".
    var primarySymbol: String
    /// The phone is reachable and showing the prompter.
    var controlsEnabled: Bool
    /// The speed − / + buttons and the Crown do something: the controls are on and the prompter isn't following the
    /// reader's voice (then the reader sets the pace and the phone ignores speed steps).
    var speedControlsEnabled: Bool
    /// 0…1, for the ring.
    var progress: Double
    /// Time remaining, "2:56" (rounded up to whole seconds), or "--:--" when there is nothing live to show.
    var timeText: String
    /// "Speed 3.0", "140 wpm", "Finish in 5:00", "Voice", or "" when there is nothing live to show.
    var speedLabel: String
    /// The digit while counting down, shown in place of the time.
    var countdownDigit: Int?

    static let appTitle = "Prompter"
    static let unreachableText = "Open Prompter on your iPhone"
    static let noPrompterText = "Tap Prompt on your iPhone"
    static let noPrompterWithMacText = "Tap Prompt on your iPhone or Mac"
    static let phoneInBackgroundText = "iPhone app in the background"
    static let noTimeText = "--:--"
    /// What VoiceOver says instead of "--:--".
    static let noTimeSpoken = "No time"
    /// The phone's speed label while the prompter follows the reader's voice.
    static let voiceSpeedLabel = "Voice"

    /// What VoiceOver reads as the primary button's value: the countdown digit, the time left, or "No time".
    var timeAccessibilityValue: String {
        if let countdownDigit { return "\(countdownDigit)" }
        return timeText == Self.noTimeText ? Self.noTimeSpoken : timeText
    }

    init(status: PrompterStatus?, isReachable: Bool) {
        guard isReachable, let status, status.isLive else {
            title = Self.appTitle
            deviceText = nil
            // An open prompter the phone isn't showing (app in the background, phone locked) can't be started from here.
            let prompterOffScreen = status?.hasPrompter == true
            stateText = isReachable && !prompterOffScreen ? Self.noPrompterText(note: status?.note) : Self.unreachableText
            primaryButtonTitle = "Start"
            primaryCommand = .start
            primarySymbol = "play.fill"
            controlsEnabled = false
            speedControlsEnabled = false
            progress = 0
            timeText = Self.noTimeText
            speedLabel = ""
            countdownDigit = nil
            return
        }

        title = status.scriptTitle.isEmpty ? Self.appTitle : status.scriptTitle
        deviceText = status.deviceName.flatMap { $0.isEmpty ? nil : "On \($0)" }
        controlsEnabled = true
        speedControlsEnabled = status.speedLabel != Self.voiceSpeedLabel
        progress = status.progress.isNaN ? 0 : min(max(status.progress, 0), 1)
        timeText = TimeFormatting.clock(status.remainingSeconds.rounded(.up))
        speedLabel = status.speedLabel
        countdownDigit = nil

        let button: (title: String, command: RemoteCommand, symbol: String)
        switch status.state {
        case .idle:
            stateText = "Ready"
            button = ("Start", .start, "play.fill")
        case .countdown(let digit):
            stateText = "\(digit)"
            countdownDigit = digit
            button = ("Cancel", .pause, "xmark")
        case .playing:
            stateText = "Playing"
            button = ("Pause", .pause, "pause.fill")
        case .paused:
            stateText = "Paused"
            button = ("Resume", .resume, "play.fill")
        case .finished:
            stateText = "Finished"
            button = ("Start again", .start, "play.fill")
        }
        primaryButtonTitle = button.title
        primaryCommand = button.command
        primarySymbol = button.symbol
    }

    /// What the watch says when there is no prompter to control, given the iPhone's note.
    static func noPrompterText(note: RemoteNote?) -> String {
        switch note {
        case .macConnected: noPrompterWithMacText
        case .phoneInBackground: phoneInBackgroundText
        case .unknown, nil: noPrompterText
        }
    }
}
