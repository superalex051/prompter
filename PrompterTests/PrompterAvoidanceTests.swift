import CoreGraphics
import Testing
@testable import Prompter

/// The prompter's pieces keep clear of an active fold and of the camera (`PrompterAvoidance`). Sizes are the iPhone
/// Duo's: open 951 × 669 with the fold at x 455…495 (book) or 669 × 951 with it at y 455…495 (tabletop); folded
/// 678 × 466 with the camera in a corner.
struct PrompterAvoidanceTests {
    typealias Avoid = PrompterAvoidance

    static let open = CGSize(width: 951, height: 669)
    static let openTall = CGSize(width: 669, height: 951)
    static let bookFold = CGRect(x: 455, y: 0, width: 40, height: 669)
    static let tabletopFold = CGRect(x: 0, y: 455, width: 669, height: 40)

    // MARK: Countdown

    @Test func countdownStaysCentredWithoutAFold() {
        #expect(Avoid.countdownArea(screen: Self.open, blocks: []) == nil)
        // The cover's camera is not a fold: the digit stays in the middle.
        #expect(Avoid.countdownArea(screen: CGSize(width: 678, height: 466), blocks: [CGRect(x: 29, y: 29, width: 37, height: 37)])
            == nil)
        #expect(Avoid.countdownArea(screen: .zero, blocks: [Self.bookFold]) == nil)
    }

    @Test func countdownGoesBesideABookFoldOnTheTrailingSide() throws {
        let area = try #require(Avoid.countdownArea(screen: Self.open, blocks: [Self.bookFold]))
        // The fold is centred (equal sides), so the trailing one, kept a gap clear of the fold.
        #expect(area == CGRect(x: 503, y: 0, width: 448, height: 669))
        #expect(!area.intersects(Self.bookFold))
    }

    @Test func countdownTakesTheLargerSide() throws {
        let offCentre = CGRect(x: 600, y: 0, width: 40, height: 669)
        let area = try #require(Avoid.countdownArea(screen: Self.open, blocks: [offCentre]))
        #expect(area == CGRect(x: 0, y: 0, width: 592, height: 669))
    }

    @Test func countdownGoesAboveATabletopFold() throws {
        let area = try #require(Avoid.countdownArea(screen: Self.openTall, blocks: [Self.tabletopFold]))
        #expect(area == CGRect(x: 0, y: 0, width: 669, height: 447))
    }

    // MARK: HUD word

    /// "Tap to start" (about 150 pt wide) centred on the open, unmirrored canvas, on the HUD's row at the bottom.
    static let row = CGRect(x: 57, y: 610, width: 837, height: 40)
    static let word = CGRect(x: 400.5, y: 616, width: 150, height: 28)

    @Test func wordStaysPutWithNothingInTheWay() {
        #expect(Avoid.wordShift(word: Self.word, row: Self.row, blocks: [], toScreen: .identity) == 0)
        let camera = CGRect(x: 884, y: 0, width: 37, height: 37)
        #expect(Avoid.wordShift(word: Self.word, row: Self.row, blocks: [camera], toScreen: .identity) == 0)
    }

    @Test func wordStepsOffTheFoldTheShorterWay() {
        // Centred on a centred fold, both ways are as short: it goes to the screen's trailing side.
        let shift = Avoid.wordShift(word: Self.word, row: Self.row, blocks: [Self.bookFold], toScreen: .identity)
        #expect(shift == 495 + 8 - 400.5)
        #expect(!Self.word.offsetBy(dx: shift, dy: 0).intersects(Self.bookFold))
        // A fold off to the left: the word moves right, the short way.
        let left = CGRect(x: 380, y: 0, width: 40, height: 669)
        #expect(Avoid.wordShift(word: Self.word, row: Self.row, blocks: [left], toScreen: .identity) == 420 + 8 - 400.5)
        let right = CGRect(x: 530, y: 0, width: 40, height: 669)
        #expect(Avoid.wordShift(word: Self.word, row: Self.row, blocks: [right], toScreen: .identity) == 530 - 8 - 550.5)
    }

    @Test func mirroredTheTieStillGoesToTheScreensTrailingSide() {
        // Mirrored, the canvas's left is the screen's right, so the word moves left in the canvas.
        let mirror = PrompterCanvasTransform.canvasToScreen(rotation: .none, mirror: true, flip: false, screenSize: Self.open)
        let fold = Self.bookFold.applying(mirror.inverted())       // x 456…496 in the canvas
        let shift = Avoid.wordShift(word: Self.word, row: Self.row, blocks: [fold], toScreen: mirror)
        #expect(shift < 0)
        let onScreen = Self.word.offsetBy(dx: shift, dy: 0).applying(mirror)
        #expect(onScreen.minX >= Self.bookFold.maxX)
    }

    @Test func wordStaysWhenNoMoveAlongTheRowClearsIt() {
        // A band across the whole row (a fold crossing a sideways canvas there): no shift along the row can clear it.
        let band = CGRect(x: 0, y: 600, width: 951, height: 40)
        #expect(Avoid.wordShift(word: Self.word, row: Self.row, blocks: [band], toScreen: .identity) == 0)
    }

    // MARK: Close button

    /// The close button: 44 pt, 12 pt in from the top leading corner of the safe area.
    static let button = CGRect(x: 12, y: 12, width: 44, height: 44)

    @Test func closeButtonStaysWithNothingInTheWay() {
        #expect(Avoid.buttonOffset(button: Self.button, screen: Self.open, blocks: []) == .zero)
        #expect(Avoid.buttonOffset(button: Self.button, screen: Self.open, blocks: [Self.bookFold]) == .zero)
    }

    @Test func closeButtonStepsOffTheCamera() {
        // The cover in landscape right: the camera sits at the top left, 29…66 both ways.
        let camera = CGRect(x: 29, y: 29, width: 37, height: 37)
        let offset = Avoid.buttonOffset(button: Self.button, screen: CGSize(width: 678, height: 466), blocks: [camera])
        // Down and across are as long (66 + 8 − 12); down wins the tie.
        #expect(offset == CGSize(width: 0, height: 62))
        #expect(!Self.button.offsetBy(dx: offset.width, dy: offset.height).intersects(camera))
    }

    @Test func closeButtonTakesTheShorterWay() {
        // A wide, short block: across would be long, down is short.
        let wide = CGRect(x: 0, y: 0, width: 300, height: 30)
        #expect(Avoid.buttonOffset(button: Self.button, screen: Self.open, blocks: [wide]) == CGSize(width: 0, height: 26))
        // A tall, narrow block: across is short.
        let tall = CGRect(x: 0, y: 0, width: 30, height: 300)
        #expect(Avoid.buttonOffset(button: Self.button, screen: Self.open, blocks: [tall]) == CGSize(width: 26, height: 0))
    }
}
