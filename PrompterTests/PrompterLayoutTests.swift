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
