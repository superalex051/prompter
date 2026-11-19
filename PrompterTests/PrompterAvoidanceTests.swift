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

    // MARK: Corner labels

    /// The cover in landscape left, 678 × 466, as measured: the camera at 611,399 37 × 37 inside the status cluster's
    /// region at 594,384 84 × 82, both at the bottom right. The HUD's label row runs 44 pt in from each side, about 420 to
    /// 442 down; time left about 40 pt wide, the speed about 90.
    static let cover = CGSize(width: 678, height: 466)
    static let coverCamera = CGRect(x: 611, y: 399, width: 37, height: 37)
    static let coverCluster = CGRect(x: 594, y: 384, width: 84, height: 82)
    static let labelRow = CGRect(x: 44, y: 420, width: 590, height: 22)

    static func corners(leading: CGFloat = 40, trailing: CGFloat = 90) -> (CGRect, CGRect) {
        let row = labelRow
        return (CGRect(x: row.minX, y: row.minY, width: leading, height: row.height),
                CGRect(x: row.maxX - trailing, y: row.minY, width: trailing, height: row.height))
    }

    @Test func cornerLabelsStayPutWithNothingInTheWay() {
        let (leading, trailing) = Self.corners()
        let none = Avoid.cornerInsets(leading: leading, trailing: trailing, row: Self.labelRow, blocks: [])
        #expect(none.leading == 0 && none.trailing == 0)
        // The camera at the top left (the cover in landscape right) is nowhere near the row.
        let top = Avoid.cornerInsets(leading: leading, trailing: trailing, row: Self.labelRow,
                                     blocks: [CGRect(x: 29, y: 29, width: 37, height: 37), CGRect(x: 0, y: 0, width: 84, height: 82)])
        #expect(top.leading == 0 && top.trailing == 0)
        // The open screen's fold in Book crosses the row in the middle: the state word's business, not the corners'.
        let open = CGRect(x: 57, y: 610, width: 837, height: 40)
        let fold = Avoid.cornerInsets(
            leading: CGRect(x: 57, y: 610, width: 40, height: 40), trailing: CGRect(x: 804, y: 610, width: 90, height: 40),
            row: open, blocks: [Self.bookFold])
        #expect(fold.leading == 0 && fold.trailing == 0)
    }

    /// The finding: on the cover in landscape left the camera sat on the HUD's corner label (the speed with Mirror off).
    /// It comes in just far enough to clear the whole region round the camera, a gap clear.
    @Test func cornerLabelComesInFromTheCamera() {
        let (leading, trailing) = Self.corners()
        let insets = Avoid.cornerInsets(leading: leading, trailing: trailing, row: Self.labelRow,
                                        blocks: [Self.coverCamera, Self.coverCluster])
        #expect(insets.leading == 0)
        #expect(insets.trailing == 634 - (594 - Avoid.gap))
        let moved = trailing.offsetBy(dx: -insets.trailing, dy: 0)
        #expect(!moved.intersects(Self.coverCamera) && !moved.intersects(Self.coverCluster))
    }

    /// Mirrored (the default), the canvas's leading end is the screen's right, so the time left comes in instead.
    @Test func mirroredTheTimeLeftComesInFromTheCamera() {
        let mirror = PrompterCanvasTransform.canvasToScreen(rotation: .none, mirror: true, flip: false, screenSize: Self.cover)
        let blocks = [Self.coverCamera, Self.coverCluster].map { $0.applying(mirror.inverted()) }
        let (leading, trailing) = Self.corners()
        let insets = Avoid.cornerInsets(leading: leading, trailing: trailing, row: Self.labelRow, blocks: blocks)
        #expect(insets.trailing == 0)
        #expect(abs(insets.leading - (84 + Avoid.gap - 44)) < 0.001)
        let onScreen = leading.offsetBy(dx: insets.leading, dy: 0).applying(mirror)
        #expect(onScreen.maxX <= Self.coverCluster.minX - Avoid.gap + 0.001)
    }

    @Test func cornerLabelStaysWhenNoMoveAlongTheRowClearsIt() {
        let (leading, trailing) = Self.corners()
        let band = CGRect(x: 0, y: 410, width: 678, height: 40)
        let insets = Avoid.cornerInsets(leading: leading, trailing: trailing, row: Self.labelRow, blocks: [band])
        #expect(insets.leading == 0 && insets.trailing == 0)
    }

    // MARK: Progress bar

    /// The HUD's 3 pt progress bar on the cover in landscape left: the label row's length, about 453 down.
    static let coverBar = CGRect(x: 44, y: 452, width: 590, height: 3)

    @Test func barStaysWholeWithNothingInTheWay() {
        let none = Avoid.barInsets(bar: Self.coverBar, blocks: [])
        #expect(none.leading == 0 && none.trailing == 0)
        // The cover in landscape right: the camera and its region at the top left, nowhere near the bar.
        let top = Avoid.barInsets(bar: Self.coverBar,
                                  blocks: [CGRect(x: 29, y: 29, width: 37, height: 37), CGRect(x: 0, y: 0, width: 84, height: 82)])
        #expect(top.leading == 0 && top.trailing == 0)
    }

    /// The finding: on the cover in landscape left the bar ran through the region round the camera. Mirror off, the
    /// region is over the bar's trailing end: the bar ends a gap short of it, where the speed label now ends too.
    @Test func barEndsShortOfTheCamera() {
        let insets = Avoid.barInsets(bar: Self.coverBar, blocks: [Self.coverCamera, Self.coverCluster])
        #expect(insets.leading == 0)
        #expect(insets.trailing == 634 - (594 - Avoid.gap))
        let shortened = CGRect(x: Self.coverBar.minX, y: Self.coverBar.minY,
                               width: Self.coverBar.width - insets.trailing, height: Self.coverBar.height)
        #expect(!shortened.intersects(Self.coverCamera) && !shortened.intersects(Self.coverCluster))
        let (leading, trailing) = Self.corners()
        let labels = Avoid.cornerInsets(leading: leading, trailing: trailing, row: Self.labelRow,
                                        blocks: [Self.coverCamera, Self.coverCluster])
        #expect(insets.trailing == labels.trailing)
    }

    /// Mirrored (the default), the canvas's leading end is the screen's right: the bar starts short of the camera there.
    @Test func mirroredTheBarStartsShortOfTheCamera() {
        let mirror = PrompterCanvasTransform.canvasToScreen(rotation: .none, mirror: true, flip: false, screenSize: Self.cover)
        let blocks = [Self.coverCamera, Self.coverCluster].map { $0.applying(mirror.inverted()) }
        let insets = Avoid.barInsets(bar: Self.coverBar, blocks: blocks)
        #expect(insets.trailing == 0)
        #expect(abs(insets.leading - (84 + Avoid.gap - 44)) < 0.001)
        let shortened = CGRect(x: Self.coverBar.minX + insets.leading, y: Self.coverBar.minY,
                               width: Self.coverBar.width - insets.leading, height: Self.coverBar.height)
        let onScreen = shortened.applying(mirror)
        #expect(onScreen.maxX <= Self.coverCluster.minX - Avoid.gap + 0.001)
        #expect(abs(onScreen.minX - 44) < 0.001)
    }

    @Test func aFoldAcrossTheBarLeavesItWhole() {
        // Book: the fold crosses the open screen's bar in the middle, as it crosses the text.
        let openBar = CGRect(x: 57, y: 652, width: 837, height: 3)
        let book = Avoid.barInsets(bar: openBar, blocks: [Self.bookFold])
        #expect(book.leading == 0 && book.trailing == 0)
        let mirror = PrompterCanvasTransform.canvasToScreen(rotation: .none, mirror: true, flip: false, screenSize: Self.open)
        let mirrored = Avoid.barInsets(bar: openBar, blocks: [Self.bookFold.applying(mirror.inverted())])
        #expect(mirrored.leading == 0 && mirrored.trailing == 0)
        // Tabletop, held tall: the fold runs across the middle of the screen, far above the bar.
        let tallBar = CGRect(x: 40, y: 934, width: 589, height: 3)
        let tabletop = Avoid.barInsets(bar: tallBar, blocks: [Self.tabletopFold])
        #expect(tabletop.leading == 0 && tabletop.trailing == 0)
    }

    @Test func barStaysWholeWhenTheBlockCoversAllOfIt() {
        let band = CGRect(x: 0, y: 440, width: 678, height: 26)
        let insets = Avoid.barInsets(bar: Self.coverBar, blocks: [band])
        #expect(insets.leading == 0 && insets.trailing == 0)
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
