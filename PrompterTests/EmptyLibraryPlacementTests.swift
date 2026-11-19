import CoreGraphics
import Testing
@testable import Prompter

/// The empty library's message and buttons keep clear of an active fold (`EmptyLibraryPlacement`). Sizes are the iPhone
/// Duo's open screen held tall, 669 × 951, with the large title above the empty state: the empty state's own space runs
/// from about 130 pt down the window, so the fold at y 455…495 sits at 325…365 in it.
struct EmptyLibraryPlacementTests {
    typealias Place = EmptyLibraryPlacement

    static let bounds = CGRect(x: 0, y: 0, width: 669, height: 787)
    static let fold = CGRect(x: 0, y: 325, width: 669, height: 40)
    /// The message and its three buttons, about 300 pt tall, centred.
    static let block = CGRect(x: 120, y: 243, width: 429, height: 300)

    @Test func nothingMovesWithoutAnActiveFold() {
        #expect(Place.shift(block: Self.block, bounds: Self.bounds, folds: []) == 0)
        // Not measured yet.
        #expect(Place.shift(block: .null, bounds: Self.bounds, folds: [Self.fold]) == 0)
    }

    @Test func aFoldClearOfTheBlockMovesNothing() {
        let low = CGRect(x: 0, y: 700, width: 669, height: 40)
        #expect(Place.shift(block: Self.block, bounds: Self.bounds, folds: [low]) == 0)
    }

    /// The finding: held tall and partly folded, the fold ran through the centred message and buttons. They move the
    /// shorter way, here down, to a gap below the fold.
    @Test func theBlockStepsOffTheFoldTheShorterWay() {
        let shift = Place.shift(block: Self.block, bounds: Self.bounds, folds: [Self.fold])
        #expect(shift == 365 + Place.gap - 243)
        let moved = Self.block.offsetBy(dx: 0, dy: shift)
        #expect(!moved.intersects(Self.fold))
        #expect(Self.bounds.contains(moved))
        // A fold over the block's lower part: up is shorter.
        let lower = CGRect(x: 0, y: 500, width: 669, height: 40)
        let up = Place.shift(block: Self.block, bounds: Self.bounds, folds: [lower])
        #expect(up == 500 - Place.gap - 543)
        #expect(!Self.block.offsetBy(dx: 0, dy: up).intersects(lower))
    }

    @Test func aTieGoesDown() {
        // The fold right through the middle of the block: both ways are as long.
        let middle = CGRect(x: 0, y: 373, width: 669, height: 40)
        let shift = Place.shift(block: Self.block, bounds: Self.bounds, folds: [middle])
        #expect(shift == 413 + Place.gap - 243)
    }

    @Test func theBlockStaysInsideTheWindow() {
        // Down would run off the bottom, so it goes up even though that is farther.
        let short = CGRect(x: 0, y: 0, width: 669, height: 640)
        let fold = CGRect(x: 0, y: 310, width: 669, height: 40)
        let shift = Place.shift(block: Self.block, bounds: short, folds: [fold])
        #expect(shift == 310 - Place.gap - 543)
        #expect(short.contains(Self.block.offsetBy(dx: 0, dy: shift)))
        // Neither way fits: it stays where it is.
        let tiny = CGRect(x: 0, y: 0, width: 669, height: 400)
        let middle = CGRect(x: 0, y: 180, width: 669, height: 40)
        let block = CGRect(x: 120, y: 50, width: 429, height: 300)
        #expect(Place.shift(block: block, bounds: tiny, folds: [middle]) == 0)
    }

    /// The finding: on the Duo in the laptop pose the move nudged the measured block by a pixel's rounding, which moved
    /// it again, without end, and the app hung. Only a real change of the block counts.
    @Test func onlyARealChangeOfTheBlockCounts() {
        #expect(Place.isNewBlock(Self.block, replacing: .null))
        #expect(Place.isNewBlock(.null, replacing: Self.block))
        #expect(!Place.isNewBlock(.null, replacing: .null))
        #expect(!Place.isNewBlock(Self.block, replacing: Self.block))
        #expect(!Place.isNewBlock(Self.block.offsetBy(dx: 0, dy: 1e-12), replacing: Self.block))
        #expect(!Place.isNewBlock(Self.block.offsetBy(dx: 0, dy: 0.34), replacing: Self.block))
        #expect(!Place.isNewBlock(Self.block.insetBy(dx: 0.5, dy: 0.5), replacing: Self.block))
        // The delete banner coming or going changes the space, and the block re-centres: a real change.
        #expect(Place.isNewBlock(Self.block.offsetBy(dx: 0, dy: -30), replacing: Self.block))
        #expect(Place.isNewBlock(Self.block.insetBy(dx: 0, dy: -20), replacing: Self.block))
    }

    @Test func aFoldRunningTopToBottomIsLeftToTheSplitView() {
        // Book, held wide: the fold runs down the window; the split view puts its columns either side of it.
        let book = CGRect(x: 75, y: 0, width: 40, height: 669)
        #expect(Place.shift(block: CGRect(x: 60, y: 180, width: 429, height: 300),
                            bounds: CGRect(x: 0, y: 0, width: 571, height: 669), folds: [book]) == 0)
    }
}
