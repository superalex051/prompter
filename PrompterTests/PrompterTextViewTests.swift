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
    static func drawnLineAtReadingLine(of view: PrompterTextView) throws -> (characterIndex: Int, y: Double) {
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

    /// SwiftUI can hand the view new settings after resizing it but before the layout pass (iPhone Duo: folded back to
    /// the cover, then opened to Book with Landscape only on). The engine must get the layout TextKit draws at the new
    /// size, not one measured at the old width, or the take scrolls past the drawn text into blank.
    @Test func settingsBeforeTheLayoutPassMeasureTheNewSize() throws {
        let (controller, view) = makeView(foldable: true)
        let engine = controller.engine
        layOut(view, 466, 678)
        engine.stepLine(40)
        let point = try #require(engine.layout.readingPoint(at: engine.position))

        view.frame = CGRect(x: 0, y: 0, width: 669, height: 951)
        view.update(document: controller.document, settings: PrompterSettings())
        view.layoutIfNeeded()

        let (fresh, freshView) = makeView(foldable: true)
        layOut(freshView, 669, 951)
        #expect(engine.layout.lines.count == fresh.engine.layout.lines.count)
        #expect(abs(engine.layout.contentHeight - fresh.engine.layout.contentHeight) < 0.5)
        #expect(abs(try #require(engine.layout.readingPoint(at: engine.position)) - point) < 1e-6)
        let drawn = try PrompterTextViewTests.drawnLineAtReadingLine(of: view)
        #expect(drawn.characterIndex == engine.layout.characterIndex(at: engine.position))
    }
}

/// New text laid out while the text view was still scrolled deep into the old one: TextKit 2 drew a block of paragraphs
/// hundreds of points away from where the whole-document layout (the engine's) had them, so the take read through the
/// wrong text. These replay the iPhone Duo walk that showed it (cover 466 × 678, open 951 × 669 or 669 × 951) and an
/// iPhone take, scrolling on in small steps like the display link, and check every line TextKit has against the engine's.
@MainActor
struct PrompterTextViewDeepRelayoutTests {
    private func makeView(body: String, foldable: Bool) throws -> (PrompterController, PrompterTextView, UITextView) {
        let controller = PrompterController(scriptTitle: "Test", body: body, settings: PrompterSettings())
        let view = PrompterTextView(engine: controller.engine)
        view.anchorsReadingPoint = foldable
        view.update(document: controller.document, settings: PrompterSettings())
        let textView = try #require(view.subviews.compactMap { $0 as? UITextView }.first)
        return (controller, view, textView)
    }

    private func layOut(_ view: PrompterTextView, _ width: Double, _ height: Double) {
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.layoutIfNeeded()
    }

    /// The engine lines whose top in TextKit's current layout is more than a point from the engine's (or not laid out).
    private func misplacedLines(_ engine: ScrollEngine, _ textView: UITextView) throws -> [Int] {
        let manager = try #require(textView.textLayoutManager)
        let content = try #require(manager.textContentManager)
        let start = manager.documentRange.location
        var tops: [Int: Double] = [:]
        manager.enumerateTextLayoutFragments(from: start, options: []) { fragment in
            let offset = content.offset(from: start, to: fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                tops[offset + line.characterRange.location] = fragment.layoutFragmentFrame.minY + line.typographicBounds.minY
            }
            return true
        }
        return engine.layout.lines.indices.filter { index in
            let line = engine.layout.lines[index]
            return tops[line.characterIndex].map { abs($0 - line.y) > 1 } ?? true
        }
    }

    /// Scrolls on to `position` in 20 pt steps, showing each step the way the display link does, and expects the line
    /// TextKit has at the reading line to be the engine's (one line either side: a paragraph gap belongs to the line above
    /// in the engine and to the next paragraph in TextKit).
    private func play(_ engine: ScrollEngine, _ textView: UITextView, to position: Double) throws {
        while engine.position < min(position, engine.maxPosition - 20) {
            engine.scrub(by: 20)
            textView.contentOffset = CGPoint(x: 0, y: (engine.position * 3).rounded() / 3)
            textView.layoutIfNeeded()
            guard let drawnLine = drawnLine(engine, textView) else { continue }
            let ownLine = try #require(engine.layout.lineIndex(at: engine.position))
            #expect(abs(drawnLine - ownLine) <= 1, "at \(Int(engine.position)): TextKit draws line \(drawnLine), the engine is on \(ownLine)")
            if abs(drawnLine - ownLine) > 1 { return }
        }
        let misplaced = try misplacedLines(engine, textView)
        #expect(misplaced.isEmpty, "lines \(misplaced) out of place at \(Int(engine.position))")
    }

    /// Every line where the engine has it, right after a relayout.
    private func expectInPlace(_ engine: ScrollEngine, _ textView: UITextView, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let misplaced = try misplacedLines(engine, textView)
        #expect(misplaced.isEmpty, "lines \(misplaced) out of place after the relayout", sourceLocation: sourceLocation)
    }

    /// The engine's index of the line TextKit has at the reading line; nil in a gap between paragraphs.
    private func drawnLine(_ engine: ScrollEngine, _ textView: UITextView) -> Int? {
        let y = textView.contentOffset.y + 0.5
        guard let manager = textView.textLayoutManager, let content = manager.textContentManager,
              let fragment = manager.textLayoutFragment(for: CGPoint(x: 1, y: y)),
              let line = fragment.textLineFragments.last(where: { fragment.layoutFragmentFrame.minY + $0.typographicBounds.minY <= y })
        else { return nil }
        let character = content.offset(from: manager.documentRange.location, to: fragment.rangeInElement.location)
            + line.characterRange.location
        return engine.layout.lines.lastIndex { $0.characterIndex <= character }
    }

    struct Walk: Sendable, CustomTestStringConvertible {
        let foldBackAt: Double
        let bookAt: Double
        let tall: Bool
        var testDescription: String { "fold back at \(Int(foldBackAt)), Book at \(Int(bookAt)) \(tall ? "tall" : "wide")" }
    }

    /// Each of these drew a paragraph or more out of place before the fix (the first is the Book step of the iPhone Duo
    /// walk with Landscape only off, 5 lines ahead; the second its fold back to the cover, 10 lines ahead).
    @Test(arguments: [
        Walk(foldBackAt: 2530, bookAt: 6685, tall: false),
        Walk(foldBackAt: 2972, bookAt: 6685, tall: false),
        Walk(foldBackAt: 2530, bookAt: 6685, tall: true),
        Walk(foldBackAt: 2530, bookAt: 7400, tall: true),
    ])
    func aFoldDeepInATakeDrawsEveryLineWhereTheEngineHasIt(walk: Walk) throws {
        let (controller, view, textView) = try makeView(body: SampleScript.body, foldable: true)
        let engine = controller.engine
        layOut(view, 466, 678)
        try play(engine, textView, to: 496)
        layOut(view, 951, 669)
        try expectInPlace(engine, textView)
        try play(engine, textView, to: walk.foldBackAt)
        layOut(view, 466, 678)
        try expectInPlace(engine, textView)
        try play(engine, textView, to: walk.bookAt)
        if walk.tall { layOut(view, 669, 951) } else { layOut(view, 951, 669) }
        try expectInPlace(engine, textView)
        try play(engine, textView, to: engine.position + 2600)
    }

    /// The same on an iPhone held in landscape: a pinch, then a turn to portrait, deep in a long take (before the fix
    /// TextKit drew line 167 at the reading line for the engine's 127 after the pinch, and 706 for 504 after the turn).
    @Test func aPinchAndATurnDeepInATakeDrawEveryLineWhereTheEngineHasIt() throws {
        let body = Array(repeating: SampleScript.body, count: 4).joined(separator: "\n\n")
        let (controller, view, textView) = try makeView(body: body, foldable: false)
        let engine = controller.engine
        layOut(view, 874, 402)
        try play(engine, textView, to: engine.maxPosition * 0.3)
        var bigger = PrompterSettings()
        bigger.fontSize = 84
        view.update(document: controller.document, settings: bigger)
        try expectInPlace(engine, textView)
        try play(engine, textView, to: engine.maxPosition * 0.65)
        layOut(view, 402, 874)
        try expectInPlace(engine, textView)
        try play(engine, textView, to: engine.maxPosition)
    }
}
