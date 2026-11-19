import Testing
@testable import Prompter

struct PrompterLayoutTests {
    /// Five hand-built lines. Paragraphs start at lines 0 and 3, with a 40 pt paragraph gap above line 3.
    ///
    ///     line  y    height  chars
    ///     0     0    100     0…11   ¶
    ///     1     100  100     12…24
    ///     2     200  100     25…39
    ///     (gap  300…340)
    ///     3     340  100     40…51  ¶
    ///     4     440  100     52…
    static let layout = PrompterLayout(
        lines: [
            .init(y: 0, height: 100, characterIndex: 0, startsParagraph: true),
            .init(y: 100, height: 100, characterIndex: 12, startsParagraph: false),
            .init(y: 200, height: 100, characterIndex: 25, startsParagraph: false),
            .init(y: 340, height: 100, characterIndex: 40, startsParagraph: true),
            .init(y: 440, height: 100, characterIndex: 52, startsParagraph: false),
        ],
        contentHeight: 540,
        wordCount: 30
    )

    // MARK: averageLinePitch

    @Test func averageLinePitchIsContentHeightPerLine() {
        #expect(Self.layout.averageLinePitch == 108)
    }

    // MARK: timedHeight

    @Test func timedHeightIsTheSpansOfTheChosenLines() {
        let lines = Self.layout.lines
        // Every line: the whole height.
        #expect(PrompterLayout.timedHeight(of: lines, contentHeight: 540) { _ in true } == 540)
        // Line 2's span runs to line 3's top, so it carries the paragraph gap: 300…340 belongs to it.
        #expect(PrompterLayout.timedHeight(of: lines, contentHeight: 540) { $0.characterIndex == 25 } == 140)
        // The last line runs to the end of the text.
        #expect(PrompterLayout.timedHeight(of: lines, contentHeight: 540) { $0.characterIndex == 52 } == 100)
        #expect(PrompterLayout.timedHeight(of: lines, contentHeight: 540) { _ in false } == 0)
        #expect(PrompterLayout.timedHeight(of: [], contentHeight: 0) { _ in true } == 0)
    }

    @Test func timedHeightDefaultsToTheWholeHeight() {
        #expect(Self.layout.timedHeight == 540)
        #expect(PrompterLayout.empty.timedHeight == 0)
        let withNotes = PrompterLayout(lines: Self.layout.lines, contentHeight: 540, wordCount: 30, timedHeight: 300)
        #expect(withNotes.timedHeight == 300)
    }

    @Test func averageLinePitchIsOneWhenThereIsNothingToMeasure() {
        #expect(PrompterLayout.empty.averageLinePitch == 1)
        let zeroHeight = PrompterLayout(
            lines: [.init(y: 0, height: 0, characterIndex: 0, startsParagraph: true)],
            contentHeight: 0,
            wordCount: 0
        )
        #expect(zeroHeight.averageLinePitch == 1)
    }

    // MARK: lineIndex(at:)

    @Test(arguments: [
        (-50.0, 0),     // above the text → first line
        (0, 0),
        (99.9, 0),
        (100, 1),
        (250, 2),
        (320, 2),       // in the paragraph gap → the line above it
        (340, 3),
        (539, 4),
        (540, 4),       // the very end
        (10_000, 4),    // past the end → last line
        (.nan, 0),
    ])
    func lineIndex(position: Double, expected: Int) {
        #expect(Self.layout.lineIndex(at: position) == expected)
    }

    // MARK: characterIndex(at:)

    @Test(arguments: [
        (-5.0, 0),
        (0, 0),
        (150, 12),
        (320, 25),
        (500, 52),
        (9_999, 52),
    ])
    func characterIndex(position: Double, expected: Int) {
        #expect(Self.layout.characterIndex(at: position) == expected)
    }

    // MARK: position(ofCharacterIndex:)

    @Test(arguments: [
        (-3, 0.0),
        (0, 0),
        (11, 0),
        (12, 100),
        (30, 200),
        (39, 200),
        (40, 340),
        (51, 340),
        (52, 440),
        (1_000, 440),
    ])
    func positionOfCharacter(index: Int, expected: Double) {
        #expect(Self.layout.position(ofCharacterIndex: index) == expected)
    }

    // MARK: Empty layout

    @Test func emptyLayoutAnswersSafely() {
        let empty = PrompterLayout.empty
        #expect(empty.lines.isEmpty)
        #expect(empty.contentHeight == 0)
        #expect(empty.wordCount == 0)
        #expect(empty.lineIndex(at: 0) == nil)
        #expect(empty.lineIndex(at: 500) == nil)
        #expect(empty.characterIndex(at: 500) == 0)
        #expect(empty.position(ofCharacterIndex: 42) == 0)
        #expect(empty.position(of: PrompterLayout.Anchor(characterIndex: 42, fraction: 0.5)) == 0)
    }

    // MARK: Anchors (used to keep the reading line on the same text across relayouts)

    @Test(arguments: [0.0, 50, 150, 320, 340, 500, 540])
    func anchorRoundTripsInTheSameLayout(position: Double) {
        let anchor = Self.layout.anchor(at: position)
        #expect(abs(Self.layout.position(of: anchor) - position) < 1e-9)
    }

    @Test func anchorRecordsLineStartAndFractionOfTheLineSpan() {
        // Line 2 spans 200…340 (its 100 pt plus the 40 pt paragraph gap below it).
        let anchor = Self.layout.anchor(at: 270)
        #expect(anchor.characterIndex == 25)
        #expect(abs(anchor.fraction - 0.5) < 1e-9)
    }

    @Test func anchorClampsOutsideTheText() {
        #expect(Self.layout.anchor(at: -100) == PrompterLayout.Anchor(characterIndex: 0, fraction: 0))
        #expect(Self.layout.anchor(at: 9_999) == PrompterLayout.Anchor(characterIndex: 52, fraction: 1))
        #expect(Self.layout.position(of: Self.layout.anchor(at: 9_999)) == 540)
    }

    @Test func anchorMovesToTheLineThatNowHoldsTheCharacter() {
        // Bigger text: 150 pt lines, 5 characters each, so character 12 (start of line 1) now sits on line 2 (10…14).
        let bigger = PrompterLayout(
            lines: (0..<12).map { .init(y: Double($0) * 150, height: 150, characterIndex: $0 * 5, startsParagraph: $0 == 0) },
            contentHeight: 1_800,
            wordCount: 30
        )
        let anchor = Self.layout.anchor(at: 125)   // a quarter into line 1 (100…200)
        #expect(anchor == PrompterLayout.Anchor(characterIndex: 12, fraction: 0.25))
        #expect(abs(bigger.position(of: anchor) - (300 + 0.25 * 150)) < 1e-9)
        #expect(bigger.lineIndex(at: bigger.position(of: anchor)) == 2)
    }
}

/// The reading point (`PrompterLayout.readingPoint`): the exact character at the reading line, which keeps the place on a
/// foldable, where one fold sends the canvas through several widths in a fraction of a second.
struct PrompterLayoutReadingPointTests {
    /// `PrompterLayoutTests.layout` with its text length known (line 4 runs from character 52 to 64).
    static let layout: PrompterLayout = {
        var layout = PrompterLayoutTests.layout
        layout.characterCount = 64
        return layout
    }()

    /// `characters` UTF-16 characters wrapped `perLine` to a line, `pitch` points apart, the text length known.
    static func wrapped(_ characters: Int, perLine: Int, pitch: Double = 100) -> PrompterLayout {
        let count = (characters + perLine - 1) / perLine
        return PrompterLayout(
            lines: (0..<count).map {
                .init(y: Double($0) * pitch, height: pitch, characterIndex: $0 * perLine, startsParagraph: $0 == 0)
            },
            contentHeight: Double(count) * pitch,
            wordCount: characters / 5,
            characterCount: characters
        )
    }

    @Test(arguments: [0.0, 50, 150, 320, 340, 500, 540])
    func roundTripsInTheSameLayout(position: Double) throws {
        let point = try #require(Self.layout.readingPoint(at: position))
        let back = try #require(Self.layout.position(ofReadingPoint: point))
        #expect(abs(back - position) < 1e-9)
    }

    @Test func interpolatesBetweenTheLineStarts() throws {
        // Line 1 holds characters 12…24 (the next line starts at 25): a quarter through it is character 12 + 13 / 4.
        #expect(try #require(Self.layout.readingPoint(at: 125)) == 12 + 13.0 / 4)
        // Line 2's span carries the paragraph gap (200…340): half way is half way through its characters 25…39.
        #expect(try #require(Self.layout.readingPoint(at: 270)) == 25 + 15.0 / 2)
        // The last line ends at the text's length.
        #expect(try #require(Self.layout.readingPoint(at: 490)) == 52 + 12.0 / 2)
    }

    @Test func mapsToTheLineHoldingTheCharacter() throws {
        // 20 characters a line becoming 12 a line: 30 % through line 4 is character 86, which is now 2 / 12 through
        // line 7 (84…95). The line-start anchor puts it 30 % through line 6 (72…83) instead.
        let narrow = Self.wrapped(240, perLine: 20)
        let wide = Self.wrapped(240, perLine: 12)
        let point = try #require(narrow.readingPoint(at: 430))
        #expect(abs(point - 86) < 1e-9)
        let mapped = try #require(wide.position(ofReadingPoint: point))
        #expect(wide.lineIndex(at: mapped) == 7)
        #expect(abs(mapped - (700 + 2.0 / 12 * 100)) < 1e-9)
        #expect(wide.lineIndex(at: wide.position(of: narrow.anchor(at: 430))) == 6)
    }

    /// The finding: a fold passes through several widths (the probe saw 466, 382, 466 and 951 pt in about 125 ms). The
    /// line-start anchor can only move back to the start of the line holding its character, so each width pulled the
    /// place back; after one unfold the reader's line was no longer at the reading line. The reading point doesn't drift.
    @Test func aChainOfWidthsKeepsTheSameCharacter() throws {
        let widths = [10, 8, 10, 21].map { Self.wrapped(1_000, perLine: $0) }
        // Half way through line 61 of the first layout: characters 610…619, so character 615.
        var position = 61 * 100 + 50.0
        var anchorPosition = position
        for (old, new) in zip(widths, widths.dropFirst()) {
            let point = try #require(old.readingPoint(at: position))
            #expect(abs(point - 615) < 1e-9)
            position = try #require(new.position(ofReadingPoint: point))
            anchorPosition = new.position(of: old.anchor(at: anchorPosition))
        }
        let last = try #require(widths.last)
        #expect(abs(try #require(last.readingPoint(at: position)) - 615) < 1e-9)
        #expect(last.lineIndex(at: position) == 29)               // 609…629 holds 615
        // The line-start anchor ended a line early, at character 598.5.
        #expect(last.lineIndex(at: anchorPosition) == 28)
        #expect(abs(try #require(last.readingPoint(at: anchorPosition)) - 598.5) < 1e-9)
    }

    @Test func andBackAgainLandsOnTheSamePosition() throws {
        let folded = Self.wrapped(2_000, perLine: 15, pitch: 137.5)
        let open = Self.wrapped(2_000, perLine: 21, pitch: 146)
        let start = 40 * 137.5 + 0.8 * 137.5
        let there = try #require(open.position(ofReadingPoint: try #require(folded.readingPoint(at: start))))
        let back = try #require(folded.position(ofReadingPoint: try #require(open.readingPoint(at: there))))
        #expect(abs(back - start) < 1e-9)
    }

    @Test func edges() throws {
        // No lines: nothing to read.
        #expect(PrompterLayout.empty.readingPoint(at: 0) == nil)
        #expect(PrompterLayout.empty.position(ofReadingPoint: 10) == nil)
        // Without the text length the last line has no end, so the caller falls back to the line-start anchor.
        let unknownLength = PrompterLayoutTests.layout
        #expect(unknownLength.readingPoint(at: 500) == nil)
        #expect(unknownLength.position(ofReadingPoint: 55) == nil)
        #expect(unknownLength.readingPoint(at: 150) != nil)
        // Outside the text: clamped to the first and the last position.
        #expect(try #require(Self.layout.readingPoint(at: -100)) == 0)
        #expect(try #require(Self.layout.position(ofReadingPoint: -5)) == 0)
        #expect(try #require(Self.layout.position(ofReadingPoint: 9_999)) == 540)
        #expect(try #require(Self.layout.readingPoint(at: 9_999)) == 64)
        #expect(Self.layout.position(ofReadingPoint: .nan) == nil)
        // Two lines starting on the same character (nothing between them): no division by zero.
        let doubled = PrompterLayout(
            lines: [
                .init(y: 0, height: 100, characterIndex: 0, startsParagraph: true),
                .init(y: 100, height: 100, characterIndex: 10, startsParagraph: false),
                .init(y: 200, height: 100, characterIndex: 10, startsParagraph: false),
            ],
            contentHeight: 300, wordCount: 3, characterCount: 20
        )
        let point = try #require(doubled.readingPoint(at: 150))
        #expect(point == 10)
        let mapped = try #require(doubled.position(ofReadingPoint: point))
        #expect(mapped.isFinite && mapped == 200)
    }
}
