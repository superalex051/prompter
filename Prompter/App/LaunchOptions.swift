import Foundation

/// Launch arguments used for screenshots and UI checks, e.g. `-route editor -demoData`.
///
/// Every option is read in two spellings (`-demoData` and a bare `demoData`), see `LaunchArguments`.
struct LaunchOptions: Equatable, Sendable {
    enum Route: String, Sendable, CaseIterable {
        case library, editor, prompter, settings
        /// The prompter with its settings sheet open (screenshots). Matched case-insensitively: `-route prompterSettings`.
        case prompterSettings = "promptersettings"
        /// Settings → Sync with Mac (screenshots). `-route syncSettings`.
        case syncSettings = "syncsettings"
        /// The Remote for Mac screen (screenshots, the watch → Mac end-to-end check). `-route macRemote`.
        case macRemote = "macremote"
    }

    /// Which script the editor and prompter routes open.
    enum ScriptChoice: String, Sendable, CaseIterable {
        /// The most recently edited one (the top of the library).
        case newest
        /// "Welcome to Prompter", the built-in sample (falls back to the newest if it was deleted).
        case sample
        /// With `-demoData`: the demo library also has `DemoData.markdownScript`, and this opens it (screenshots).
        case markdown
    }

    var route: Route = .library               // "-route editor" or "route editor"
    var demoData: Bool = false                // "-demoData" (bare flag), "-demoData YES|1|true" or "demoData true"
    var autoStart: Bool = false               // "-autoStart" (bare flag) or "-autoStart YES|1|true": start the countdown on open
    /// "-noWatchPush": the phone never pushes to the watch (no live messages, no application context) and only answers
    /// its messages. That is what WatchConnectivity does when the phone's session wrongly believes the watch app isn't
    /// installed (seen on the simulators); used to check that the watch keeps up by asking (`StatusPoll`).
    var noWatchPush: Bool = false
    var script: ScriptChoice = .newest        // "-script sample" (any case)
    /// "-scrollMode voice" (speed, finishIn, wpm or voice): with `-demoData`, the throwaway settings start in that mode.
    var scrollMode: PrompterSettings.ScrollMode?
    /// Debug builds: "-voiceFile Documents/read.m4a" makes voice-follow listen to that audio file (played in real time)
    /// instead of the microphone. A relative path is inside the app's data container (`simctl get_app_container … data`).
    var voiceFile: String?
    /// Debug builds: "-voiceReplay Documents/read.results" replays a recogniser's recorded results (made on the Mac by
    /// scripts/voice-check.sh) at their recorded times instead of listening. The simulator has no working speech
    /// recogniser, so this is how it shows the text following a real read-through. Same path rules as `voiceFile`.
    var voiceReplay: String?
    /// Debug builds: "-duoProbe" logs the window's shape (size, size classes, the fold, the hinge) on every change to
    /// Documents/duo-probe.log. See DuoProbe.swift.
    var duoProbe: Bool = false
    /// "-landscapeOnly NO" (or YES): with `-demoData`, the prompter opens with "Landscape only" set this way (the throwaway
    /// settings start with it on). Used to check the prompter on a foldable with the lock off. nil: the setting as it is.
    var landscapeOnly: Bool?
    /// "-landscapeSide left" (or right): with `-demoData`, the throwaway side store starts with that landscape side
    /// remembered, so a take opened from portrait locks to it. Used to shoot the other side of a phone held upright (a
    /// foldable's camera lands on the other corner). nil: nothing remembered, so the lock picks landscape right.
    var landscapeSide: LandscapeSide?

    enum LandscapeSide: String, Sendable, CaseIterable {
        case left, right
    }

    /// Debug builds with `-demoData`: "-demoPairedMac" pairs the throwaway library with a made-up Mac (`DemoData.macName`),
    /// so the screens that show only while a Mac is paired (the library's Remote for Mac button, Settings, Sync with Mac,
    /// Remote for Mac pushed from there) can be screenshotted. Nothing ever connects to it.
    var demoPairedMac: Bool = false
    /// Debug builds: "-interfaceOrientation landscapeLeft" (or landscapeRight, portrait) turns the window that way once
    /// the library shows, for screenshots of the iPhone Duo's cover held wide when the simulator's own rotate control
    /// (in Device Hub) can't be reached. Any other value is ignored.
    var interfaceOrientation: DebugOrientation?

    /// The orientations `-interfaceOrientation` accepts.
    enum DebugOrientation: String, Sendable, CaseIterable {
        case portrait, landscapeLeft, landscapeRight
    }

    init(arguments: [String] = LaunchArguments.process) {
        if let value = Self.value(after: "route", in: arguments), let route = Route(rawValue: value.lowercased()) {
            self.route = route
        }
        if let value = Self.value(after: "script", in: arguments), let script = ScriptChoice(rawValue: value.lowercased()) {
            self.script = script
        }
        if let value = Self.value(after: "scrollMode", in: arguments) {
            scrollMode = PrompterSettings.ScrollMode.allCases.first { $0.rawValue.lowercased() == value.lowercased() }
        }
        voiceFile = Self.value(after: "voiceFile", in: arguments)
        voiceReplay = Self.value(after: "voiceReplay", in: arguments)
        demoData = Self.flag("demoData", in: arguments)
        autoStart = Self.flag("autoStart", in: arguments)
        noWatchPush = Self.flag("noWatchPush", in: arguments)
        duoProbe = Self.flag("duoProbe", in: arguments)
        if LaunchArguments.flagIndex("landscapeOnly", in: arguments) != nil {
            landscapeOnly = Self.flag("landscapeOnly", in: arguments)
        }
        if let value = Self.value(after: "landscapeSide", in: arguments) {
            landscapeSide = LandscapeSide(rawValue: value.lowercased())
        }
        demoPairedMac = Self.flag("demoPairedMac", in: arguments)
        if let value = Self.value(after: "interfaceOrientation", in: arguments) {
            interfaceOrientation = DebugOrientation.allCases.first { $0.rawValue.lowercased() == value.lowercased() }
        }
    }

    /// `voiceFile` as a file URL: absolute paths as they are, relative ones under `home` (the app's data container).
    func resolvedVoiceFile(home: String = NSHomeDirectory()) -> URL? {
        Self.resolve(voiceFile, home: home)
    }

    var voiceFileURL: URL? { resolvedVoiceFile() }

    /// `voiceReplay` as a file URL, like `voiceFileURL`.
    var voiceReplayURL: URL? { Self.resolve(voiceReplay, home: NSHomeDirectory()) }

    private static func resolve(_ path: String?, home: String) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("/") { return URL(filePath: path) }
        return URL(filePath: home).appending(path: path)
    }

    private static func flag(_ name: String, in arguments: [String]) -> Bool {
        LaunchArguments.flag(name, in: arguments)
    }

    private static func value(after name: String, in arguments: [String]) -> String? {
        LaunchArguments.value(after: name, in: arguments)
    }
}
