import Foundation

/// The debug launch options of presenting (M6b), e.g.
/// `open Prompter.app --args -demoData -route prompter -autoStart -outputScreen 1 -snapshot /tmp/shots -quitAfter 12`.
/// Read like every other option (`LaunchArguments`).
struct PresenterLaunchOptions: Equatable, Sendable {
    /// Which script `-route prompter` presents.
    enum ScriptChoice: String, Equatable, Sendable {
        /// The most recently edited one (the top of the library).
        case newest
        /// "Welcome to Prompter", the built-in sample (the newest if it was deleted).
        case sample
        /// With `-demoData`: the demo library also has `DemoData.markdownScript`, and this presents it (screenshots).
        case markdown
    }

    /// "-route prompter": start presenting at launch.
    var routesToPrompter = false
    /// "-script sample" or "-script markdown" (any case); otherwise the newest script.
    var script: ScriptChoice = .newest
    /// "-outputScreen <index|name>": the output goes to that screen instead of the remembered or automatic one.
    var outputScreen: OutputScreenRequest?
    /// "-autoStart": start the countdown as soon as presenting begins.
    var autoStart = false
    /// "-presenterSettings": open the Presenter view's settings panel (screenshots).
    var opensSettings = false
    /// "-previewMirrored": the Presenter view's preview starts "as on the teleprompter" (screenshots).
    var previewMirrored = false
    /// "-snapshot <dir>" (the app's own option): with `-route prompter`, also write PNGs of the output and the Presenter
    /// view at `snapshotTimes`.
    var snapshotDirectory: URL?
    /// "-presenterSnapshots 2,8": seconds after presenting began; default 2 s (mid-countdown) and 8 s (playing).
    var snapshotTimes: [Double] = [2, 8]
    /// "-singleScreen": act as if only the main screen were connected (checks the one-screen layout on a two-screen Mac).
    var singleScreen = false
    /// "-mute", and any `-snapshot` run: no countdown beeps (test launches shouldn't make noise).
    var isMuted = false

    init(arguments: [String] = LaunchArguments.process) {
        routesToPrompter = LaunchArguments.value(after: "route", in: arguments)?.lowercased() == "prompter"
        if let value = LaunchArguments.value(after: "script", in: arguments),
           let choice = ScriptChoice(rawValue: value.lowercased()) {
            script = choice
        }
        outputScreen = LaunchArguments.value(after: "outputScreen", in: arguments).flatMap(OutputScreenRequest.init(argument:))
        autoStart = LaunchArguments.flag("autoStart", in: arguments)
        opensSettings = LaunchArguments.flag("presenterSettings", in: arguments)
        previewMirrored = LaunchArguments.flag("previewMirrored", in: arguments)
        if let path = LaunchArguments.value(after: "snapshot", in: arguments), !path.isEmpty {
            snapshotDirectory = URL(filePath: path, directoryHint: .isDirectory)
        }
        if let value = LaunchArguments.value(after: "presenterSnapshots", in: arguments) {
            let times = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                .filter { $0.isFinite && $0 >= 0 }
            if !times.isEmpty { snapshotTimes = times }
        }
        singleScreen = LaunchArguments.flag("singleScreen", in: arguments)
        isMuted = LaunchArguments.flag("mute", in: arguments) || snapshotDirectory != nil
    }
}
