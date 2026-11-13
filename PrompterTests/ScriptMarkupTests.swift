import Testing
import UIKit
@testable import Prompter

struct ScriptMarkupTests {
    // MARK: Line kinds

    @Test(arguments: [
        "// a note",
        "//note without a space",
        "   //  indented note   ",
        "\t// tabbed",
        "/// three slashes",
        "//",
        "// https://example.com in a note is still a note",
    ])
    func notes(line: String) {
        #expect(ScriptMarkup.kind(of: line) == .note)
    }

    @Test(arguments: [
        ("[pause]", nil),
        ("[PAUSE]", nil),
        ("  [Pause]  ", nil),
        ("[ pause ]", nil),
        ("[pause 3]", 3),
        ("[Pause 1]", 1),
        ("[pause 60]", 60),
        ("\t[pause 2]\t", 2),
        ("[pause  10 ]", 10),
        ("[pause 3s]", 3),
        ("[pause 3 s]", 3),
        ("[PAUSE 05]", 5),
    ] as [(String, Int?)])
    func pauseCues(line: String, seconds: Int?) {
        #expect(ScriptMarkup.kind(of: line) == .pause(seconds: seconds))
    }

    @Test(arguments: [
        "",
        "   ",
        "Hello there.",
        "[pause 0]",                            // out of range: shown as written, so the mistake is visible
        "[pause 61]",
        "[pause 100]",
        "[pause -1]",
        "[pause 2.5]",
        "[pause two]",
        "[pause3]",
        "[pauses]",
        "[pause] [pause]",
        "[pause 3] now",
        "pause",
        "[break]",
        "/ one slash",
        "[pause 3",
        "pause 3]",
    ])
    func text(line: String) {
        #expect(ScriptMarkup.kind(of: line) == .text)
    }

    /// Review focus 1: markup that looks like markup but isn't. Only whole lines are notes or cues; a `//` or a
    /// `[pause]` inside a line is part of the script and is read (and counted) like any other words.
    @Test func onlyWholeLinesAreMarkup() {
        let lookalikes = [
            "Find the link at https://example.com/rig and print the cradle.",
            "Bring the tripod and/or // the clamp, whichever is closer.",
            "Then [pause] for effect, and carry on.",
            "Say it slowly [pause 2] and smile.",
            "A URL like //cdn.example.com only counts when it starts the line.",
        ]
        for line in lookalikes {
            #expect(ScriptMarkup.kind(of: line) == .text, "\(line)")
        }
        let body = lookalikes.joined(separator: "\n")
        let document = PrompterDocument(body: body)
        #expect(document.paragraphs.map(\.kind) == Array(repeating: .text, count: lookalikes.count))
        #expect(document.paragraphs.map(\.text) == lookalikes)      // shown exactly as written
        #expect(document.holds.isEmpty)
        #expect(ReadingStats(text: body).wordCount == ReadingStats.wordCount(of: body))
        #expect(ReadingStats(text: body).holdSeconds == 0)
    }

    // MARK: Lines

    @Test func linesKeepBlankLinesAndTheirRanges() {
        let body = "One\n\n// note\r\n[pause 2]\nTwo"
        let lines = ScriptMarkup.lines(of: body)
        #expect(lines.map { String(body[$0.range]) } == ["One", "", "// note", "[pause 2]", "Two"])
        #expect(lines.map(\.kind) == [.text, .text, .note, .pause(seconds: 2), .text])
    }

    @Test func emptyBodyIsOneBlankTextLine() {
        let lines = ScriptMarkup.lines(of: "")
        #expect(lines.count == 1)
        #expect(lines.first?.kind == .text)
        #expect(ScriptMarkup.lines(of: "A\n").map(\.kind) == [.text, .text])
    }

    @Test func noteTextDropsTheSlashesAndSpaces() {
        #expect(ScriptMarkup.noteText("// Smile here.") == "Smile here.")
        #expect(ScriptMarkup.noteText("   ///   Three   ") == "Three")
        #expect(ScriptMarkup.noteText("//no space") == "no space")
        #expect(ScriptMarkup.noteText("//").isEmpty)
        #expect(ScriptMarkup.noteText("// a // b") == "a // b")
    }

    @Test func cueLabels() {
        #expect(ScriptMarkup.cueLabel(seconds: nil) == "PAUSE")
        #expect(ScriptMarkup.cueLabel(seconds: 3) == "PAUSE 3s")
    }

    // MARK: Reading stats

    @Test func readingStatsCountTextLinesOnly() {
        let body = """
            Hello there, friends.
            // Look at camera two here, then smile.
            [pause 3]
            [pause]

            Welcome back.
            """
        let stats = ReadingStats(text: body)
        #expect(stats.wordCount == 5)
        #expect(stats.holdSeconds == 3)
        #expect(ReadingStats.wordCount(of: body) > stats.wordCount)     // the raw counter still sees every token
        // 5 words at 60 wpm = 5 s, plus the 3 s hold.
        #expect(stats.readingSeconds(atWPM: 60) == 8)
        #expect(stats.readingSeconds(atWPM: 0) == 0)
    }

    @Test func aScriptOfOnlyNotesHasNoWords() {
        let stats = ReadingStats(text: "// one\n// two\n[pause 2]")
        #expect(stats.wordCount == 0)
        #expect(stats.holdSeconds == 2)
    }
}

struct PrompterDocumentTests {
    @Test func paragraphsKindsAndShownText() {
        let body = "Intro line.  \n\n  // Breathe.  \n[pause 3]\n[PAUSE]\n//\nOutro."
        let document = PrompterDocument(body: body)
        #expect(document.paragraphs == [
            .init(text: "Intro line.", kind: .text),
            .init(text: "Breathe.", kind: .note),
            .init(text: "PAUSE 3s", kind: .pause(seconds: 3)),
            .init(text: "PAUSE", kind: .pause(seconds: nil)),
            .init(text: "Outro.", kind: .text),             // the empty note shows nothing and is dropped
        ])
        #expect(document.text == "Intro line.\nBreathe.\nPAUSE 3s\nPAUSE\nOutro.")
        #expect(document.timedWordCount == 3)
        #expect(document.timedWordCount == ReadingStats(text: body).wordCount)
    }

    @Test func holdsPointAtTheirParagraphInUTF16() {
        // "🎬" is 2 UTF-16 units; "é" is 1.
        let document = PrompterDocument(body: "🎬 Café\n[pause 2]\nNext\n[pause]\n[pause 5]")
        let text = document.text as NSString
        #expect(document.holds == [
            .init(characterIndex: text.range(of: "PAUSE 2s").location, seconds: 2),
            .init(characterIndex: text.range(of: "PAUSE 5s").location, seconds: 5),
        ])
        #expect(document.holds.first?.characterIndex == 8)          // "🎬 Café\n" = 2 + 1 + 4 + 1
    }

    @Test func plainScriptsAreUnchanged() {
        let body = "First paragraph.  \n\n\nSecond line\nThird\t\n   \n"
        let document = PrompterDocument(body: body)
        #expect(document.text == "First paragraph.\nSecond line\nThird")
        #expect(document.paragraphs.allSatisfy { $0.kind == .text })
        #expect(document.holds.isEmpty)
        #expect(document.timedWordCount == ReadingStats.wordCount(of: body))
        #expect(PrompterDocument(body: " \n\n").isEmpty)
        #expect(PrompterDocument(body: "// only an empty note: no\n//").paragraphs.count == 1)
    }
}

/// How notes and cues are drawn.
@MainActor
struct PrompterMarkupRenderingTests {
    private let size = CGSize(width: 874, height: 402)

    private func style(_ configure: (inout PrompterSettings) -> Void = { _ in }) -> PrompterTextStyle {
        var settings = PrompterSettings()
        configure(&settings)
        return PrompterTextStyle(settings: settings, canvasSize: size, isPad: false)
    }

    private func attributes(
        of paragraph: String, in document: PrompterDocument, style: PrompterTextStyle
    ) -> [NSAttributedString.Key: Any] {
        let string = PrompterText.attributedString(document, style: style)
        let location = (document.text as NSString).range(of: paragraph).location
        return string.attributes(at: location, effectiveRange: nil)
    }

    @Test func notesAreSmallItalicAndDimmed() throws {
        let style = style()
        let document = PrompterDocument(body: "Read this.\n// Not this.")
        let text = attributes(of: "Read this.", in: document, style: style)
        let note = attributes(of: "Not this.", in: document, style: style)

        let textFont = try #require(text[.font] as? UIFont)
        let noteFont = try #require(note[.font] as? UIFont)
        #expect(textFont.pointSize == 72)
        #expect(abs(noteFont.pointSize - 72 * 0.55) < 0.001)
        #expect(noteFont.fontDescriptor.symbolicTraits.contains(.traitItalic))
        #expect(!textFont.fontDescriptor.symbolicTraits.contains(.traitItalic))

        let noteColour = try #require(note[.foregroundColor] as? UIColor)
        var white: CGFloat = 0
        var alpha: CGFloat = 0
        noteColour.getWhite(&white, alpha: &alpha)
        #expect(abs(alpha - 0.45) < 0.001)
        #expect(white == 1)
        #expect((text[.foregroundColor] as? UIColor) == .white)
    }

    @Test func italicKeepsTheWeight() {
        let heavy = PrompterText.italicSystemFont(ofSize: 40, weight: .heavy)
        let regular = PrompterText.italicSystemFont(ofSize: 40, weight: .regular)
        #expect(heavy.fontDescriptor.symbolicTraits.contains(.traitItalic))
        #expect(heavy.fontName != regular.fontName)
        let traits = heavy.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        let weight = traits?[.weight] as? Double ?? 0
        #expect(weight > UIFont.Weight.semibold.rawValue)
    }

    @Test func cuesAreACentredAmberLabel() throws {
        let style = style()
        let document = PrompterDocument(body: "Before.\n[pause 3]\nAfter.")
        let cue = attributes(of: "PAUSE 3s", in: document, style: style)
        let font = try #require(cue[.font] as? UIFont)
        #expect(abs(font.pointSize - 36) < 0.001)
        let paragraph = try #require(cue[.paragraphStyle] as? NSParagraphStyle)
        #expect(paragraph.alignment == .center)
        #expect((cue[.foregroundColor] as? UIColor) == PrompterSettings.Scheme.whiteOnBlack.cueUIColor)
        #expect((cue[.kern] as? Double ?? 0) > 0)
        // The text around it is unchanged.
        let after = attributes(of: "After.", in: document, style: style)
        #expect((after[.paragraphStyle] as? NSParagraphStyle)?.alignment == .natural)
        #expect((after[.font] as? UIFont)?.pointSize == 72)
    }

    @Test func cueColourStandsOutInEveryScheme() {
        for scheme in PrompterSettings.Scheme.allCases {
            #expect(scheme.cueUIColor != scheme.foregroundUIColor)
            #expect(scheme.cueUIColor != scheme.backgroundUIColor)
        }
    }

    @Test func everyParagraphKeepsTheTextParagraphSpacing() throws {
        let style = style()
        let document = PrompterDocument(body: "One.\n// Two.\n[pause 2]\nThree.")
        let string = PrompterText.attributedString(document, style: style)
        #expect(string.string == document.text)
        for paragraph in ["One.", "Two.", "PAUSE 2s", "Three."] {
            let found = attributes(of: paragraph, in: document, style: style)
            let paragraphStyle = try #require(found[.paragraphStyle] as? NSParagraphStyle)
            #expect(abs(paragraphStyle.paragraphSpacing - style.paragraphSpacing) < 0.01, "\(paragraph)")
        }
        // The line break after a note carries the note's style (TextKit styles a paragraph by its own characters).
        let breakAfterNote = (document.text as NSString).range(of: "Two.").upperBound
        let breakFont = try #require(string.attribute(.font, at: breakAfterNote, effectiveRange: nil) as? UIFont)
        #expect(breakFont.fontDescriptor.symbolicTraits.contains(.traitItalic))
    }

    /// The layout the engine gets: notes and cues are lines (steps can land on them), but only text words set the pace,
    /// and each timed cue becomes a hold at the top of its line.
    @Test func layoutHasTheCueLinesAndHolds() throws {
        let body = "Hey, welcome back. Today I'm showing you the rig.\n// Smile.\n[pause 3]\n[pause]\nIt's simpler than it looks."
        let document = PrompterDocument(body: body)
        let style = style()
        let textView = UITextView(usingTextLayoutManager: true)
        textView.frame = CGRect(origin: .zero, size: size)
        textView.textContainer.lineFragmentPadding = 0
        textView.attributedText = PrompterText.attributedString(document, style: style)
        textView.textContainerInset = style.textContainerInset
        textView.layoutIfNeeded()
        let manager = try #require(textView.textLayoutManager)
        let layout = PrompterLayoutExtractor.layout(
            of: manager, wordCount: document.timedWordCount, holds: document.holds
        )

        #expect(layout.wordCount == ReadingStats(text: body).wordCount)
        #expect(layout.wordCount == 14)
        let text = document.text as NSString
        let cueIndex = text.range(of: "PAUSE 3s").location
        let cueLine = try #require(layout.lines.first { $0.characterIndex == cueIndex })
        #expect(cueLine.startsParagraph)
        #expect(layout.holds == [PrompterLayout.Hold(y: cueLine.y, seconds: 3, characterIndex: cueIndex)])
        #expect(layout.totalHoldSeconds == 3)
        // The note and both cues are lines of their own, smaller than a text line.
        let noteIndex = text.range(of: "Smile.").location
        let noteLine = try #require(layout.lines.first { $0.characterIndex == noteIndex })
        let firstLine = try #require(layout.lines.first)
        #expect(noteLine.height < firstLine.height)
        #expect(cueLine.height < firstLine.height)
        #expect(layout.lines.contains { $0.characterIndex == text.range(of: "PAUSE\n").location })

        // The text paragraphs' share of the height sets the WPM pace (the note and cue lines carry no words). The
        // document form of the extractor reads the same words and holds.
        let timed = PrompterLayoutExtractor.layout(of: manager, document: document)
        #expect(timed.wordCount == layout.wordCount)
        #expect(timed.holds == layout.holds)
        #expect(layout.timedHeight == layout.contentHeight)            // no paragraph kinds given: all text
        let notesAndCues = noteLine.height + cueLine.height
        #expect(timed.timedHeight < timed.contentHeight - notesAndCues)
        #expect(timed.timedHeight > timed.contentHeight / 2)
        let lastTextIndex = text.range(of: "It's simpler").location
        let lastTextLine = try #require(timed.lines.first { $0.characterIndex == lastTextIndex })
        let firstNoteOrCue = try #require(timed.lines.first { $0.characterIndex == noteIndex })
        // The first paragraph's lines (up to the note) and the last paragraph's (to the end) are exactly the timed part.
        #expect(abs(timed.timedHeight - (firstNoteOrCue.y + (timed.contentHeight - lastTextLine.y))) < 0.001)
    }

    @Test func timedRangesAreTheTextParagraphs() {
        let document = PrompterDocument(body: "One two.\n// note\n[pause 2]\nThree.")
        let text = document.text as NSString
        #expect(document.timedRanges == [
            0..<text.range(of: "One two.").length,
            text.range(of: "Three.").location..<text.length,
        ])
        #expect(PrompterDocument(body: "// only a note\n[pause]").timedRanges.isEmpty)
    }
}
