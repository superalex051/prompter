import Foundation

/// The watch app's debug launch arguments, for simulator checks and screenshots:
/// - `-remoteScript "start@3,pause@14,speedStep:5@15"` sends those commands at those seconds after launch (`RemoteScript`).
/// - `-demoStatus playing` shows a canned status without a phone and leaves the watch session off (`macPlaying`: the Mac
///   presenting through the iPhone; `phoneBackground`: the iPhone app in the background with a Mac paired).
///
/// Read from `xcrun simctl launch <watch> <watch bundle ID> -demoStatus playing` or Xcode's scheme
/// arguments. Lives in `Shared/` so the iOS test target can test it.
struct WatchLaunchOptions: Equatable, Sendable {
    /// What `-demoStatus` shows. Matched case-insensitively.
    enum DemoStatus: String, CaseIterable, Sendable {
        case ready, countdown, playing, paused, finished, unreachable
        case noPrompter = "noprompter"
        /// Prompter for Mac presenting, relayed by the iPhone.
        case macPlaying = "macplaying"
        /// No prompter, the iPhone app is in the background and a Mac is paired.
        case phoneBackground = "phonebackground"
    }

    /// nil when the option is missing or none of its steps could be read.
    var remoteScript: RemoteScript?
    var demoStatus: DemoStatus?

    init(arguments: [String] = LaunchArguments.process) {
        if let text = Self.value(after: "remoteScript", in: arguments) {
            let script = RemoteScript(text)
            remoteScript = script.steps.isEmpty ? nil : script
        }
        if let name = Self.value(after: "demoStatus", in: arguments) {
            demoStatus = DemoStatus(rawValue: name.lowercased())
        }
    }

    /// The watch is only launched with `simctl` or Xcode, which write the dashed form, so a bare name is not an option here
    /// (the shared reader also accepts the bare form that Maestro writes).
    private static func value(after name: String, in arguments: [String]) -> String? {
        guard arguments.contains("-\(name)") else { return nil }
        return LaunchArguments.value(after: name, in: arguments)
    }
}

extension WatchLaunchOptions.DemoStatus {
    static let demoTitle = "Channel intro: rig tour"
    static let demoMacName = "Studio Mac"

    /// Whether the canned phone counts as reachable (only `unreachable` doesn't).
    var isReachable: Bool { self != .unreachable }

    /// The canned status; nil for `unreachable` (nothing ever arrived).
    var status: PrompterStatus? {
        func live(_ state: PlaybackState, progress: Double, remaining: Double, speed: String) -> PrompterStatus {
            PrompterStatus(
                hasPrompter: true,
                scriptTitle: Self.demoTitle,
                state: state,
                progress: progress,
                remainingSeconds: remaining,
                speedLabel: speed,
                sequence: 1
            )
        }
        switch self {
        case .ready: return live(.idle, progress: 0, remaining: 176, speed: "Speed 3.0")
        case .countdown: return live(.countdown(3), progress: 0, remaining: 176, speed: "Speed 3.0")
        case .playing: return live(.playing, progress: 0.42, remaining: 102, speed: "Speed 3.5")
        case .paused: return live(.paused, progress: 0.42, remaining: 102, speed: "Speed 3.5")
        case .finished: return live(.finished, progress: 1, remaining: 0, speed: "Speed 3.5")
        case .unreachable: return nil
        case .noPrompter:
            var status = PrompterStatus.noPrompter
            status.sequence = 1
            return status
        case .macPlaying:
            var status = live(.playing, progress: 0.42, remaining: 102, speed: "140 wpm")
            status.deviceName = Self.demoMacName
            return status
        case .phoneBackground:
            var status = PrompterStatus.noPrompter
            status.sequence = 1
            status.note = .phoneInBackground
            return status
        }
    }
}
