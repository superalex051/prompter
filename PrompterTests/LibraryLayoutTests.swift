import CoreGraphics
import Testing
@testable import Prompter

struct LibraryLayoutTests {
    // Window sizes measured on the iPhone Duo simulator (`-duoProbe`), and the iPhones and iPads the app already ran on.

    @Test func theFoldedDuoGetsTheStack() {
        // Cover screen, held tall and wide: compact width.
        #expect(LibraryLayout.choose(isRegularWidth: false, windowWidth: 466, isPad: false) == .stack)
        #expect(LibraryLayout.choose(isRegularWidth: false, windowWidth: 678, isPad: false) == .stack)
    }

    @Test func theOpenDuoHeldWideGetsTheSplit() {
        #expect(LibraryLayout.choose(isRegularWidth: true, windowWidth: 951, isPad: false) == .split)
    }

    /// The finding: open and tall (669 x 951, regular width) the split view hid the list behind a sidebar button and showed
    /// only "Pick a script or make a new one".
    @Test func theOpenDuoHeldTallGetsTheStackWithTheListShowing() {
        #expect(LibraryLayout.choose(isRegularWidth: true, windowWidth: 669, isPad: false) == .stack)
    }

    @Test func iPhonesKeepWhatTheyHad() {
        // iPhone 17 Pro, portrait and landscape: compact width.
        #expect(LibraryLayout.choose(isRegularWidth: false, windowWidth: 402, isPad: false) == .stack)
        #expect(LibraryLayout.choose(isRegularWidth: false, windowWidth: 874, isPad: false) == .stack)
        // A Pro Max in landscape is regular width and wide: the split, as before.
        #expect(LibraryLayout.choose(isRegularWidth: true, windowWidth: 956, isPad: false) == .split)
    }

    @Test(arguments: [744.0, 820, 1024, 1032, 1366, 678, 500])
    func anIPadAtRegularWidthKeepsTheSplitAtAnyWidth(width: Double) {
        // Includes a half-screen window narrower than the phone minimum (678 pt on a 13 inch iPad in landscape).
        #expect(LibraryLayout.choose(isRegularWidth: true, windowWidth: CGFloat(width), isPad: true) == .split)
    }

    @Test func anIPadAtCompactWidthKeepsTheStack() {
        #expect(LibraryLayout.choose(isRegularWidth: false, windowWidth: 375, isPad: true) == .stack)
        #expect(LibraryLayout.choose(isRegularWidth: false, windowWidth: 1024, isPad: true) == .stack)
    }

    @Test func beforeTheFirstLayoutPassTheSizeClassDecides() {
        #expect(LibraryLayout.choose(isRegularWidth: true, windowWidth: nil, isPad: false) == .split)
        #expect(LibraryLayout.choose(isRegularWidth: false, windowWidth: nil, isPad: false) == .stack)
        #expect(LibraryLayout.choose(isRegularWidth: true, windowWidth: nil, isPad: true) == .split)
    }

    /// Unfolding passed through 382 x 678 and 466 x 678 at regular width for a frame each before the open screen's
    /// 951 x 669 (probe log). The layout must switch once, not flicker to the split and back.
    @Test func unfoldingSwitchesOnceThroughTheMeasuredFrames() {
        let frames: [(regular: Bool, width: CGFloat)] = [(false, 466), (true, 382), (true, 466), (true, 951)]
        let layouts = frames.map { LibraryLayout.choose(isRegularWidth: $0.regular, windowWidth: $0.width, isPad: false) }
        #expect(layouts == [.stack, .stack, .stack, .split])
        #expect(switches(in: layouts) == 1)
    }

    /// Assumed frames: only the unfold was measured. Folding and turning the open Duo could not be captured (the first
    /// probe stalled after the turn, and later Device Hub could not be driven while the Mac was locked).
    @Test func foldingSwitchesOnce() {
        let frames: [(regular: Bool, width: CGFloat)] = [(true, 951), (true, 466), (false, 466)]
        let layouts = frames.map { LibraryLayout.choose(isRegularWidth: $0.regular, windowWidth: $0.width, isPad: false) }
        #expect(switches(in: layouts) == 1)
        #expect(layouts.last == .stack)
    }

    /// Assumed frames, like the fold above.
    @Test func turningTheOpenDuoTallAndBackSwitchesOnceEachWay() {
        let frames: [(regular: Bool, width: CGFloat)] = [(true, 951), (true, 669), (true, 669), (true, 951)]
        let layouts = frames.map { LibraryLayout.choose(isRegularWidth: $0.regular, windowWidth: $0.width, isPad: false) }
        #expect(layouts == [.split, .stack, .stack, .split])
    }

    private func switches(in layouts: [LibraryLayout]) -> Int {
        zip(layouts, layouts.dropFirst()).filter { $0 != $1 }.count
    }
}
