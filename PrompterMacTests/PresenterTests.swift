import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import PrompterMac

// M6b: presenting on the Mac. Display picking, the canvas geometry, the Presenter view's words, key routing, launch
// options, the session (settings ⇄ engine, elapsed time, script switching) and the canvas's text layout.

// MARK: - Display picking

private func screen(
    _ id: UInt32, _ name: String, builtIn: Bool = false, menuBar: Bool = false,
    frame: CGRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
) -> DisplayDescriptor {
    DisplayDescriptor(id: id, name: name, frame: frame, isBuiltIn: builtIn, hasMenuBar: menuBar)
}

struct DisplayPickerTests {
    private let laptop = screen(1, "Built-in Retina Display", builtIn: true, menuBar: true)
    private let hdmi = screen(2, "Teleprompter HDMI")

    @Test func laptopPlusHDMIPutsTheOutputOnHDMIAndThePresenterOnTheLaptop() {
        let plan = DisplayPicker.plan(screens: [laptop, hdmi])
        #expect(plan == DisplayPlan(output: 2, presenter: 1))
        #expect(plan?.isSingleScreen == false)
    }

    @Test func hdmiSetAsMainDisplayStillGetsTheOutput() {
        // The person made the external screen the main one (menu bar there): still the external one, never the laptop.
        let laptopWithoutMenuBar = screen(1, "Built-in Retina Display", builtIn: true)
        let mainHDMI = screen(2, "Teleprompter HDMI", menuBar: true)
        #expect(DisplayPicker.plan(screens: [mainHDMI, laptopWithoutMenuBar]) == DisplayPlan(output: 2, presenter: 1))
    }

    @Test func twoExternalScreensPreferTheOneWithoutTheMenuBar() {
        // This Mac: a 3440×1440 main screen and a 2560×1440 second one.
        let main = screen(10, "M34WQ", menuBar: true)
        let second = screen(11, "27GL850")
        #expect(DisplayPicker.plan(screens: [main, second]) == DisplayPlan(output: 11, presenter: 10))
    }

    @Test func oneScreenIsASingleScreenPlan() {
        let plan = DisplayPicker.plan(screens: [laptop])
        #expect(plan == DisplayPlan(output: 1, presenter: 1))
        #expect(plan?.isSingleScreen == true)
        #expect(DisplayPicker.plan(screens: []) == nil)
    }

    @Test func theRememberedScreenWinsAndIsFoundByNameAfterReconnecting() {
        let other = screen(3, "Studio Display")
        let remembered = RememberedOutput(displayID: 3, name: "Studio Display")
        #expect(DisplayPicker.plan(screens: [laptop, hdmi, other], remembered: remembered)?.output == 3)
        // Plugged in again with a new ID: matched by its name.
        let reconnected = screen(7, "Studio Display")
        #expect(DisplayPicker.plan(screens: [laptop, hdmi, reconnected], remembered: remembered)?.output == 7)
        // Not connected: the automatic choice.
        #expect(DisplayPicker.plan(screens: [laptop, hdmi], remembered: remembered)?.output == 2)
    }

    @Test func twoScreensWithTheRememberedNameAreAmbiguousUnlessTheIDMatches() {
        let first = screen(4, "LG")
        let second = screen(5, "LG")
        #expect(DisplayPicker.match(RememberedOutput(displayID: 9, name: "LG"), in: [first, second]) == nil)
        #expect(DisplayPicker.match(RememberedOutput(displayID: 5, name: "LG"), in: [first, second])?.id == 5)
    }

    @Test func aLaunchRequestPicksByIndexOrName() {
        let screens = [laptop, hdmi]
        #expect(DisplayPicker.plan(screens: screens, request: .index(0))?.output == 1)
        #expect(DisplayPicker.plan(screens: screens, request: .name("hdmi"))?.output == 2)
        // Unknown: ignored.
        #expect(DisplayPicker.plan(screens: screens, request: .index(5))?.output == 2)
        #expect(DisplayPicker.plan(screens: screens, request: .name("Projector"))?.output == 2)
        #expect(OutputScreenRequest(argument: "1") == .index(1))
        #expect(OutputScreenRequest(argument: " 27GL850 ") == .name("27GL850"))
        #expect(OutputScreenRequest(argument: "  ") == nil)
    }

    @Test func choosingThePresentersScreenSwapsAndSwapTradesPlaces() {
        let plan = DisplayPlan(output: 2, presenter: 1)
        #expect(DisplayPicker.choosing(output: 1, from: plan, in: [laptop, hdmi]) == DisplayPlan(output: 1, presenter: 2))
        #expect(DisplayPicker.swapped(plan) == DisplayPlan(output: 1, presenter: 2))
        // A third screen: the Presenter view stays put.
        let third = screen(3, "Projector")
        #expect(DisplayPicker.choosing(output: 3, from: plan, in: [laptop, hdmi, third]) == DisplayPlan(output: 3, presenter: 1))
        // A screen that isn't connected: nothing changes.
        #expect(DisplayPicker.choosing(output: 9, from: plan, in: [laptop, hdmi]) == plan)
    }

    @Test func losingTheOutputScreenReplansAndSaysSo() {
        let plan = DisplayPlan(output: 2, presenter: 1)
        let replan = DisplayPicker.replan(current: plan, screens: [laptop])
        #expect(replan == DisplayPicker.Replan(plan: DisplayPlan(output: 1, presenter: 1), outputLost: true))
        #expect(DisplayPicker.replan(current: plan, screens: []) == nil)
    }

    @Test func screensThatStayKeepThePlan() {
        let plan = DisplayPlan(output: 1, presenter: 2)   // swapped by the person
        #expect(DisplayPicker.replan(current: plan, screens: [laptop, hdmi]) == .init(plan: plan, outputLost: false))
    }

    @Test func losingOnlyThePresenterScreenMovesThePresenterAndPauses() {
        let plan = DisplayPlan(output: 2, presenter: 3)   // a third screen had the Presenter view
        let replan = DisplayPicker.replan(current: plan, screens: [laptop, hdmi])
        #expect(replan == .init(plan: DisplayPlan(output: 2, presenter: 1), outputLost: false, presenterLost: true))
        #expect(replan?.isDisruptive == true)
    }

    @Test func closingTheLaptopLidMidTakeKeepsTheOutputFullScreenAndPauses() {
        // Laptop + HDMI; the lid closes: only the teleprompter screen is left.
        let plan = DisplayPlan(output: 2, presenter: 1)
        let replan = DisplayPicker.replan(current: plan, screens: [hdmi])
        #expect(replan == .init(
            plan: DisplayPlan(output: 2, presenter: 2, outputStaysFullScreen: true), outputLost: false, presenterLost: true
        ))
        #expect(replan?.isDisruptive == true)
        // Nothing else changes while the lid stays closed.
        let closed = DisplayPlan(output: 2, presenter: 2, outputStaysFullScreen: true)
        #expect(DisplayPicker.replan(current: closed, screens: [hdmi]) == .init(plan: closed, outputLost: false))
        // The lid opens again: back to the two-screen plan, with nothing to pause for.
        #expect(DisplayPicker.replan(current: closed, screens: [laptop, hdmi])
            == .init(plan: DisplayPlan(output: 2, presenter: 1), outputLost: false))
    }

    @Test func theNoticeSaysWhatHappenedToTheScreens() {
        let twoScreens = DisplayPlan(output: 2, presenter: 1)
        let lost = DisplayPicker.Replan(plan: DisplayPlan(output: 1, presenter: 1), outputLost: true)
        #expect(PresentingController.notice(for: lost, previous: twoScreens, previousScreens: [1, 2])
            == "The teleprompter screen disconnected. Paused.")
        let lidClosed = DisplayPicker.Replan(
            plan: DisplayPlan(output: 2, presenter: 2, outputStaysFullScreen: true), outputLost: false, presenterLost: true
        )
        #expect(PresentingController.notice(for: lidClosed, previous: twoScreens, previousScreens: [1, 2])
            == "The Presenter view's screen disconnected. Paused.")
        // The HDMI screen plugged in while presenting on the laptop alone: the output moves onto it.
        let single = DisplayPlan(output: 1, presenter: 1)
        let connected = DisplayPicker.Replan(plan: twoScreens, outputLost: false)
        #expect(PresentingController.notice(for: connected, previous: single, previousScreens: [1])
            == "Teleprompter screen connected.")
        // Nothing worth saying: the plan stands, or the output moved to a screen that was already there.
        #expect(PresentingController.notice(for: .init(plan: twoScreens, outputLost: false), previous: twoScreens,
                                            previousScreens: [1, 2]) == nil)
        #expect(PresentingController.notice(for: connected, previous: single, previousScreens: [1, 2]) == nil)
    }

    @Test func aSecondScreenArrivingMovesASingleScreenOutputThere() {
        let plan = DisplayPlan(output: 1, presenter: 1)
        let replan = DisplayPicker.replan(current: plan, screens: [laptop, hdmi])
        #expect(replan == .init(plan: DisplayPlan(output: 2, presenter: 1), outputLost: false))
    }
}

// MARK: - Canvas geometry

struct CanvasGeometryTests {
    private func apply(_ transform: CGAffineTransform, _ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: x, y: y).applying(transform)
    }

    @Test func sidewaysRotationsSwapTheCanvas() {
        let screen = CGSize(width: 2560, height: 1440)
        #expect(CanvasGeometry.canvasSize(screenSize: screen, rotation: .none) == screen)
        #expect(CanvasGeometry.canvasSize(screenSize: screen, rotation: .half) == screen)
        #expect(CanvasGeometry.canvasSize(screenSize: screen, rotation: .quarter) == CGSize(width: 1440, height: 2560))
        #expect(CanvasGeometry.canvasSize(screenSize: screen, rotation: .threeQuarters) == CGSize(width: 1440, height: 2560))
    }

    @Test func mirrorAndFlipAreExact() {
        let mirror = CanvasGeometry.layerTransform(rotation: .none, mirror: true, flip: false)
        #expect(apply(mirror, 10, 5) == CGPoint(x: -10, y: 5))
        let flip = CanvasGeometry.layerTransform(rotation: .none, mirror: false, flip: true)
        #expect(apply(flip, 10, 5) == CGPoint(x: 10, y: -5))
        #expect(CanvasGeometry.layerTransform(rotation: .none, mirror: false, flip: false) == .identity)
    }

    @Test func aQuarterTurnIsClockwiseOnScreenLikeTheIPhone() {
        // Core Animation's y runs up: clockwise takes the right (1, 0) to the bottom (0, -1) and the top to the right.
        let quarter = CanvasGeometry.layerTransform(rotation: .quarter, mirror: false, flip: false)
        #expect(apply(quarter, 1, 0) == CGPoint(x: 0, y: -1))
        #expect(apply(quarter, 0, 1) == CGPoint(x: 1, y: 0))
        let threeQuarters = CanvasGeometry.layerTransform(rotation: .threeQuarters, mirror: false, flip: false)
        #expect(apply(threeQuarters, 1, 0) == CGPoint(x: 0, y: 1))
        let half = CanvasGeometry.layerTransform(rotation: .half, mirror: false, flip: false)
        #expect(apply(half, 1, 2) == CGPoint(x: -1, y: -2))
    }

    @Test func rotationComesBeforeTheMirror() {
        // Rotated clockwise the top goes right; the mirror then takes it to the left.
        let transform = CanvasGeometry.layerTransform(rotation: .quarter, mirror: true, flip: false)
        #expect(apply(transform, 0, 1) == CGPoint(x: -1, y: 0))
        let scaled = CanvasGeometry.layerTransform(rotation: .none, mirror: true, flip: false, scale: 0.5)
        #expect(apply(scaled, 10, 4) == CGPoint(x: -5, y: 2))
    }

    @Test func thePreviewIsReadableByDefaultAndExactOnRequest() {
        var settings = PrompterSettings()
        settings.mirrorHorizontal = true
        settings.rotation = .quarter
        let output = CGSize(width: 2560, height: 1440)
        let readable = CanvasGeometry.previewTransform(
            settings: settings, outputScreenSize: output, showsAsOnTeleprompter: false, in: CGSize(width: 900, height: 900)
        )
        // The portrait canvas fitted upright: no mirror, no rotation.
        #expect(readable.canvasSize == CGSize(width: 1440, height: 2560))
        #expect(abs(readable.scale - 900.0 / 2560) < 1e-9)
        #expect(readable.transform == CGAffineTransform(scaleX: readable.scale, y: readable.scale))

        let exact = CanvasGeometry.previewTransform(
            settings: settings, outputScreenSize: output, showsAsOnTeleprompter: true, in: CGSize(width: 900, height: 900)
        )
        #expect(abs(exact.scale - 900.0 / 2560) < 1e-9)
        #expect(exact.transform == CanvasGeometry.layerTransform(rotation: .quarter, mirror: true, flip: false,
                                                                 scale: exact.scale))
    }

    @Test func fitScaleAndPixelAlignment() {
        #expect(CanvasGeometry.fitScale(CGSize(width: 200, height: 100), in: CGSize(width: 100, height: 100)) == 0.5)
        #expect(CanvasGeometry.fitScale(CGSize(width: 100, height: 50), in: CGSize(width: 400, height: 400)) == 4)
        #expect(CanvasGeometry.fitScale(.zero, in: CGSize(width: 10, height: 10)) == 0)
        #expect(CanvasGeometry.pixelAligned(10.3, pixelsPerPoint: 2) == 10.5)
        #expect(CanvasGeometry.pixelAligned(10.2, pixelsPerPoint: 1) == 10)
        #expect(CanvasGeometry.pixelAligned(7, pixelsPerPoint: 0) == 7)
    }
}

// MARK: - Words, keys, options

struct PresenterStatusTests {
    @Test func stateWords() {
        #expect(PresenterStatus.stateWord(for: .idle) == "Ready")
        #expect(PresenterStatus.stateWord(for: .countdown(3)) == "Starting 3")
        #expect(PresenterStatus.stateWord(for: .playing) == "Playing")
        #expect(PresenterStatus.stateWord(for: .playing, holdSeconds: 2) == "Pause 2")
        #expect(PresenterStatus.stateWord(for: .paused) == "Paused")
        #expect(PresenterStatus.stateWord(for: .finished) == "End")
    }

    @Test func thePrimaryButtonSaysWhatItWillDo() {
        #expect(PresenterStatus.primaryAction(for: .idle) == "Start")
        #expect(PresenterStatus.primaryAction(for: .countdown(2)) == "Cancel")
        #expect(PresenterStatus.primaryAction(for: .playing) == "Pause")
        #expect(PresenterStatus.primaryAction(for: .paused) == "Resume")
        #expect(PresenterStatus.primaryAction(for: .finished) == "Restart")
    }

    @Test func hudWordsAndPercent() {
        #expect(PresenterStatus.hudWord(for: .idle) == "Press Space to start")
        #expect(PresenterStatus.hudWord(for: .playing) == nil)
        #expect(PresenterStatus.hudWord(for: .countdown(1)) == nil)
        #expect(PresenterStatus.hudWord(for: .playing, holdSeconds: 3) == "Pause 3")
        #expect(PresenterStatus.percent(0.629) == "62%")
        #expect(PresenterStatus.percent(1.5) == "100%")
        #expect(PresenterStatus.percent(.nan) == "0%")
    }

    @Test func countdownSoundsFollowTheBeepSetting() {
        var settings = PrompterSettings()
        settings.countdownSeconds = 3
        settings.countdownBeep = true
        #expect(MacPrompterFeedback.sound(for: .countdownTick(3), settings: settings) == .tick)
        #expect(MacPrompterFeedback.sound(for: .go, settings: settings) == .go)
        #expect(MacPrompterFeedback.sound(for: .paused, settings: settings) == nil)
        settings.countdownBeep = false
        #expect(MacPrompterFeedback.sound(for: .go, settings: settings) == nil)
    }
}

struct PresenterKeyRoutingTests {
    private typealias Key = MacKeyMap.KeyCode

    @Test func presentingWindowsTakeThePrompterKeys() {
        #expect(PresenterKeyRouting.action(keyCode: Key.space, modifiers: [], target: .presenting, isEditingText: false)
            == .togglePlay)
        #expect(PresenterKeyRouting.action(keyCode: Key.downArrow, modifiers: [.shift], target: .presenting,
                                           isEditingText: false) == .stepParagraph(1))
        #expect(PresenterKeyRouting.action(keyCode: Key.pageUp, modifiers: [], target: .presenting, isEditingText: false)
            == .stepLine(-1))
        #expect(PresenterKeyRouting.action(keyCode: Key.equal, modifiers: [.shift], target: .presenting,
                                           isEditingText: false) == .speedStep(5))
        #expect(PresenterKeyRouting.action(keyCode: Key.zero, modifiers: [], target: .presenting, isEditingText: false)
            == .backToTop)
        #expect(PresenterKeyRouting.action(keyCode: Key.escape, modifiers: [], target: .presenting, isEditingText: false)
            == .exit)
    }

    @Test func otherWindowsTypingAndShortcutsAreLeftAlone() {
        #expect(PresenterKeyRouting.action(keyCode: Key.space, modifiers: [], target: .otherWindow, isEditingText: false)
            == nil)
        #expect(PresenterKeyRouting.action(keyCode: Key.escape, modifiers: [], target: .presenting, isEditingText: true)
            == nil)
        #expect(PresenterKeyRouting.action(keyCode: Key.zero, modifiers: [.command], target: .presenting,
                                           isEditingText: false) == nil)
        #expect(PresenterKeyRouting.action(keyCode: 0, modifiers: [], target: .presenting, isEditingText: false) == nil)
    }

    @Test func focusedControlsKeepTheirOwnKeys() {
        // A focused slider keeps ← and →; ↑ and ↓ still step the text.
        #expect(PresenterKeyRouting.action(keyCode: Key.leftArrow, modifiers: [], target: .presenting,
                                           isEditingText: false, focusedControl: .slider) == nil)
        #expect(PresenterKeyRouting.action(keyCode: Key.rightArrow, modifiers: [], target: .presenting,
                                           isEditingText: false, focusedControl: .slider) == nil)
        #expect(PresenterKeyRouting.action(keyCode: Key.downArrow, modifiers: [], target: .presenting,
                                           isEditingText: false, focusedControl: .slider) == .stepLine(1))
        #expect(PresenterKeyRouting.action(keyCode: Key.space, modifiers: [], target: .presenting,
                                           isEditingText: false, focusedControl: .slider) == .togglePlay)
        // A focused button keeps Space and Return (Full Keyboard Access presses it); arrows still step the text.
        for key in [Key.space, Key.returnKey, Key.keypadEnter] {
            #expect(PresenterKeyRouting.action(keyCode: key, modifiers: [], target: .presenting,
                                               isEditingText: false, focusedControl: .button) == nil)
        }
        #expect(PresenterKeyRouting.action(keyCode: Key.rightArrow, modifiers: [], target: .presenting,
                                           isEditingText: false, focusedControl: .button) == .stepLine(1))
        #expect(PresenterKeyRouting.action(keyCode: Key.escape, modifiers: [], target: .presenting,
                                           isEditingText: false, focusedControl: .button) == .exit)
    }

    @MainActor
    @Test func focusedControlKinds() {
        #expect(PresenterKeyRouting.focusedControl(NSSlider()) == .slider)
        #expect(PresenterKeyRouting.focusedControl(NSSegmentedControl()) == .slider)
        #expect(PresenterKeyRouting.focusedControl(NSButton()) == .button)
        let disabled = NSButton()
        disabled.isEnabled = false
        #expect(PresenterKeyRouting.focusedControl(disabled) == .none)
        #expect(PresenterKeyRouting.focusedControl(NSTextView()) == .none)
        #expect(PresenterKeyRouting.focusedControl(nil) == .none)
    }

    @Test func escapePausesARunningTakeFirst() {
        #expect(PresenterKeyRouting.escapeOutcome(for: .playing) == .pause)
        #expect(PresenterKeyRouting.escapeOutcome(for: .countdown(3)) == .pause)
        #expect(PresenterKeyRouting.escapeOutcome(for: .paused) == .stopPresenting)
        #expect(PresenterKeyRouting.escapeOutcome(for: .idle) == .stopPresenting)
        #expect(PresenterKeyRouting.escapeOutcome(for: .finished) == .stopPresenting)
    }

    @MainActor
    @Test func onlyEditableTextViewsCountAsTyping() {
        let editable = NSTextView()
        #expect(PresenterKeyRouting.isTextInput(editable))
        editable.isEditable = false
        #expect(!PresenterKeyRouting.isTextInput(editable))
        #expect(!PresenterKeyRouting.isTextInput(NSView()))
        #expect(!PresenterKeyRouting.isTextInput(nil))
    }
}

struct PresenterLaunchOptionsTests {
    @Test func defaults() {
        let options = PresenterLaunchOptions(arguments: ["Prompter"])
        #expect(!options.routesToPrompter)
        #expect(options.script == .newest)
        #expect(options.outputScreen == nil)
        #expect(!options.autoStart)
        #expect(options.snapshotDirectory == nil)
        #expect(options.snapshotTimes == [2, 8])
        #expect(!options.isMuted)
        #expect(!options.singleScreen)
    }

    @Test func everyOption() {
        let options = PresenterLaunchOptions(arguments: [
            "Prompter", "-demoData", "-route", "Prompter", "-script", "SAMPLE", "-outputScreen", "27GL850",
            "-autoStart", "-presenterSettings", "-previewMirrored", "-snapshot", "/tmp/shots",
            "-presenterSnapshots", "1.5, 9,x", "-singleScreen",
        ])
        #expect(options.routesToPrompter)
        #expect(options.script == .sample)
        #expect(options.outputScreen == .name("27GL850"))
        #expect(options.autoStart)
        #expect(options.opensSettings)
        #expect(options.previewMirrored)
        #expect(options.snapshotDirectory?.path(percentEncoded: false).hasPrefix("/tmp/shots") == true)
        #expect(options.snapshotTimes == [1.5, 9])
        #expect(options.isMuted)   // snapshot runs are silent
        #expect(options.singleScreen)
        #expect(PresenterLaunchOptions(arguments: ["-route", "settings"]).routesToPrompter == false)
        #expect(PresenterLaunchOptions(arguments: ["-outputScreen", "1", "-mute"]).outputScreen == .index(1))
        #expect(PresenterLaunchOptions(arguments: ["-mute"]).isMuted)
    }
}

// MARK: - Session and canvas

@MainActor
struct PresenterSessionTests {
    private struct Fixture {
        let session: PresenterSession
        let scriptStore: ScriptStore
        let settingsStore: SettingsStore
        let first: Script
        let second: Script
        let directory: URL
        let suite: String
    }

    private func makeFixture(countdown: Int = 0) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PresenterTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptStore = ScriptStore(directory: directory, initialScripts: { _ in [] })
        let first = scriptStore.create(title: "First", body: Array(repeating: "One two three four five six seven.", count: 30)
            .joined(separator: "\n\n"))
        let second = scriptStore.create(title: "Second", body: "Short and sweet.")
        let suite = "PresenterTests-\(UUID().uuidString)"
        let settingsStore = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        settingsStore.settings.countdownSeconds = countdown
        let session = PresenterSession(
            scriptID: first.id, scriptStore: scriptStore, settingsStore: settingsStore,
            outputScreenSize: CGSize(width: 1920, height: 1080)
        )
        session.isMuted = true
        return Fixture(session: session, scriptStore: scriptStore, settingsStore: settingsStore, first: first,
                       second: second, directory: directory, suite: suite)
    }

    private func cleanUp(_ fixture: Fixture) {
        fixture.session.close()
        try? FileManager.default.removeItem(at: fixture.directory)
        UserDefaults.standard.removePersistentDomain(forName: fixture.suite)
    }

    /// Gives the engine the layout an output canvas of the session's size would.
    private func layOut(_ session: PresenterSession) {
        let style = PrompterTextStyle(settings: session.settings, canvasSize: session.outputScreenSize, isPad: true)
        session.engine.updateLayout(PrompterLayoutExtractor.layout(of: session.document, style: style))
    }

    @Test func opensOnTheScriptWithTheSavedSettings() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        #expect(fixture.session.scriptTitle == "First")
        #expect(fixture.session.document == PrompterDocument(body: fixture.first.body))
        #expect(fixture.session.engine.settings == fixture.settingsStore.settings)
        #expect(fixture.session.engine.state == .idle)
    }

    @Test func settingsChangesReachTheEngine() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        fixture.settingsStore.settings.wordsPerMinute = 200
        // The session follows the store through Observation, on the next main-actor turn.
        for _ in 0..<20 where fixture.session.engine.settings.wordsPerMinute != 200 {
            await Task.yield()
        }
        #expect(fixture.session.engine.settings.wordsPerMinute == 200)
    }

    // MARK: The controller (M8 review)

    @Test func aPresentingControllerIsReleasedOnceItStops() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        // Two made-up screens far from any real one, so the windows open where nobody sees them.
        let screens = [
            DisplayDescriptor(id: 90_001, name: "Test laptop", frame: CGRect(x: -40_000, y: -40_000, width: 1280, height: 800),
                              isBuiltIn: true, hasMenuBar: true),
            DisplayDescriptor(id: 90_002, name: "Test HDMI", frame: CGRect(x: -37_000, y: -40_000, width: 1280, height: 720),
                              isBuiltIn: false, hasMenuBar: false),
        ]
        let suite = "PresentingControllerTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        weak var weakController: PresentingController?
        weak var weakOutput: PrompterCanvasView?
        weak var weakOutputWindow: NSWindow?
        weak var weakPresenterWindow: NSWindow?
        autoreleasepool {
            let controller = PresentingController(session: fixture.session, defaults: defaults, request: nil, screens: screens)
            controller.open()
            weakController = controller
            weakOutput = controller.outputView
            weakOutputWindow = controller.outputWindow
            weakPresenterWindow = controller.presenterWindow
            #expect(controller.plan == DisplayPlan(output: 90_002, presenter: 90_001))
            #expect(controller.outputView != nil && controller.outputWindow != nil && controller.presenterWindow != nil)
            controller.close()
        }
        for _ in 0..<100 where weakController != nil || weakOutput != nil || weakOutputWindow != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(weakController == nil, "the Presenter view no longer keeps its controller alive")
        #expect(weakOutput == nil, "the output canvas (and its text tiles) went with it")
        #expect(weakOutputWindow == nil)
        #expect(weakPresenterWindow == nil)
    }

    @Test func escapePausesATakeThenStopsPresenting() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        layOut(fixture.session)
        let controller = PresentingController(
            session: fixture.session, defaults: .standard, request: nil, screens: []
        )
        var stops = 0
        controller.onStop = { stops += 1 }
        fixture.session.start()
        #expect(fixture.session.engine.state == .playing)
        controller.escape()
        #expect(fixture.session.engine.state == .paused)
        #expect(stops == 0)
        controller.escape()
        #expect(stops == 1)
    }

    @Test func noticesClearThemselves() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let controller = PresentingController(session: fixture.session, defaults: .standard, request: nil, screens: [])
        controller.noticeDuration = .milliseconds(200)
        controller.show(notice: PresentingController.outputConnectedNotice)
        #expect(controller.notice == "Teleprompter screen connected.")
        #expect(controller.isSingleScreen, "no screens: nothing to swap")
        for _ in 0..<100 where controller.notice != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(controller.notice == nil)
    }

    @Test func speedStepsAreSaved() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let before = fixture.settingsStore.settings.wordsPerMinute
        fixture.session.speedStep(5)
        #expect(fixture.settingsStore.settings.wordsPerMinute == before + 10)
        #expect(fixture.session.engine.settings.wordsPerMinute == before + 10)
    }

    @Test func voiceModeScrollsAtTheWPMPaceOnTheMac() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        var settings = fixture.settingsStore.settings
        settings.scrollMode = .voice
        fixture.settingsStore.settings = settings
        let session = PresenterSession(
            scriptID: fixture.first.id, scriptStore: fixture.scriptStore, settingsStore: fixture.settingsStore,
            outputScreenSize: CGSize(width: 1920, height: 1080)
        )
        defer { session.close() }
        #expect(session.engine.isVoiceMode)
        #expect(!session.engine.isFollowingVoice)
    }

    @Test func elapsedCountsPlayingTimeOnlyAndTimeOnlyMovesForward() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let session = fixture.session
        layOut(session)
        session.start()
        #expect(session.engine.state == .playing)
        let start = CACurrentMediaTime()
        session.advance(to: start)
        for step in 1...25 { session.advance(to: start + Double(step) * 0.1) }
        #expect(session.elapsedSeconds == 2)
        let position = session.engine.position
        #expect(position > 0)
        // A frame time from another screen's display link that is behind: ignored.
        session.advance(to: start + 1)
        #expect(session.engine.position == position)

        session.pause()
        for step in 26...60 { session.advance(to: start + Double(step) * 0.1) }
        #expect(session.elapsedSeconds == 2)
        session.backToTop()
        #expect(session.elapsedSeconds == 0)
        #expect(session.engine.position == 0)
    }

    @Test func switchingScriptsStartsTheNewOneFromTheTop() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let session = fixture.session
        layOut(session)
        session.stepLine(3)
        #expect(session.engine.position > 0)
        session.switchScript(to: fixture.second.id)
        #expect(session.scriptID == fixture.second.id)
        #expect(session.scriptTitle == "Second")
        #expect(session.document.text == "Short and sweet.")
        #expect(session.engine.state == .idle)
        #expect(session.engine.position == 0)
        // An unknown script changes nothing.
        session.switchScript(to: UUID())
        #expect(session.scriptID == fixture.second.id)
    }

    @Test func editsToThePresentedScriptShowUp() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        fixture.scriptStore.update(fixture.first.id, title: "Renamed", body: "New words.")
        for _ in 0..<20 where fixture.session.scriptTitle != "Renamed" {
            await Task.yield()
        }
        #expect(fixture.session.scriptTitle == "Renamed")
        #expect(fixture.session.document.text == "New words.")
    }

    @Test func keyActionsDriveTheEngine() throws {
        let fixture = try makeFixture(countdown: 3)
        defer { cleanUp(fixture) }
        let session = fixture.session
        layOut(session)
        session.perform(.togglePlay)
        #expect(session.engine.state == .countdown(3))
        session.perform(.togglePlay)
        #expect(session.engine.state == .idle)
        session.perform(.stepParagraph(1))
        #expect(session.engine.position > 0)
        session.perform(.backToTop)
        #expect(session.engine.position == 0)
        session.perform(.exit)   // the launcher's business; nothing happens here
        #expect(session.engine.state == .idle)
    }
}

@MainActor
struct PrompterCanvasLayersTests {
    private let document = PrompterDocument(body: """
        A first paragraph long enough to wrap across a few lines on the canvas, so there is something to scroll.

        // A note for the presenter
        [pause 2]
        And a second paragraph after the pause, also long enough to wrap onto another line or two.
        """)

    @Test func theCanvasLaysOutExactlyWhatTheEngineExpects() {
        let canvas = PrompterCanvasLayers()
        let settings = PrompterSettings()
        let size = CGSize(width: 2560, height: 1440)
        let layout = canvas.configure(document: document, settings: settings, canvasSize: size, contentsScale: 1)
        let style = PrompterTextStyle(settings: settings, canvasSize: size, isPad: true)
        #expect(layout == PrompterLayoutExtractor.layout(of: document, style: style))
        #expect(layout?.holds.count == 1)
        #expect((layout?.contentHeight ?? 0) > 0)
        // The 72 pt setting scaled to the canvas, as on the iPad.
        #expect(abs(style.fontSize - 72 * 2560.0 / 874) < 0.001)
    }

    @Test func onlyLayoutChangesLayTheTextOutAgain() {
        let canvas = PrompterCanvasLayers()
        var settings = PrompterSettings()
        let size = CGSize(width: 1920, height: 1080)
        #expect(canvas.configure(document: document, settings: settings, canvasSize: size, contentsScale: 2) != nil)
        // Nothing changed, or only the reading line, the dimming or the mirror: the same text.
        #expect(canvas.configure(document: document, settings: settings, canvasSize: size, contentsScale: 2) == nil)
        settings.readingLinePosition = 0.5
        settings.dimmedOpacity = 0.8
        settings.mirrorHorizontal.toggle()
        #expect(canvas.configure(document: document, settings: settings, canvasSize: size, contentsScale: 2) == nil)
        // Bigger text or a new scheme: laid out (and drawn) again.
        settings.fontSize = 100
        #expect(canvas.configure(document: document, settings: settings, canvasSize: size, contentsScale: 2) != nil)
        settings.scheme = .yellowOnBlack
        #expect(canvas.configure(document: document, settings: settings, canvasSize: size, contentsScale: 2) != nil)
        // A sideways canvas: a narrower measure, new lines.
        #expect(canvas.configure(document: document, settings: settings, canvasSize: CGSize(width: 1080, height: 1920),
                                 contentsScale: 2) != nil)
    }

    @Test func showingAPositionKeepsTilesOnlyAroundTheScreen() {
        let canvas = PrompterCanvasLayers()
        let long = PrompterDocument(body: Array(repeating: "Line of words to read aloud.", count: 80).joined(separator: "\n"))
        let size = CGSize(width: 1920, height: 1080)
        canvas.configure(document: long, settings: PrompterSettings(), canvasSize: size, contentsScale: 1)
        let tiles = { canvas.root.sublayers?.first?.sublayers?.count ?? 0 }
        let atTop = tiles()
        #expect(atTop > 0)
        canvas.show(position: canvas.contentHeight / 2)
        // Still only the tiles near the screen, not the whole script.
        let maxTiles = Int((size.height * 2 / PrompterCanvasLayers.tileHeight).rounded(.up)) + 3
        #expect(tiles() <= maxTiles)
        #expect(Double(tiles()) * PrompterCanvasLayers.tileHeight < canvas.contentHeight)
    }
}
