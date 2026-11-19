import Testing
import UIKit
@testable import Prompter

struct PrompterTextTests {
    // MARK: Display text

    @Test func blankLinesAreDroppedAndTrailingSpacesTrimmed() {
        let body = "First paragraph.  \n\n\nSecond line\nThird\t\n   \n"
        #expect(PrompterText.displayText(from: body) == "First paragraph.\nSecond line\nThird")
    }

    @Test func windowsLineEndingsAndLeadingBlankLines() {
        #expect(PrompterText.displayText(from: "\r\n\r\nOne\r\n\r\nTwo") == "One\nTwo")
    }

    @Test func emptyOrWhitespaceBodyIsEmpty() {
        #expect(PrompterText.displayText(from: "").isEmpty)
        #expect(PrompterText.displayText(from: " \n\t\n ").isEmpty)
    }

    @Test func indentationIsKept() {
        #expect(PrompterText.displayText(from: "  Indented\nNext") == "  Indented\nNext")
    }

    // MARK: Style

    @Test func defaultStyleOnIPhoneLandscape() {
        let style = PrompterTextStyle(settings: PrompterSettings(), canvasSize: CGSize(width: 874, height: 402), isPad: false)
        #expect(style.fontSize == 72)
        #expect(abs(style.sideInset - 874 * 0.06) < 0.001)
        #expect(abs(style.readingLineY - 134) < 0.001)
        #expect(style.paragraphSpacing == 36)
        let inset = style.textContainerInset
        #expect(abs(inset.top - 134) < 0.001)
        #expect(abs(inset.top + inset.bottom - 402) < 0.001)
    }

    @Test func iPadScalesTheFontToTheTighterSide() {
        // 13-inch iPad: the long side is the tighter fit (1366 / 874 < 1024 / 402).
        let style = PrompterTextStyle(settings: PrompterSettings(), canvasSize: CGSize(width: 1366, height: 1024), isPad: true)
        #expect(abs(style.fontSize - 72 * 1366 / 874) < 0.001)
        // A wide, short canvas: the short side is the tighter fit.
        #expect(abs(PrompterTextStyle.fontScale(canvasSize: CGSize(width: 2000, height: 600), isPad: true) - 600 / 402) < 0.001)
        // The iPhone 17 Pro itself would be exactly 1.
        #expect(PrompterTextStyle.fontScale(canvasSize: CGSize(width: 874, height: 402), isPad: true) == 1)
        #expect(PrompterTextStyle.fontScale(canvasSize: CGSize(width: 1366, height: 1024), isPad: false) == 1)
        // Portrait or landscape, the same short side.
        let portrait = PrompterTextStyle(settings: PrompterSettings(), canvasSize: CGSize(width: 1024, height: 1366), isPad: true)
        #expect(portrait.fontSize == style.fontSize)
        // Never shrinks below the setting, and an empty size doesn't produce NaN.
        #expect(PrompterTextStyle.fontScale(canvasSize: CGSize(width: 300, height: 200), isPad: true) == 1)
        #expect(PrompterTextStyle.fontScale(canvasSize: .zero, isPad: true) == 1)
    }

    /// The finding: the prompter sized its text from the device idiom, so the open iPhone Duo (a 951 × 669 canvas, idiom
    /// phone) got the iPhone's 72 pt and looked small, with a third more lines on screen. A large canvas now takes the
    /// iPad's scaling; every iPhone canvas, the folded Duo and every iPad keep the size they had.
    @Test(arguments: [
        // (canvas, iPad idiom, scales to the canvas)
        (CGSize(width: 874, height: 402), false, false),     // iPhone 17 Pro, landscape (the rig)
        (CGSize(width: 402, height: 874), false, false),
        (CGSize(width: 956, height: 440), false, false),     // the largest iPhone
        (CGSize(width: 667, height: 375), false, false),
        (CGSize(width: 678, height: 466), false, false),     // iPhone Duo folded, landscape
        (CGSize(width: 466, height: 678), false, false),
        (CGSize(width: 382, height: 678), false, false),     // a size seen half way through an unfold
        (CGSize(width: 951, height: 669), false, true),      // iPhone Duo open
        (CGSize(width: 669, height: 951), false, true),
        (CGSize(width: 900, height: 600), false, true),      // the edge
        (CGSize(width: 900, height: 599.5), false, false),
        (CGSize(width: 1366, height: 1024), true, true),     // iPads, whatever the window
        (CGSize(width: 320, height: 1024), true, true),
        (CGSize.zero, false, false),
    ])
    func largeCanvasTakesTheCanvasScaling(canvas: CGSize, isPad: Bool, scales: Bool) {
        #expect(PrompterTextStyle.scalesToCanvas(isPad: isPad, canvasSize: canvas) == scales)
    }

    @Test func textSizesOnTheDuo() {
        func size(_ width: Double, _ height: Double) -> Double {
            let canvas = CGSize(width: width, height: height)
            let scales = PrompterTextStyle.scalesToCanvas(isPad: false, canvasSize: canvas)
            return PrompterTextStyle(settings: PrompterSettings(), canvasSize: canvas, isPad: scales).fontSize
        }
        #expect(size(874, 402) == 72)                           // the iPhone in the rig: unchanged
        #expect(size(678, 466) == 72)                           // folded
        #expect(abs(size(951, 669) - 72 * 951 / 874) < 0.001)   // open: about 78 pt, the long side is the tighter fit
        #expect(size(669, 951) == size(951, 669))               // open, either way up
    }

    @Test func pinchSizeOverridesTheSettingAndIsClamped() {
        let size = CGSize(width: 874, height: 402)
        #expect(PrompterTextStyle(settings: PrompterSettings(), canvasSize: size, isPad: false, fontSize: 120).fontSize == 120)
        #expect(PrompterTextStyle(settings: PrompterSettings(), canvasSize: size, isPad: false, fontSize: 5).fontSize == 24)
        #expect(PrompterTextStyle(settings: PrompterSettings(), canvasSize: size, isPad: false, fontSize: 900).fontSize == 200)
    }

    @Test func onlyLayoutAffectingChangesNeedARelayout() {
        let size = CGSize(width: 874, height: 402)
        let base = PrompterTextStyle(settings: PrompterSettings(), canvasSize: size, isPad: false)
        var settings = PrompterSettings()
        settings.scheme = .yellowOnBlack
        settings.readingLinePosition = 0.5
        settings.dimmedOpacity = 0.8
        #expect(!PrompterTextStyle(settings: settings, canvasSize: size, isPad: false).needsRelayout(comparedTo: base))
        settings.lineSpacing = 2
        #expect(PrompterTextStyle(settings: settings, canvasSize: size, isPad: false).needsRelayout(comparedTo: base))
        #expect(PrompterTextStyle(settings: PrompterSettings(), canvasSize: CGSize(width: 402, height: 874), isPad: false)
            .needsRelayout(comparedTo: base))
    }

    @Test func colourOnlyChangesStillNeedNewText() {
        let size = CGSize(width: 874, height: 402)
        let base = PrompterTextStyle(settings: PrompterSettings(), canvasSize: size, isPad: false)
        #expect(base.needsNewText(comparedTo: nil))
        #expect(!base.needsNewText(comparedTo: base))
        var settings = PrompterSettings()
        settings.readingLinePosition = 0.5
        settings.dimmedOpacity = 0.8
        #expect(!PrompterTextStyle(settings: settings, canvasSize: size, isPad: false).needsNewText(comparedTo: base))
        settings.scheme = .blackOnWhite
        #expect(PrompterTextStyle(settings: settings, canvasSize: size, isPad: false).needsNewText(comparedTo: base))
        settings = PrompterSettings()
        settings.fontWeight = .bold
        #expect(PrompterTextStyle(settings: settings, canvasSize: size, isPad: false).needsNewText(comparedTo: base))
    }

    @Test func lineSpacingIsExtraSpaceBelowEachLine() {
        var settings = PrompterSettings()
        settings.lineSpacing = 1.0
        let font = UIFont.systemFont(ofSize: 72, weight: .heavy)
        let size = CGSize(width: 874, height: 402)
        #expect(PrompterTextStyle(settings: settings, canvasSize: size, isPad: false).lineSpacing(for: font) == 0)
        settings.lineSpacing = 1.6
        let spacing = PrompterTextStyle(settings: settings, canvasSize: size, isPad: false).lineSpacing(for: font)
        #expect(abs(spacing - 0.6 * font.lineHeight) < 0.001)
    }

    @Test func schemeColours() {
        #expect(PrompterSettings.Scheme.whiteOnBlack.foregroundUIColor == .white)
        #expect(PrompterSettings.Scheme.whiteOnBlack.backgroundUIColor == .black)
        #expect(PrompterSettings.Scheme.blackOnWhite.foregroundUIColor == .black)
        #expect(PrompterSettings.Scheme.blackOnWhite.backgroundUIColor == .white)
        #expect(PrompterSettings.Scheme.yellowOnBlack.backgroundUIColor == .black)
    }
}

/// The TextKit 2 extraction the scroll engine depends on, on a real text view.
@MainActor
struct PrompterLayoutExtractorTests {
    private func layout(of text: String, width: Double = 874, settings: PrompterSettings = PrompterSettings()) -> PrompterLayout {
        let size = CGSize(width: width, height: 402)
        let style = PrompterTextStyle(settings: settings, canvasSize: size, isPad: false)
        let textView = UITextView(usingTextLayoutManager: true)
        textView.frame = CGRect(origin: .zero, size: size)
        textView.textContainer.lineFragmentPadding = 0
        textView.attributedText = PrompterText.attributedString(text, style: style)
        textView.textContainerInset = style.textContainerInset
        textView.layoutIfNeeded()
        guard let manager = textView.textLayoutManager else { return .empty }
        return PrompterLayoutExtractor.layout(of: manager, wordCount: ReadingStats.wordCount(of: text))
    }

    @Test func emptyTextIsEmptyLayout() {
        #expect(layout(of: "") == .empty)
    }

    /// The view-less extraction (Core, used by the Mac) matches what the iPhone's text view lays out.
    @Test func viewlessLayoutMatchesTheTextView() {
        let document = PrompterDocument(body: SampleScript.body)
        let size = CGSize(width: 874, height: 402)
        let style = PrompterTextStyle(settings: PrompterSettings(), canvasSize: size, isPad: false)
        let textView = UITextView(usingTextLayoutManager: true)
        textView.frame = CGRect(origin: .zero, size: size)
        textView.textContainer.lineFragmentPadding = 0
        textView.attributedText = PrompterText.attributedString(document, style: style)
        textView.textContainerInset = style.textContainerInset
        textView.layoutIfNeeded()
        guard let manager = textView.textLayoutManager else {
            Issue.record("no text layout manager")
            return
        }
        let fromView = PrompterLayoutExtractor.layout(of: manager, document: document)
        let viewless = PrompterLayoutExtractor.layout(of: document, style: style)
        #expect(!viewless.lines.isEmpty)
        #expect(viewless == fromView)
    }

    @Test func paragraphsAndWrappedLines() throws {
        let first = "Hey, welcome back. Today I'm showing you the setup I use to talk straight down the lens."
        let second = "It's simpler than it looks."
        let text = first + "\n" + second
        let result = layout(of: text)

        #expect(result.lines.count >= 3)          // the first paragraph wraps at 72 pt
        #expect(result.wordCount == ReadingStats.wordCount(of: text))
        let firstLine = try #require(result.lines.first)
        #expect(firstLine.y == 0)
        #expect(firstLine.characterIndex == 0)
        #expect(firstLine.startsParagraph)
        // y strictly ascending, continuation lines don't start paragraphs, character indexes ascend.
        for (a, b) in zip(result.lines, result.lines.dropFirst()) {
            #expect(b.y > a.y)
            #expect(b.characterIndex > a.characterIndex)
        }
        let paragraphStarts = result.lines.filter(\.startsParagraph)
        #expect(paragraphStarts.count == 2)
        #expect(paragraphStarts.last?.characterIndex == (first as NSString).length + 1)
        let lastLine = try #require(result.lines.last)
        #expect(result.contentHeight >= lastLine.y + lastLine.height)
    }

    @Test func linePitchFollowsTheSpacingSetting() throws {
        let text = String(repeating: "word ", count: 80)
        var tight = PrompterSettings()
        tight.lineSpacing = 1.0
        var loose = PrompterSettings()
        loose.lineSpacing = 2.0
        let tightLayout = layout(of: text, settings: tight)
        let looseLayout = layout(of: text, settings: loose)
        let tightPitch = try #require(tightLayout.lines.dropFirst().first).y
        let loosePitch = try #require(looseLayout.lines.dropFirst().first).y
        #expect(abs(loosePitch / tightPitch - 2) < 0.1)
    }

    @Test func narrowerCanvasWrapsIntoMoreLines() {
        let text = String(repeating: "Prompter keeps your place. ", count: 10)
        #expect(layout(of: text, width: 400).lines.count > layout(of: text, width: 874).lines.count)
    }
}

struct PrompterHUDTextTests {
    @Test func stateWords() {
        #expect(PrompterHUD.stateWord(for: .idle) == "Tap to start")
        #expect(PrompterHUD.stateWord(for: .paused) == "Paused")
        #expect(PrompterHUD.stateWord(for: .finished) == "End")
        #expect(PrompterHUD.stateWord(for: .playing) == nil)
        #expect(PrompterHUD.stateWord(for: .countdown(3)) == nil)
        #expect(PrompterHUD.stateWord(for: .playing, isListening: true) == "Listening…")
        #expect(PrompterHUD.stateWord(for: .playing, holdSeconds: 2, isListening: true) == "Pause 2")
        #expect(PrompterHUD.stateWord(for: .paused, isListening: true) == "Paused")
    }

    @Test func voiceNoticeOnlyInVoiceModeAndNotWhileMoving() {
        let message = "Voice needs microphone access. Scrolling at your set pace instead."
        #expect(PrompterHUD.notice(state: .idle, isVoiceMode: true, problem: .microphoneDenied) == message)
        #expect(PrompterHUD.notice(state: .paused, isVoiceMode: true, problem: .microphoneDenied) == message)
        #expect(PrompterHUD.notice(state: .countdown(3), isVoiceMode: true, problem: .microphoneDenied) == message)
        #expect(PrompterHUD.notice(state: .playing, isVoiceMode: true, problem: .microphoneDenied) == nil)
        #expect(PrompterHUD.notice(state: .idle, isVoiceMode: false, problem: .microphoneDenied) == nil)
        #expect(PrompterHUD.notice(state: .idle, isVoiceMode: true, problem: nil) == nil)
    }

    @Test func accessibilityLabel() {
        // Idle shows "Tap to start", but VoiceOver (and the QA flows) hear the state: "Ready".
        #expect(PrompterHUD.accessibilityText(state: .idle, remainingSeconds: 71, speedLabel: "140 wpm")
            == "Ready, 1:11 left, 140 wpm")
        #expect(PrompterHUD.accessibilityText(state: .paused, remainingSeconds: 72, speedLabel: "140 wpm")
            == "Paused, 1:12 left, 140 wpm")
        #expect(PrompterHUD.accessibilityText(state: .countdown(3), remainingSeconds: 0, speedLabel: "Speed 3.0")
            == "Starting in 3, 0:00 left, Speed 3.0")
        #expect(PrompterHUD.accessibilityText(state: .playing, remainingSeconds: 300, speedLabel: "Finish in 5:00")
            == "Playing, 5:00 left, Finish in 5:00")
        #expect(PrompterHUD.accessibilityText(state: .playing, remainingSeconds: 60, speedLabel: "Voice", isListening: true)
            == "Listening…, 1:00 left, Voice")
        #expect(PrompterHUD.accessibilityText(state: .idle, remainingSeconds: 60, speedLabel: "140 wpm", notice: "Voice stopped listening. Scrolling at your set pace instead.")
            == "Voice stopped listening. Scrolling at your set pace instead. Ready, 1:00 left, 140 wpm")
    }
}

struct PrompterFeedbackTests {
    @Test func beepsOnlyForTheCountdownWhenEnabled() {
        var settings = PrompterSettings()
        settings.countdownSeconds = 5
        settings.countdownBeep = true
        #expect(PrompterFeedback.sound(for: .countdownTick(3), settings: settings) == .tick)
        #expect(PrompterFeedback.sound(for: .go, settings: settings) == .go)
        for event in [ScrollEngine.Event.paused, .resumed, .finished, .jumped] {
            #expect(PrompterFeedback.sound(for: event, settings: settings) == nil)
        }
        #expect(PrompterFeedback.Sound.tick.systemSoundID != PrompterFeedback.Sound.go.systemSoundID)

        settings.countdownBeep = false
        #expect(PrompterFeedback.sound(for: .countdownTick(3), settings: settings) == nil)
        #expect(PrompterFeedback.sound(for: .go, settings: settings) == nil)

        settings.countdownBeep = true
        settings.countdownSeconds = 0
        #expect(PrompterFeedback.sound(for: .go, settings: settings) == nil)
    }
}

struct PrompterOrientationPolicyTests {
    typealias Policy = PrompterOrientationPolicy

    @Test func singleOrientationMasks() {
        #expect(Policy.mask(for: .portrait) == .portrait)
        #expect(Policy.mask(for: .landscapeLeft) == .landscapeLeft)
        #expect(Policy.mask(for: .landscapeRight) == .landscapeRight)
        #expect(Policy.mask(for: .portraitUpsideDown) == .portraitUpsideDown)
        #expect(Policy.mask(for: .unknown) == nil)
    }

    @Test(arguments: [
        // (current interface orientation, side the last take used, side to lock)
        (UIInterfaceOrientation.landscapeLeft, UIInterfaceOrientation?.none, UIInterfaceOrientation.landscapeLeft),
        (.landscapeRight, .landscapeLeft, .landscapeRight),     // already landscape: stay on that side
        (.landscapeLeft, .landscapeRight, .landscapeLeft),
        (.portrait, .landscapeLeft, .landscapeLeft),            // from portrait: the side the last take used
        (.portrait, nil, .landscapeRight),
        (.unknown, nil, .landscapeRight),
        (.portraitUpsideDown, .portrait, .landscapeRight),      // a non-landscape "last side" is ignored
    ])
    func sideToLock(current: UIInterfaceOrientation, last: UIInterfaceOrientation?, expected: UIInterfaceOrientation) {
        #expect(Policy.landscapeSide(current: current, last: last) == expected)
    }

    /// The finding: a `.landscape` mask let the interface flip between the two sides when the phone was picked up and put
    /// down the other way round, turning the text upside down in the glass mid-take. The lock is one side only.
    @Test(arguments: [UIInterfaceOrientation.portrait, .landscapeLeft, .landscapeRight])
    func landscapeOnlyLocksToASingleSide(current: UIInterfaceOrientation) {
        var policy = Policy(defaultMask: .allButUpsideDown)
        let action = policy.prompterOpened(landscapeOnly: true, current: current)
        #expect(policy.mask == .landscapeLeft || policy.mask == .landscapeRight)
        #expect(policy.mask != .landscape)
        #expect(action == .rotate(policy.mask))
        #expect(policy.isLocked)
    }

    @Test func takesInARowStayOnTheSameSide() {
        var policy = Policy(defaultMask: .allButUpsideDown)
        _ = policy.prompterOpened(landscapeOnly: true, current: .landscapeLeft)
        #expect(policy.mask == .landscapeLeft)
        #expect(policy.prompterClosed() == .rotate(.landscapeLeft))
        // Back in the library the interface may be portrait; the next take still opens on the left side.
        #expect(policy.prompterOpened(landscapeOnly: true, current: .portrait) == .rotate(.landscapeLeft))
        #expect(policy.lastSide == .landscapeLeft)
    }

    @Test func closingRestoresTheOrientationFromBeforeThePrompter() {
        var policy = Policy(defaultMask: .allButUpsideDown)
        #expect(policy.prompterOpened(landscapeOnly: true, current: .portrait) == .rotate(.landscapeRight))
        #expect(policy.prompterClosed() == .rotate(.portrait))
        #expect(policy.mask == .allButUpsideDown)
        #expect(!policy.isLocked)
        #expect(policy.prompterClosed() == .none)              // closing twice does nothing more
    }

    /// The finding: turning "Landscape only" off inside the prompter forced the interface back to portrait (and swapped the
    /// settings popover for a sheet mid-edit). Now it only relaxes the mask; the restore waits for the prompter to close.
    @Test func turningLandscapeOnlyOffMidTakeOnlyRelaxesTheMask() {
        var policy = Policy(defaultMask: .allButUpsideDown)
        _ = policy.prompterOpened(landscapeOnly: true, current: .portrait)
        #expect(policy.landscapeOnlyChanged(false, current: .landscapeRight) == .refresh)
        #expect(policy.mask == .allButUpsideDown)
        #expect(policy.landscapeOnlyChanged(false, current: .landscapeRight) == .none)
        // Closing while unlocked leaves the interface following the device.
        #expect(policy.prompterClosed() == .none)
    }

    @Test func turningLandscapeOnlyBackOnLocksTheCurrentSideAndKeepsTheRestore() {
        var policy = Policy(defaultMask: .allButUpsideDown)
        _ = policy.prompterOpened(landscapeOnly: true, current: .portrait)
        _ = policy.landscapeOnlyChanged(false, current: .landscapeRight)
        // The phone was turned over while unlocked: lock to the side it is on now.
        #expect(policy.landscapeOnlyChanged(true, current: .landscapeLeft) == .rotate(.landscapeLeft))
        #expect(policy.landscapeOnlyChanged(true, current: .landscapeLeft) == .none)
        #expect(policy.prompterClosed() == .rotate(.portrait))
    }

    @Test func landscapeOnlyOffNeverLocks() {
        var policy = Policy(defaultMask: .all)
        #expect(policy.prompterOpened(landscapeOnly: false, current: .portrait) == .none)
        #expect(policy.mask == .all)
        #expect(policy.prompterClosed() == .none)
        // Outside the prompter the toggle (app settings) does nothing.
        #expect(policy.landscapeOnlyChanged(true, current: .portrait) == .none)
        #expect(policy.mask == .all)
    }

    // MARK: Foldables (iPhone Duo)

    /// The finding: the screen was read from the window's size alone, so Split View or a pinned video on the inner screen
    /// (a smaller window) read as the cover, and a locked take turned as if folded. A small window counts as the cover
    /// only while the hinge is closed; otherwise the screen is left as it was.
    @Test(arguments: [
        (CGSize(width: 466, height: 678), true, PrompterOrientationPolicy.Screen?.some(.cover)),
        (CGSize(width: 678, height: 466), true, .cover),
        (CGSize(width: 951, height: 669), false, .inner),
        (CGSize(width: 669, height: 951), false, .inner),
        (CGSize(width: 951, height: 669), true, .inner),     // folding: the hinge closed before the window moved
        (CGSize(width: 678, height: 466), false, nil),       // unfolding: the hinge opens before the window moves
        (CGSize(width: 382, height: 678), false, nil),       // half way through an unfold
        (CGSize(width: 475, height: 669), false, nil),       // Split View, half of the inner screen
        (CGSize(width: 951, height: 420), false, nil),       // a video pinned to the top of the inner screen
    ])
    func screenFromTheWindowAndTheHinge(size: CGSize, isHingeClosed: Bool, screen: PrompterOrientationPolicy.Screen?) {
        #expect(Policy.Screen.from(windowSize: size, isHingeClosed: isHingeClosed) == screen)
    }

    /// Measured on the simulator, for one hold of the device: cover portrait with the inner screen's landscape left, cover
    /// landscape left with its portrait upside down. The other two follow the same quarter turn.
    @Test func sameDirectionOnTheOtherScreen() {
        #expect(Policy.sameDirection(as: .portrait, from: .cover, to: .inner) == .landscapeLeft)
        #expect(Policy.sameDirection(as: .landscapeLeft, from: .cover, to: .inner) == .portraitUpsideDown)
        #expect(Policy.sameDirection(as: .landscapeRight, from: .cover, to: .inner) == .portrait)
        #expect(Policy.sameDirection(as: .landscapeLeft, from: .inner, to: .cover) == .portrait)
        #expect(Policy.sameDirection(as: .portraitUpsideDown, from: .inner, to: .cover) == .landscapeLeft)
        #expect(Policy.sameDirection(as: .landscapeRight, from: .cover, to: .cover) == .landscapeRight)
        for orientation in [UIInterfaceOrientation.portrait, .landscapeLeft, .portraitUpsideDown, .landscapeRight] {
            let there = Policy.sameDirection(as: orientation, from: .cover, to: .inner)
            #expect(Policy.sameDirection(as: there, from: .inner, to: .cover) == orientation)
        }
    }

    /// The finding (code reading, then the probe): a take open in the rig locks the inner screen's landscape left. Folding
    /// kept that lock, and the cover, which does follow the lock, showed the text a quarter turn from where it was. Now the
    /// cover turns to the orientation that keeps the text's direction: portrait.
    @Test func foldingAnOpenTakeKeepsTheTextsDirection() {
        var policy = Policy(defaultMask: .allButUpsideDown)
        #expect(policy.prompterOpened(landscapeOnly: true, current: .landscapeLeft) == .rotate(.landscapeLeft))
        #expect(policy.windowChanged(to: .inner, current: .landscapeLeft) == .none)
        // Book posture, Rotate Right on the open screen: still the inner screen, nothing to do.
        #expect(policy.windowChanged(to: .inner, current: .landscapeLeft) == .none)
        #expect(policy.windowChanged(to: .cover, current: .landscapeLeft) == .rotate(.portrait))
        #expect(policy.mask == .portrait)
        #expect(policy.isLocked)
        // The take opened on the inner screen, which ignores the lock: its side isn't remembered for the next take.
        #expect(policy.lastSide == nil)
    }

    /// The finding: the remembered side was one value for both screens, so a take on the inner screen (landscape left,
    /// the side it shows by itself) set the side the next take on the cover locked to, a quarter turn from the take before
    /// it there, with the camera at the bottom. Only the cover's own locks set it now.
    @Test func aTakeOnTheInnerScreenLeavesTheCoversSideAlone() {
        var policy = Policy(defaultMask: .allButUpsideDown, lastSide: .landscapeRight)
        // The open lock runs before the window is reported, so it doesn't know the screen yet.
        _ = policy.prompterOpened(landscapeOnly: true, current: .landscapeLeft)
        #expect(policy.windowChanged(to: .inner, current: .landscapeLeft) == .none)
        #expect(policy.lastSide == .landscapeRight)
        // Landscape only switched off and on again there: still not the cover's choice.
        _ = policy.landscapeOnlyChanged(false, current: .landscapeLeft)
        _ = policy.landscapeOnlyChanged(true, current: .landscapeLeft)
        #expect(policy.lastSide == .landscapeRight)
        _ = policy.prompterClosed()
        // The next take, folded and held upright: back to the cover's own side.
        #expect(policy.prompterOpened(landscapeOnly: true, current: .portrait) == .rotate(.landscapeRight))
        #expect(policy.windowChanged(to: .cover, current: .landscapeRight) == .none)
        #expect(policy.lastSide == .landscapeRight)
    }

    @Test func aTakeOnTheCoverStillSetsTheSide() {
        var policy = Policy(defaultMask: .allButUpsideDown, lastSide: .landscapeRight)
        _ = policy.prompterOpened(landscapeOnly: true, current: .landscapeLeft)
        _ = policy.windowChanged(to: .cover, current: .landscapeLeft)
        #expect(policy.lastSide == .landscapeLeft)
        // A fold mid-take doesn't change it either way. (The cover's landscape left is upside down on the inner screen,
        // which a phone app doesn't support, so the lock stays: see the next test.)
        #expect(policy.windowChanged(to: .inner, current: .portraitUpsideDown) == .none)
        #expect(policy.mask == .landscapeLeft)
        #expect(policy.lastSide == .landscapeLeft)
    }

    /// The finding (code reading): the supported-orientation check ran only for the cover, so unfolding a take locked to
    /// landscape left on the cover set the mask to upside down alone, which an iPhone app never declares (no orientation
    /// in common with its view controllers). Folding back from the inner screen in landscape right then left that mask in
    /// force on the cover. The lock now stays as it was on both screens, and the fold back still maps from what the inner
    /// screen really showed.
    @Test func unfoldingFromTheCoversLandscapeLeftKeepsASupportedLock() {
        var policy = Policy(defaultMask: .allButUpsideDown)
        #expect(policy.prompterOpened(landscapeOnly: true, current: .landscapeLeft) == .rotate(.landscapeLeft))
        #expect(policy.windowChanged(to: .cover, current: .landscapeLeft) == .none)
        // Unfolded: upside down on the inner screen would keep the direction, but a phone app can't have it.
        #expect(policy.windowChanged(to: .inner, current: .landscapeRight) == .none)
        #expect(policy.mask == .landscapeLeft)
        #expect(policy.orientationOnScreen == .landscapeRight)
        // Folded back: the inner screen's landscape right is upside down on the cover too, so the lock still stays.
        #expect(policy.windowChanged(to: .cover, current: .landscapeLeft) == .none)
        #expect(policy.mask == .landscapeLeft)
        // Back on the screen it opened on: closing restores as usual.
        #expect(policy.prompterClosed() == .rotate(.landscapeLeft))
        #expect(policy.mask == .allButUpsideDown)
    }

    /// Whatever the hold on either screen, a fold or an unfold mid-take never leaves the app with an orientation it doesn't
    /// support, and never asks for one.
    @Test(arguments: [UIInterfaceOrientation.landscapeLeft, .landscapeRight])
    func foldsNeverLockAnUnsupportedOrientation(coverSide: UIInterfaceOrientation) {
        let holds: [UIInterfaceOrientation] = [.portrait, .landscapeLeft, .portraitUpsideDown, .landscapeRight]
        for innerHold in holds {
            for coverHold in holds {
                var policy = Policy(defaultMask: .allButUpsideDown)
                var actions = [policy.prompterOpened(landscapeOnly: true, current: coverSide)]
                actions.append(policy.windowChanged(to: .cover, current: coverSide))
                actions.append(policy.windowChanged(to: .inner, current: innerHold))
                actions.append(policy.windowChanged(to: .cover, current: coverHold))
                actions.append(policy.windowChanged(to: .inner, current: innerHold))
                #expect(policy.defaultMask.contains(policy.mask), "inner \(innerHold.rawValue), cover \(coverHold.rawValue)")
                for case .rotate(let requested) in actions {
                    #expect(policy.defaultMask.contains(requested), "inner \(innerHold.rawValue), cover \(coverHold.rawValue)")
                }
            }
        }
    }

    /// The finding: Split View on the inner screen (a 475 pt wide window) read as a fold to the cover. A small window with
    /// the hinge open now leaves the screen as it was: no turn, and closing still restores.
    @Test func splitViewOnTheInnerScreenIsNotAFold() {
        var policy = Policy(defaultMask: .allButUpsideDown)
        _ = policy.prompterOpened(landscapeOnly: true, current: .landscapeLeft)
        _ = policy.windowChanged(to: .inner, current: .landscapeLeft)
        let half = Policy.Screen.from(windowSize: CGSize(width: 475, height: 669), isHingeClosed: false)
        #expect(policy.windowChanged(to: half, current: .landscapeLeft) == .none)
        #expect(policy.screen == .inner)
        #expect(policy.mask == .landscapeLeft)
        #expect(policy.prompterClosed() == .rotate(.landscapeLeft))
    }

    /// Unfolding, the window can still be on the cover while the hinge reads open, and on a fold back the window can reach
    /// the cover before the hinge reads closed. Those reports change nothing, so the fold still maps the orientation the
    /// screen it came from really had.
    @Test func reportsInTheMiddleOfAFoldChangeNothing() {
        var policy = Policy(defaultMask: .allButUpsideDown)
        _ = policy.prompterOpened(landscapeOnly: true, current: .landscapeLeft)
        _ = policy.windowChanged(to: .inner, current: .landscapeLeft)
        // Folding: the window is on the cover (portrait already), the hinge not closed yet.
        #expect(policy.windowChanged(to: nil, current: .portrait) == .none)
        #expect(policy.orientationOnScreen == .landscapeLeft)
        #expect(policy.windowChanged(to: .cover, current: .portrait) == .rotate(.portrait))
    }

    @Test func openedInSplitViewNeverRestoresAnotherScreensOrientation() {
        var policy = Policy(defaultMask: .allButUpsideDown, lastSide: .landscapeRight)
        _ = policy.prompterOpened(landscapeOnly: true, current: .landscapeLeft)
        #expect(policy.windowChanged(to: nil, current: .landscapeLeft) == .none)
        #expect(policy.lastSide == .landscapeRight)          // the device is open: not the cover's choice
        // Folded later: the first screen known is the cover, but the take didn't open there.
        _ = policy.windowChanged(to: .cover, current: .landscapeLeft)
        #expect(policy.prompterClosed() == .refresh)
    }

    /// The finding: the inner screen ignores the lock and can turn over with the device (landscape left to right, same
    /// size). Reported, the fold then maps the side the inner screen really shows: here that is upside down on the cover,
    /// which an iPhone app can't show, so the lock stays rather than locking portrait with the text upside down.
    @Test func aHalfTurnOnTheInnerScreenIsWhatTheFoldUses() {
        var policy = Policy(defaultMask: .allButUpsideDown)
        _ = policy.prompterOpened(landscapeOnly: true, current: .landscapeLeft)
        _ = policy.windowChanged(to: .inner, current: .landscapeLeft)
        #expect(policy.windowChanged(to: .inner, current: .landscapeRight) == .none)
        #expect(policy.orientationOnScreen == .landscapeRight)
        #expect(policy.windowChanged(to: .cover, current: .landscapeLeft) == .none)
        #expect(policy.mask == .landscapeLeft)
    }

    /// The inner screen ignores the app's orientations (measured: locked to landscape right, it showed landscape left). On
    /// an unfold the policy asks once for the same direction and then takes what the inner screen shows.
    @Test func unfoldingAsksOnceThenAcceptsTheInnerScreen() {
        var policy = Policy(defaultMask: .allButUpsideDown)
        #expect(policy.prompterOpened(landscapeOnly: true, current: .portrait) == .rotate(.landscapeRight))
        #expect(policy.windowChanged(to: .cover, current: .landscapeRight) == .none)
        #expect(policy.windowChanged(to: .inner, current: .landscapeLeft) == .rotate(.portrait))
        // Ignored: the inner screen stays wide. No second request.
        #expect(policy.windowChanged(to: .inner, current: .landscapeLeft) == .none)
        // Folded again: the cover takes the direction the inner screen really showed.
        #expect(policy.windowChanged(to: .cover, current: .portrait) == .rotate(.portrait))
    }

    @Test func closingAfterAFoldOnlyRelaxesTheLock() {
        var policy = Policy(defaultMask: .allButUpsideDown)
        _ = policy.prompterOpened(landscapeOnly: true, current: .landscapeLeft)
        _ = policy.windowChanged(to: .inner, current: .landscapeLeft)
        _ = policy.windowChanged(to: .cover, current: .landscapeLeft)
        // The orientation from before the prompter was the inner screen's: not restored on the cover.
        #expect(policy.prompterClosed() == .refresh)
        #expect(policy.mask == .allButUpsideDown)
        #expect(policy.prompterClosed() == .none)
    }

    @Test func closingBackOnTheFirstScreenStillRestores() {
        var policy = Policy(defaultMask: .allButUpsideDown)
        _ = policy.prompterOpened(landscapeOnly: true, current: .portrait)
        _ = policy.windowChanged(to: .cover, current: .landscapeRight)
        _ = policy.windowChanged(to: .inner, current: .landscapeLeft)
        _ = policy.windowChanged(to: .cover, current: .portrait)
        #expect(policy.prompterClosed() == .rotate(.portrait))
    }

    @Test func withoutTheLockAFoldChangesNothing() {
        var policy = Policy(defaultMask: .allButUpsideDown)
        #expect(policy.prompterOpened(landscapeOnly: false, current: .portrait) == .none)
        #expect(policy.windowChanged(to: .cover, current: .portrait) == .none)
        #expect(policy.windowChanged(to: .inner, current: .landscapeLeft) == .none)
        #expect(policy.windowChanged(to: .cover, current: .portrait) == .none)
        #expect(policy.mask == .allButUpsideDown)
        #expect(policy.prompterClosed() == .none)
    }

    @Test func upsideDownOnTheCoverKeepsTheLock() {
        // The inner screen in landscape right matches the cover upside down, which an iPhone app doesn't support.
        var policy = Policy(defaultMask: .allButUpsideDown)
        _ = policy.prompterOpened(landscapeOnly: true, current: .landscapeRight)
        _ = policy.windowChanged(to: .inner, current: .landscapeRight)
        #expect(policy.windowChanged(to: .cover, current: .landscapeRight) == .none)
        #expect(policy.mask == .landscapeRight)
    }

    @Test func outsideThePrompterWindowsOnlyRecord() {
        var policy = Policy(defaultMask: .allButUpsideDown)
        #expect(policy.windowChanged(to: .cover, current: .portrait) == .none)
        #expect(policy.windowChanged(to: .inner, current: .landscapeLeft) == .none)
        #expect(policy.mask == .allButUpsideDown)
    }

    @Test func aSecondOpenKeepsTheFirstRestorePoint() {
        var policy = Policy(defaultMask: .allButUpsideDown)
        _ = policy.prompterOpened(landscapeOnly: true, current: .portrait)
        #expect(policy.prompterOpened(landscapeOnly: true, current: .landscapeRight) == .none)
        #expect(policy.orientationBeforePrompter == .portrait)
        #expect(policy.prompterClosed() == .rotate(.portrait))
    }
}

struct PrompterCanvasTransformTests {
    private let canvas = CGSize(width: 874, height: 402)

    private func map(_ point: CGPoint, _ rotation: PrompterSettings.Rotation, mirror: Bool = false, flip: Bool = false,
                     size: CGSize) -> CGPoint {
        point.applying(PrompterCanvasTransform.make(rotation: rotation, mirror: mirror, flip: flip, canvasSize: size))
    }

    @Test func noRotationNoMirrorIsIdentity() {
        #expect(PrompterCanvasTransform.make(rotation: .none, mirror: false, flip: false, canvasSize: canvas) == .identity)
    }

    @Test func mirrorAndFlipSwapEdgesAboutTheCentre() {
        #expect(map(.zero, .none, mirror: true, size: canvas) == CGPoint(x: 874, y: 0))
        #expect(map(.zero, .none, flip: true, size: canvas) == CGPoint(x: 0, y: 402))
        #expect(map(CGPoint(x: 437, y: 201), .none, mirror: true, flip: true, size: canvas) == CGPoint(x: 437, y: 201))
    }

    @Test func quarterTurnIsExactAndClockwise() {
        let transform = PrompterCanvasTransform.make(rotation: .quarter, mirror: false, flip: false, canvasSize: canvas)
        #expect([transform.a, transform.b, transform.c, transform.d] == [0, 1, -1, 0])
        // A sideways canvas (402 × 874 inside an 874 × 402 screen): its top-left corner lands at the top-right of the
        // area it covers, i.e. clockwise.
        let sideways = CGSize(width: 402, height: 874)
        let topLeft = map(.zero, .quarter, size: sideways)
        let centre = map(CGPoint(x: 201, y: 437), .quarter, size: sideways)
        #expect(centre == CGPoint(x: 201, y: 437))
        #expect(topLeft == CGPoint(x: 201 + 437, y: 437 - 201))
    }

    @Test func halfTurnPlusFlipEqualsMirror() {
        let p = CGPoint(x: 100, y: 50)
        #expect(map(p, .half, mirror: false, flip: true, size: canvas) == map(p, .none, mirror: true, size: canvas))
    }

    @Test func sidewaysRotations() {
        #expect(PrompterCanvasTransform.isSideways(.quarter))
        #expect(PrompterCanvasTransform.isSideways(.threeQuarters))
        #expect(!PrompterCanvasTransform.isSideways(.none))
        #expect(!PrompterCanvasTransform.isSideways(.half))
    }

    // MARK: Screen and canvas points (the fold and the camera are reported in screen points)

    private func toScreen(_ rotation: PrompterSettings.Rotation, mirror: Bool = false, flip: Bool = false,
                          screen: CGSize = CGSize(width: 951, height: 669)) -> CGAffineTransform {
        PrompterCanvasTransform.canvasToScreen(rotation: rotation, mirror: mirror, flip: flip, screenSize: screen)
    }

    @Test func canvasToScreenIsIdentityWithoutTurnsAndMirrorsAboutTheMiddle() {
        #expect(toScreen(.none) == .identity)
        // The open Duo's fold (x 455…495) is centred, so mirroring maps it onto itself, give or take a point.
        let fold = CGRect(x: 455, y: 0, width: 40, height: 669)
        let inCanvas = fold.applying(toScreen(.none, mirror: true).inverted())
        #expect(inCanvas == CGRect(x: 456, y: 0, width: 40, height: 669))
        // An off-centre rect lands on the other side.
        #expect(CGRect(x: 0, y: 0, width: 66, height: 66).applying(toScreen(.none, mirror: true).inverted())
            == CGRect(x: 885, y: 0, width: 66, height: 66))
    }

    @Test func aSidewaysCanvasCoversTheScreenExactly() {
        let screen = CGSize(width: 951, height: 669)
        for rotation in [PrompterSettings.Rotation.quarter, .threeQuarters] {
            let canvas = PrompterCanvasTransform.canvasSize(rotation: rotation, screenSize: screen)
            #expect(canvas == CGSize(width: 669, height: 951))
            let covered = CGRect(origin: .zero, size: canvas).applying(toScreen(rotation, screen: screen))
            #expect(covered == CGRect(origin: .zero, size: screen))
        }
        // A quarter turn is clockwise: the canvas's top left corner is the screen's top right.
        #expect(CGPoint.zero.applying(toScreen(.quarter, screen: screen)) == CGPoint(x: 951, y: 0))
        // So a vertical fold on the screen is a band across the sideways canvas (screen x is 951 minus canvas y).
        let fold = CGRect(x: 455, y: 0, width: 40, height: 669).applying(toScreen(.quarter, screen: screen).inverted())
        #expect(fold == CGRect(x: 0, y: 456, width: 669, height: 40))
    }
}
