import Testing
@testable import Prompter

struct LaunchOptionsTests {
    @Test func noArgumentsMeansLibraryWithoutDemoData() {
        let options = LaunchOptions(arguments: [])
        #expect(options.route == .library)
        #expect(!options.demoData)
    }

    @Test func routeArgumentPicksTheRoute() {
        #expect(LaunchOptions(arguments: ["/path/Prompter", "-route", "editor"]).route == .editor)
        #expect(LaunchOptions(arguments: ["-route", "prompter"]).route == .prompter)
        #expect(LaunchOptions(arguments: ["-route", "settings"]).route == .settings)
    }

    @Test func unknownOrMissingRouteFallsBackToLibrary() {
        #expect(LaunchOptions(arguments: ["-route", "nowhere"]).route == .library)
        #expect(LaunchOptions(arguments: ["-route"]).route == .library)
    }

    @Test func scrollModeOverride() {
        #expect(LaunchOptions(arguments: ["-scrollMode", "voice"]).scrollMode == .voice)
        #expect(LaunchOptions(arguments: ["-scrollMode", "finishIn"]).scrollMode == .finishIn)
        #expect(LaunchOptions(arguments: ["scrollMode", "WPM"]).scrollMode == .wpm)
        #expect(LaunchOptions(arguments: ["-scrollMode", "warp"]).scrollMode == nil)
        #expect(LaunchOptions(arguments: []).scrollMode == nil)
    }

    @Test func voiceFileIsResolvedInTheAppContainer() {
        let relative = LaunchOptions(arguments: ["-voiceFile", "Documents/read.m4a"])
        #expect(relative.voiceFile == "Documents/read.m4a")
        #expect(relative.resolvedVoiceFile(home: "/data/home")?.path() == "/data/home/Documents/read.m4a")
        let absolute = LaunchOptions(arguments: ["-voiceFile", "/tmp/read.m4a"])
        #expect(absolute.resolvedVoiceFile(home: "/data/home")?.path() == "/tmp/read.m4a")
        #expect(LaunchOptions(arguments: ["-voiceFile"]).resolvedVoiceFile() == nil)
        #expect(LaunchOptions(arguments: []).voiceFileURL == nil)
    }

    @Test func demoDataFlag() {
        #expect(LaunchOptions(arguments: ["-demoData"]).demoData)
        #expect(LaunchOptions(arguments: ["-demoData", "YES"]).demoData)
        #expect(LaunchOptions(arguments: ["-demoData", "1"]).demoData)
        #expect(LaunchOptions(arguments: ["-demoData", "true"]).demoData)
        #expect(!LaunchOptions(arguments: ["-demoData", "NO"]).demoData)
        #expect(!LaunchOptions(arguments: ["-demoData", "0"]).demoData)
    }

    @Test func bareDemoDataFlagFollowedByAnotherOption() {
        let options = LaunchOptions(arguments: ["-demoData", "-route", "editor"])
        #expect(options.demoData)
        #expect(options.route == .editor)
    }

    // Maestro 2.11 `launchApp: arguments: {demoData: true, route: editor}` reaches the app as
    // `<path> demoData true -route editor`: it dashes every key except one whose value is a YAML boolean.
    @Test func maestroUndashedBooleanKeyStillTurnsDemoDataOn() {
        let options = LaunchOptions(arguments: ["/path/Prompter", "demoData", "true", "-route", "editor"])
        #expect(options.demoData)
        #expect(options.route == .editor)
    }

    @Test func maestroUndashedKeysInAnyOrder() {
        let options = LaunchOptions(arguments: ["/path/Prompter", "-route", "settings", "demoData", "true"])
        #expect(options.demoData)
        #expect(options.route == .settings)
    }

    @Test func undashedDemoDataHonoursAFalseValue() {
        #expect(!LaunchOptions(arguments: ["demoData", "false"]).demoData)
        #expect(!LaunchOptions(arguments: ["demoData", "0"]).demoData)
    }

    @Test func undashedRouteIsAccepted() {
        #expect(LaunchOptions(arguments: ["route", "prompter"]).route == .prompter)
    }

    @Test func maestroDashedKeysMatchTheShellForm() {
        // `{-demoData: true, -route: editor}` is the form the QA flows use.
        let fromMaestro = LaunchOptions(arguments: ["/path/Prompter", "-demoData", "true", "-route", "editor"])
        let fromShell = LaunchOptions(arguments: ["/path/Prompter", "-demoData", "-route", "editor"])
        #expect(fromMaestro == fromShell)
    }

    @Test func unrelatedArgumentsAreIgnored() {
        let options = LaunchOptions(arguments: ["/path/Prompter", "-foo", "bar", "demo", "route2"])
        #expect(options == LaunchOptions(arguments: []))
    }
}

struct LaunchOptionsAutoStartTests {
    @Test func autoStartIsOffByDefault() {
        #expect(!LaunchOptions(arguments: []).autoStart)
        #expect(!LaunchOptions(arguments: ["-route", "prompter", "-demoData"]).autoStart)
    }

    @Test func autoStartFlag() {
        #expect(LaunchOptions(arguments: ["-autoStart"]).autoStart)
        #expect(LaunchOptions(arguments: ["-autoStart", "YES"]).autoStart)
        #expect(LaunchOptions(arguments: ["-autoStart", "1"]).autoStart)
        #expect(LaunchOptions(arguments: ["-autoStart", "true"]).autoStart)
        #expect(!LaunchOptions(arguments: ["-autoStart", "NO"]).autoStart)
        #expect(!LaunchOptions(arguments: ["-autoStart", "0"]).autoStart)
    }

    @Test func bareAutoStartAmongOtherOptions() {
        let options = LaunchOptions(arguments: ["-demoData", "-route", "prompter", "-autoStart"])
        #expect(options.autoStart)
        #expect(options.demoData)
        #expect(options.route == .prompter)

        let first = LaunchOptions(arguments: ["-autoStart", "-demoData"])
        #expect(first.autoStart)
        #expect(first.demoData)
    }

    /// Testing only: the phone answers the watch but never pushes to it, as when its WCSession wrongly believes the watch
    /// app isn't installed.
    @Test func noWatchPushFlag() {
        #expect(!LaunchOptions(arguments: []).noWatchPush)
        #expect(!LaunchOptions(arguments: ["-demoData", "-route", "prompter"]).noWatchPush)
        let options = LaunchOptions(arguments: ["-demoData", "-route", "prompter", "-noWatchPush"])
        #expect(options.noWatchPush)
        #expect(options.demoData)
        #expect(options.route == .prompter)
        #expect(!LaunchOptions(arguments: ["-noWatchPush", "NO"]).noWatchPush)
    }

    /// Screenshots: the demo library paired with a made-up Mac, for the screens that show only while a Mac is paired.
    @Test func demoPairedMacFlag() {
        #expect(!LaunchOptions(arguments: []).demoPairedMac)
        #expect(!LaunchOptions(arguments: ["-demoData", "-route", "syncSettings"]).demoPairedMac)
        let options = LaunchOptions(arguments: ["-demoData", "-demoPairedMac", "-route", "syncSettings"])
        #expect(options.demoPairedMac)
        #expect(options.demoData)
        #expect(options.route == .syncSettings)
    }

    /// Screenshots of the iPhone Duo's cover held wide without the simulator's rotate control.
    @Test func interfaceOrientationOption() {
        #expect(LaunchOptions(arguments: []).interfaceOrientation == nil)
        #expect(LaunchOptions(arguments: ["-interfaceOrientation", "landscapeLeft"]).interfaceOrientation == .landscapeLeft)
        #expect(LaunchOptions(arguments: ["-interfaceOrientation", "LANDSCAPERIGHT"]).interfaceOrientation == .landscapeRight)
        #expect(LaunchOptions(arguments: ["-interfaceOrientation", "portrait"]).interfaceOrientation == .portrait)
        #expect(LaunchOptions(arguments: ["-interfaceOrientation", "none"]).interfaceOrientation == nil)
    }

    @Test func prompterSettingsRouteIsCaseInsensitive() {
        #expect(LaunchOptions(arguments: ["-route", "prompterSettings"]).route == .prompterSettings)
        #expect(LaunchOptions(arguments: ["-route", "promptersettings"]).route == .prompterSettings)
        #expect(LaunchOptions(arguments: ["-route", "PROMPTER"]).route == .prompter)
    }
}

struct LaunchOptionsScriptTests {
    @Test func newestScriptByDefault() {
        #expect(LaunchOptions(arguments: []).script == .newest)
        #expect(LaunchOptions(arguments: ["-route", "prompter", "-demoData"]).script == .newest)
    }

    @Test func scriptSamplePicksTheSample() {
        #expect(LaunchOptions(arguments: ["-script", "sample"]).script == .sample)
        #expect(LaunchOptions(arguments: ["-script", "Sample"]).script == .sample)
        #expect(LaunchOptions(arguments: ["script", "sample"]).script == .sample)      // Maestro's undashed form
        let options = LaunchOptions(arguments: ["-demoData", "-route", "prompter", "-script", "sample", "-autoStart"])
        #expect(options.script == .sample)
        #expect(options.route == .prompter)
        #expect(options.demoData)
        #expect(options.autoStart)
    }

    @Test func unknownOrMissingScriptFallsBackToNewest() {
        #expect(LaunchOptions(arguments: ["-script", "nope"]).script == .newest)
        #expect(LaunchOptions(arguments: ["-script"]).script == .newest)
        #expect(LaunchOptions(arguments: ["-script", "-route", "editor"]).script == .newest)
    }
}
