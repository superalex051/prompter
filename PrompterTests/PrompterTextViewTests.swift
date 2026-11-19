import Testing
import UIKit
@testable import Prompter

/// The text view feeding the engine, without a window (no display link): layout passes, relayout anchoring, pending start.
@MainActor
struct PrompterTextViewTests {
    private static let body = DemoData.scripts(now: Date(timeIntervalSince1970: 0))[0].body

    private func makeView(settings: PrompterSettings = PrompterSettings()) -> (PrompterController, PrompterTextView) {
        let controller = PrompterController(scriptTitle: "Test", body: Self.body, settings: settings)
        let view = PrompterTextView(engine: controller.engine)
        controller.textView = view
        view.update(document: controller.document, settings: settings)
        return (controller, view)
    }

    @Test func controllerShowsTheScriptWithoutBlankLines() {
        let controller = PrompterController(scriptTitle: "T", body: "One\n\nTwo\n", settings: PrompterSettings())
        #expect(controller.text == "One\nTwo")
        #expect(!controller.isEmpty)
        #expect(PrompterController(scriptTitle: "T", body: " \n", settings: PrompterSettings()).isEmpty)
    }

    @Test func noLayoutUntilTheViewHasASize() {
        let (controller, _) = makeView()
        #expect(controller.engine.layout == .empty)
    }

    @Test func layoutPassFeedsTheEngine() {
        let (controller, view) = makeView()
        view.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
        view.layoutIfNeeded()
        let layout = controller.engine.layout
        #expect(layout.lines.count > 10)
        #expect(layout.contentHeight > 0)
        #expect(layout.wordCount == ReadingStats.wordCount(of: controller.text))
        #expect(controller.engine.remainingSeconds > 0)
    }

    @Test func startBeforeTheFirstLayoutWaitsThenCountsDown() {
        let (controller, view) = makeView()
        controller.engine.start()
        #expect(controller.engine.state == .idle)
        view.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
        view.layoutIfNeeded()
        #expect(controller.engine.state == .countdown(5))
    }

    @Test func fontChangeKeepsTheSameLineAtTheReadingLine() throws {
        let settings = PrompterSettings()
        let (controller, view) = makeView(settings: settings)
        view.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
        view.layoutIfNeeded()
        let engine = controller.engine
        engine.stepLine(7)
        let before = engine.layout.characterIndex(at: engine.position)
        #expect(before > 0)

        var bigger = settings
        bigger.fontSize = 110
        view.update(document: controller.document, settings: bigger)
        let after = engine.layout.characterIndex(at: engine.position)
        // The line now at the reading line contains the character that was there before.
        let index = try #require(engine.layout.lineIndex(at: engine.position))
        let nextStart = index + 1 < engine.layout.lines.count ? engine.layout.lines[index + 1].characterIndex : Int.max
        #expect(after <= before && before < nextStart)
        #expect(engine.state == .idle)
    }

    enum LookChange: String, Sendable, CaseIterable {
        case yellowOnBlack, blackOnWhite, readingLine
    }

    /// Changing only the colours replaces the attributed string. TextKit 2 then lays out lazily again and estimates
    /// everything above the viewport, so deep in a long script the line it draws at the reading line could be a different
    /// one from the engine's. The view must lay the whole document out again (and the engine keep its place). Moving the
    /// reading line only changes the text container inset, which keeps TextKit's layout; it is checked here too.
    @Test(arguments: LookChange.allCases)
    func lookChangeDeepInALongScriptDrawsTheEnginesLine(change: LookChange) throws {
        let settings = PrompterSettings()
        let longBody = Array(repeating: Self.body, count: 30).joined(separator: "\n\n")
        let controller = PrompterController(scriptTitle: "Long", body: longBody, settings: settings)
        let view = PrompterTextView(engine: controller.engine)
        view.update(document: controller.document, settings: settings)
        view.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
        view.layoutIfNeeded()
        let engine = controller.engine
        let lineCount = engine.layout.lines.count
        #expect(lineCount > 600)
        engine.stepLine(lineCount * 3 / 4)
        // Show that place (without a window there is no display link; a relayout shows the offset).
        var pinched = settings
        pinched.fontSize = settings.fontSize + 1
        view.update(document: controller.document, settings: pinched)
        view.update(document: controller.document, settings: settings)
        view.layoutIfNeeded()
        let layoutBefore = engine.layout
        let positionBefore = engine.position
        let expected = try Self.drawnLineAtReadingLine(of: view)
        #expect(expected.characterIndex == layoutBefore.characterIndex(at: positionBefore))

        var changed = settings
        switch change {
        case .yellowOnBlack: changed.scheme = .yellowOnBlack
        case .blackOnWhite: changed.scheme = .blackOnWhite
        case .readingLine: changed.readingLinePosition = 0.5
        }
        view.update(document: controller.document, settings: changed)
        view.layoutIfNeeded()

        #expect(engine.layout == layoutBefore)
        #expect(engine.position == positionBefore)
        #expect(engine.state == .idle)
        let drawn = try Self.drawnLineAtReadingLine(of: view)
        #expect(drawn.characterIndex == engine.layout.characterIndex(at: engine.position))
        #expect(abs(drawn.y - (engine.layout.lineIndex(at: engine.position).map { engine.layout.lines[$0].y } ?? -1)) < 1)
    }

    /// The line TextKit currently has at the reading line (from whatever layout it holds, estimated or not): its first
    /// character and its top in text-container coordinates.
    private static func drawnLineAtReadingLine(of view: PrompterTextView) throws -> (characterIndex: Int, y: Double) {
        let textView = try #require(view.subviews.compactMap { $0 as? UITextView }.first)
        let layoutManager = try #require(textView.textLayoutManager)
        let contentManager = try #require(layoutManager.textContentManager)
        // The reading line is at contentOffset.y + inset.top in the text view, i.e. contentOffset.y in the container.
        let y = textView.contentOffset.y
        let fragment = try #require(layoutManager.textLayoutFragment(for: CGPoint(x: 1, y: y + 0.5)))
        let frame = fragment.layoutFragmentFrame
        let elementOffset = contentManager.offset(
            from: layoutManager.documentRange.location, to: fragment.rangeInElement.location
        )
        let line = try #require(fragment.textLineFragments.last { frame.minY + $0.typographicBounds.minY <= y + 0.5 })
        return (elementOffset + line.characterRange.location, frame.minY + line.typographicBounds.minY)
    }

    @Test func rotationRelayoutKeepsTheAnchorToo() throws {
        let (controller, view) = makeView()
        view.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
        view.layoutIfNeeded()
        let engine = controller.engine
        engine.stepParagraph(2)
        let before = engine.layout.characterIndex(at: engine.position)
        view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        view.layoutIfNeeded()
        let index = try #require(engine.layout.lineIndex(at: engine.position))
        let line = engine.layout.lines[index]
        let nextStart = index + 1 < engine.layout.lines.count ? engine.layout.lines[index + 1].characterIndex : Int.max
        #expect(line.characterIndex <= before && before < nextStart)
    }
}

/// A script with a note and a pause cue, through the real text view.
@MainActor
struct PrompterTextViewMarkupTests {
    @Test func layoutTimesTextWordsOnlyAndCarriesTheHold() throws {
        let body = "Hey, welcome back.\n// Look at the lens.\n[pause 2]\nToday I'm showing you the rig."
        let controller = PrompterController(scriptTitle: "Markup", body: body, settings: PrompterSettings())
        let view = PrompterTextView(engine: controller.engine)
        view.update(document: controller.document, settings: PrompterSettings())
        view.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
        view.layoutIfNeeded()

        let layout = controller.engine.layout
        #expect(controller.text == "Hey, welcome back.\nLook at the lens.\nPAUSE 2s\nToday I'm showing you the rig.")
        #expect(layout.wordCount == 9)
        #expect(layout.wordCount == ReadingStats(text: body).wordCount)
        let cueIndex = (controller.text as NSString).range(of: "PAUSE 2s").location
        let hold = try #require(layout.holds.first)
        #expect(layout.holds.count == 1)
        #expect(hold.characterIndex == cueIndex)
        #expect(hold.seconds == 2)
        #expect(layout.lines.contains { $0.characterIndex == cueIndex && $0.y == hold.y })
        // Steps land on the note and the cue like on any paragraph.
        controller.engine.stepParagraph(2)
        #expect(controller.engine.position == hold.y)
    }
}

/// The text view on a foldable (iPhone Duo): the font follows the canvas, and a fold keeps the exact place.
@MainActor
struct PrompterTextViewFoldTests {
    private static let body = DemoData.scripts(now: Date(timeIntervalSince1970: 0))[0].body

    private func makeView(foldable: Bool) -> (PrompterController, PrompterTextView) {
        let controller = PrompterController(scriptTitle: "Test", body: Self.body, settings: PrompterSettings())
        let view = PrompterTextView(engine: controller.engine)
        controller.textView = view
        view.anchorsReadingPoint = foldable
        view.update(document: controller.document, settings: PrompterSettings())
        return (controller, view)
    }

    private func layOut(_ view: PrompterTextView, _ width: Double, _ height: Double) {
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.layoutIfNeeded()
    }

    private func fontSize(of view: PrompterTextView) throws -> Double {
        let textView = try #require(view.subviews.compactMap { $0 as? UITextView }.first)
        let font = try #require(textView.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        return font.pointSize
    }

    /// The open Duo's canvas (951 × 669) gets the iPad's scaling; folded (678 × 466, 466 × 678) and every iPhone canvas
    /// stay at the set size. These tests run on an iPhone simulator, so the idiom is phone throughout.
    @Test func textSizeFollowsTheCanvas() throws {
        let (_, view) = makeView(foldable: true)
        layOut(view, 874, 402)
        #expect(try fontSize(of: view) == 72)
        layOut(view, 678, 466)
        #expect(try fontSize(of: view) == 72)
        layOut(view, 951, 669)
        #expect(abs(try fontSize(of: view) - 72 * 951 / 874) < 0.001)
        layOut(view, 669, 951)
        #expect(abs(try fontSize(of: view) - 72 * 951 / 874) < 0.001)
        layOut(view, 466, 678)
        #expect(try fontSize(of: view) == 72)
    }

    /// Unfolding passes through several widths (probe: 466, 382, 466, 951 pt); folding comes back. With the reading point
    /// on, the character at the reading line is the same at every step, and back at the first size so is the position.
    @Test func aFoldAndBackKeepsTheExactPlace() throws {
        let (controller, view) = makeView(foldable: true)
        let engine = controller.engine
        layOut(view, 678, 466)
        engine.stepLine(9)
        engine.scrub(by: 37)                    // part way down a line
        let start = engine.position
        let point = try #require(engine.layout.readingPoint(at: start))
        for (width, height) in [(382.0, 678.0), (466, 678), (951, 669), (669, 951), (678, 466)] {
            layOut(view, width, height)
            #expect(abs(try #require(engine.layout.readingPoint(at: engine.position)) - point) < 1e-6)
        }
        #expect(abs(engine.position - start) < 0.5)
    }
}
