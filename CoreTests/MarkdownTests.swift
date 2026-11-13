import Foundation
import Testing
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
#if os(macOS)
@testable import PrompterMac
#else
@testable import Prompter
#endif

// MARK: - Helpers

/// `text` with each styled run wrapped as {B:…} {I:…} {S:…} {C:…} (letters in that order), for compact expectations.
private func tagged(_ parsed: MarkdownInline.Parsed) -> String {
    tagged(text: parsed.text, runs: parsed.runs)
}

private func tagged(text: String, runs: [MarkdownInline.Run]) -> String {
    let units = Array(text.utf16)
    func slice(_ range: Range<Int>) -> String { String(utf16CodeUnits: Array(units[range]), count: range.count) }
    var out = ""
    var position = 0
    for run in runs {
        if run.range.lowerBound > position { out += slice(position..<run.range.lowerBound) }
        out += "{\(letters(run.style)):\(slice(run.range))}"
        position = run.range.upperBound
    }
    if position < units.count { out += slice(position..<units.count) }
    return out
}

private func letters(_ style: MarkdownStyle) -> String {
    var tag = ""
    if style.contains(.bold) { tag += "B" }
    if style.contains(.italic) { tag += "I" }
    if style.contains(.strikethrough) { tag += "S" }
    if style.contains(.code) { tag += "C" }
    return tag
}

private func inline(_ source: String) -> String {
    tagged(MarkdownInline.parse(source))
}

// MARK: - Inline

struct MarkdownInlineTests {
    @Test(arguments: [
        ("**bold**", "{B:bold}"),
        ("__bold__", "{B:bold}"),
        ("*italic*", "{I:italic}"),
        ("_italic_", "{I:italic}"),
        ("~~strike~~", "{S:strike}"),
        ("`code`", "{C:code}"),
        ("[the site](https://example.com)", "the site"),
        ("![a photo](photo.jpg)", "a photo"),
        ("***both***", "{BI:both}"),
        ("Say **this** and *that*.", "Say {B:this} and {I:that}."),
        ("**`code` inside**", "{BC:code}{B: inside}"),
        ("[**bold link**](u)", "{B:bold link}"),
    ])
    func eachMarker(source: String, expected: String) {
        #expect(inline(source) == expected)
    }

    /// A marker without its partner is shown as typed; nothing is swallowed.
    @Test(arguments: [
        ("**bold", "**bold"),
        ("*a", "*a"),
        ("__a", "__a"),
        ("~~a", "~~a"),
        ("`code", "`code"),
        ("[text](", "[text]("),
        ("[text]", "[text]"),
        ("a ** b ** c", "a ** b ** c"),
        ("5 * 3 = 15", "5 * 3 = 15"),
        ("**a** **", "{B:a} **"),
        ("**foo*", "*{I:foo}"),
        ("*foo**", "{I:foo}*"),
        ("~one~", "~one~"),
        ("~~~a~~~", "~~~a~~~"),
        ("snake_case_word", "snake_case_word"),
        ("file_name.txt and _real_", "file_name.txt and {I:real}"),
        ("[pause] for effect", "[pause] for effect"),
        ("[a](b c)", "[a](b c)"),
    ])
    func unbalancedMarkersStayLiteral(source: String, expected: String) {
        #expect(inline(source) == expected)
    }

    @Test(arguments: [
        ("\\*not italic\\*", "*not italic*"),
        ("\\_\\_x\\_\\_", "__x__"),
        ("\\[x](y)", "[x](y)"),
        ("a \\\\ b", "a \\ b"),
        ("C:\\path", "C:\\path"),          // a backslash before a letter is a backslash
        ("`a \\* b`", "{C:a \\* b}"),       // no escapes inside code
    ])
    func escapes(source: String, expected: String) {
        #expect(inline(source) == expected)
    }

    @Test func plainLineIsReturnedAsIs() {
        let parsed = MarkdownInline.parse("Hey, welcome back. It's 9:41 & 50% done.")
        #expect(parsed == .plain("Hey, welcome back. It's 9:41 & 50% done."))
    }

    @Test func markersAndSourceRunsPointIntoTheSource() {
        let source = "a **b** [c](d)"
        let parsed = MarkdownInline.parse(source)
        #expect(parsed.text == "a b c")
        #expect(parsed.markers == [2..<4, 5..<7, 8..<9, 10..<14])
        #expect(parsed.sourceRuns == [MarkdownInline.Run(range: 4..<5, style: .bold)])
        #expect(parsed.runs == [MarkdownInline.Run(range: 2..<3, style: .bold)])
    }

    @Test func offsetsAreUTF16() {
        let parsed = MarkdownInline.parse("🎉 **café** 🎉")
        #expect(parsed.text == "🎉 café 🎉")
        #expect(parsed.runs == [MarkdownInline.Run(range: 3..<7, style: .bold)])
        #expect(parsed.markers == [3..<5, 9..<11])
    }

    /// Our parser agrees with Foundation's CommonMark parser on the shown text and the styles (where the two are meant to
    /// agree: Foundation also turns single tildes, entities and autolinks into formatting, which we leave alone).
    @Test(arguments: [
        "**bold", "*a **b*", "snake_case_word", "~~two~~", "`code` **b**", "[t](u) ![alt](i.png)", "\\*lit\\*",
        "foo*bar*baz", "__a__ _b_", "***x***", "5 * 3 = 15", "**a** **", "*foo**bar**baz*", "_foo_bar_", "**foo*",
        "*foo**", "a ** b ** c", "[pause] for effect", "[link](http://a.com/(b))", "**`code`**", "~~a ~~b~~",
        "**bold** and *it* `c` [l](u)", "*foo*bar", "**foo bar **", "*(**foo**)*", "foo***bar***baz",
        "*foo _bar* baz_", "**foo*bar**", "`` a ` b ``", "` a `", "[a](b c)", "[a](b \"t\")", "Don't *you* dare",
        "It's 3*4*5", "café *déjà* vu", "emoji 🎉 **party** 🎉", "_ foo _", "*foo*bar*", "**foo**bar", "__foo__bar",
        "a*\"foo\"*", "x _(y)_ z", "\\\\*a*", "[a]", "[a] (b)", "Read from the **glass**, not from paper.",
    ])
    func matchesFoundation(source: String) throws {
        let foundation = try AttributedString(
            markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        var expected = ""
        for run in foundation.runs {
            let text = String(foundation[run.range].characters)
            var style: MarkdownStyle = []
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { style.insert(.bold) }
                if intent.contains(.emphasized) { style.insert(.italic) }
                if intent.contains(.strikethrough) { style.insert(.strikethrough) }
                if intent.contains(.code) { style.insert(.code) }
            }
            expected += style.isEmpty ? text : "{\(letters(style)):\(text)}"
        }
        // Foundation splits a run where only the link changes; ours merges same-style neighbours.
        expected = expected.replacingOccurrences(of: "}{B:", with: "").replacingOccurrences(of: "}{I:", with: "")
        let ours = inline(source).replacingOccurrences(of: "}{B:", with: "").replacingOccurrences(of: "}{I:", with: "")
        #expect(ours == expected, "\(source)")
    }
}

// MARK: - Blocks

struct ScriptMarkdownTests {
    @Test(arguments: [
        ("# Cold open", ScriptMarkdown.Block.heading(level: 1), "Cold open"),
        ("## Three things", .heading(level: 2), "Three things"),
        ("### Wrap up ###", .heading(level: 3), "Wrap up"),
        ("###### Six", .heading(level: 6), "Six"),
        ("  # Indented", .heading(level: 1), "Indented"),
        ("# **Bold** title", .heading(level: 1), "Bold title"),
        ("# C#", .heading(level: 1), "C#"),
        ("#hashtag", .text, "#hashtag"),
        ("#1 tip", .text, "#1 tip"),
        ("####### seven", .text, "####### seven"),
        ("---", .rule, ""),
        ("***", .rule, ""),
        ("_ _ _", .rule, ""),
        ("--", .text, "--"),
        ("- item", .text, "• item"),
        ("* item", .text, "• item"),
        ("+ item", .text, "• item"),
        ("    - nested", .text, "    • nested"),
        ("-not a bullet", .text, "-not a bullet"),
        ("1. First", .text, "1. First"),
        ("2) Second", .text, "2) Second"),
        ("> Quoted", .text, "Quoted"),
        (">> Deeper", .text, "Deeper"),
        ("> - quoted bullet", .text, "• quoted bullet"),
        ("> ## quoted heading", .heading(level: 2), "quoted heading"),
        ("Plain line   ", .text, "Plain line"),
        ("  indented", .text, "  indented"),
    ])
    func blocks(source: String, block: ScriptMarkdown.Block, text: String) {
        let line = ScriptMarkdown.parse(source)
        #expect(line.block == block)
        #expect(line.text == text)
        #expect(ScriptMarkdown.block(of: source) == block)
    }

    @Test func bulletRunsAreShiftedPastThePrefix() {
        let line = ScriptMarkdown.parse("- Read from the **glass**")
        #expect(tagged(text: line.text, runs: line.runs) == "• Read from the {B:glass}")
        #expect(line.markers == [0..<2, 16..<18, 23..<25])
        #expect(line.sourceRuns == [MarkdownInline.Run(range: 18..<23, style: .bold)])
    }

    @Test func headingMarkersIncludeTheHashesAndTheClosingRun() {
        let line = ScriptMarkdown.parse("## Title ##")
        #expect(line.markers == [0..<3, 9..<11])
    }

    @Test func trailingSpacesAreTrimmedAndRunsClipped() {
        let line = ScriptMarkdown.parse("Say **this**   ")
        #expect(line.text == "Say this")
        #expect(line.runs == [MarkdownInline.Run(range: 4..<8, style: .bold)])
    }
}

// MARK: - Markup interplay and the document

struct MarkdownDocumentTests {
    @Test func notesAndCuesWinOverMarkdown() {
        let body = "// # not a heading, a **note**\n[pause 3]\n# Heading\n---\nText"
        let kinds = ScriptMarkup.lines(of: body, markdown: true).map(\.kind)
        #expect(kinds == [.note, .pause(seconds: 3), .heading(level: 1), .rule, .text])
        // Off: headings and rules are text, as before.
        #expect(ScriptMarkup.lines(of: body).map(\.kind) == [.note, .pause(seconds: 3), .text, .text, .text])
    }

    @Test func documentWithMarkdown() {
        let body = "# Intro\nSay **this**.\n// a *quiet* note\n[pause 2]\n---\n- one\n\n1. two"
        let document = PrompterDocument(body: body, markdown: true)
        #expect(document.paragraphs.map(\.kind) == [.heading(level: 1), .text, .note, .pause(seconds: 2), .rule, .text, .text])
        #expect(document.text == "Intro\nSay this.\na quiet note\nPAUSE 2s\n\(ScriptMarkdown.ruleText)\n• one\n1. two")
        #expect(tagged(text: document.paragraphs[1].text, runs: document.paragraphs[1].runs) == "Say {B:this}.")
        #expect(tagged(text: document.paragraphs[2].text, runs: document.paragraphs[2].runs) == "a {I:quiet} note")
        // Headings, notes, cues and rules hold no spoken words: "Say this." + "one" + "1. two".
        #expect(document.timedWordCount == 5)
        #expect(document.holds.count == 1)
        #expect(document.timedRanges.count == 3)
    }

    @Test func markdownOffShowsEverythingAsWritten() {
        let body = "# Intro\nSay **this**.\n- one"
        let document = PrompterDocument(body: body, markdown: false)
        #expect(document.text == body)
        #expect(document.paragraphs.allSatisfy { $0.kind == .text && $0.runs.isEmpty })
        #expect(PrompterDocument(body: body) == document)
    }

    @Test func emptyHeadingsAndMarkerOnlyLinesAreDropped() {
        let document = PrompterDocument(body: "#\nWords\n[](nowhere)\n//", markdown: true)
        #expect(document.text == "Words")
    }

    @Test func scriptsWithoutMarkdownAreUnchangedByTheSetting() {
        for script in DemoData.scripts(now: .now) {
            #expect(PrompterDocument(body: script.body, markdown: true) == PrompterDocument(body: script.body))
            #expect(ReadingStats(text: script.body, markdown: true) == ReadingStats(text: script.body))
        }
    }
}

// MARK: - Word counts

struct MarkdownReadingStatsTests {
    @Test func countsTheShownSpokenWords() {
        let body = "# Intro to the rig\nSay **this** and [click here](https://example.com/a b) ~~now~~.\n---\n- one"
        // Off: "#", "---" and "-" aren't words, but the heading's words are: 4 + 7 + 1.
        #expect(ReadingStats(text: body).wordCount == 4 + 7 + 1)
        // On: the heading isn't read, the rest has the same 7 + 1 tokens ("[click here](https://example.com/a b)" isn't
        // a link, because of the space in the address, so it stays as written).
        #expect(ReadingStats(text: body, markdown: true).wordCount == 7 + 1)
        let linked = "Say [click here](https://example.com) now."
        #expect(ReadingStats(text: linked).wordCount == 4)
        #expect(ReadingStats(text: linked, markdown: true).wordCount == 4)
    }

    @Test func matchesTheDocumentsTimedWords() {
        let bodies = [DemoData.markdownBody, SampleScript.body, "## a **b** c\n**\n* x *y*\n> **q**"]
            + DemoData.scripts(now: .now).map(\.body)
        for body in bodies {
            #expect(ReadingStats(text: body, markdown: true).wordCount
                == PrompterDocument(body: body, markdown: true).timedWordCount)
        }
    }

    @Test func markdownDemoNumbers() {
        let stats = ReadingStats(text: DemoData.markdownBody, markdown: true)
        #expect(stats.holdSeconds == 2)
        #expect(stats.wordCount == 59)
    }
}

// MARK: - Attributed string

@MainActor
struct MarkdownAttributedStringTests {
    private func components(_ color: Any?) -> [Double] {
        guard let color = color as? PlatformColor,
              let srgb = color.cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent,
                                                 options: nil),
              let parts = srgb.components
        else { return [] }
        return parts.map { (Double($0) * 1000).rounded() / 1000 }
    }

    private func isItalic(_ font: Any?) -> Bool {
        #if canImport(UIKit)
        (font as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitItalic) ?? false
        #else
        (font as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic) ?? false
        #endif
    }

    private func attributed(_ body: String, scheme: PrompterSettings.Scheme) -> (NSAttributedString, PrompterTextStyle) {
        var settings = PrompterSettings()
        settings.scheme = scheme
        let style = PrompterTextStyle(settings: settings, canvasSize: CGSize(width: 874, height: 402), isPad: false)
        return (PrompterText.attributedString(PrompterDocument(body: body, markdown: true), style: style), style)
    }

    @Test(arguments: PrompterSettings.Scheme.allCases)
    func boldIsTheSchemesCueColor(scheme: PrompterSettings.Scheme) {
        let (string, _) = attributed("Say **this** now", scheme: scheme)
        let text = string.string as NSString
        let bold = text.range(of: "this")
        let plain = text.range(of: "Say")
        #expect(components(string.attribute(.foregroundColor, at: bold.location, effectiveRange: nil))
            == components(scheme.cueColor))
        #expect(components(string.attribute(.foregroundColor, at: plain.location, effectiveRange: nil))
            == components(scheme.foregroundColor))
        // Same font as the rest of the line (already heavy), so bold doesn't change the layout.
        let boldFont = string.attribute(.font, at: bold.location, effectiveRange: nil) as? PlatformFont
        let plainFont = string.attribute(.font, at: plain.location, effectiveRange: nil) as? PlatformFont
        #expect(boldFont == plainFont)
    }

    @Test(arguments: PrompterSettings.Scheme.allCases)
    func headingsAreLargerAndAmber(scheme: PrompterSettings.Scheme) throws {
        let (string, style) = attributed("# Title\n## Sub\n### Third\nText", scheme: scheme)
        let text = string.string as NSString
        func size(of word: String) -> Double {
            (string.attribute(.font, at: text.range(of: word).location, effectiveRange: nil) as? PlatformFont)
                .map { Double($0.pointSize) } ?? 0
        }
        #expect(size(of: "Title") == style.fontSize * 1.2)
        #expect(size(of: "Sub") == style.fontSize * 1.1)
        #expect(size(of: "Third") == style.fontSize)
        #expect(size(of: "Text") == style.fontSize)
        #expect(components(string.attribute(.foregroundColor, at: 0, effectiveRange: nil)) == components(scheme.cueColor))
    }

    @Test func italicStrikeAndCode() {
        let (string, style) = attributed("An *italic* and ~~gone~~ and `code`", scheme: .whiteOnBlack)
        let text = string.string as NSString
        #expect(text as String == "An italic and gone and code")
        let italic = text.range(of: "italic").location
        let gone = text.range(of: "gone").location
        let code = text.range(of: "code").location
        #expect(isItalic(string.attribute(.font, at: italic, effectiveRange: nil)))
        #expect(!isItalic(string.attribute(.font, at: 0, effectiveRange: nil)))
        #expect(string.attribute(.strikethroughStyle, at: gone, effectiveRange: nil) as? Int
            == NSUnderlineStyle.single.rawValue)
        #expect(components(string.attribute(.foregroundColor, at: gone, effectiveRange: nil)).last
            == PrompterText.strikethroughOpacity)
        // Code is plain text.
        #expect(components(string.attribute(.foregroundColor, at: code, effectiveRange: nil))
            == components(style.scheme.foregroundColor))
        #expect(string.attribute(.font, at: code, effectiveRange: nil) as? PlatformFont
            == string.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont)
    }

    @Test func boldInANoteStaysDim() {
        let (string, _) = attributed("// a **loud** note", scheme: .whiteOnBlack)
        let text = string.string as NSString
        let alpha = components(string.attribute(.foregroundColor, at: text.range(of: "loud").location,
                                                effectiveRange: nil)).last
        #expect(alpha == PrompterText.noteOpacity)
    }

    @Test func ruleIsACentredDimLine() throws {
        let (string, _) = attributed("Before\n---\nAfter", scheme: .whiteOnBlack)
        let text = string.string as NSString
        let rule = text.range(of: ScriptMarkdown.ruleText)
        #expect(rule.location != NSNotFound)
        let paragraph = try #require(string.attribute(.paragraphStyle, at: rule.location, effectiveRange: nil)
            as? NSParagraphStyle)
        #expect(paragraph.alignment == .center)
        #expect(components(string.attribute(.foregroundColor, at: rule.location, effectiveRange: nil)).last
            == PrompterText.noteOpacity)
    }

    /// The view-less layout of a Markdown script: the spoken words are the document's, the hold is found, and the
    /// heading and rule lines aren't timed.
    @Test func layoutOfAMarkdownScript() throws {
        let document = PrompterDocument(body: DemoData.markdownBody, markdown: true)
        let style = PrompterTextStyle(settings: PrompterSettings(), canvasSize: CGSize(width: 874, height: 402), isPad: false)
        let layout = PrompterLayoutExtractor.layout(of: document, style: style)
        #expect(layout.wordCount == document.timedWordCount)
        #expect(layout.holds.count == 1)
        #expect(layout.timedHeight < layout.contentHeight)
        let headingIndex = (document.text as NSString).range(of: "Cold open").location
        #expect(layout.lines.first?.characterIndex == headingIndex)
        #expect(layout.lines.count >= document.paragraphs.count)
    }
}

// MARK: - Settings and import

struct MarkdownSettingsAndImportTests {
    @Test func markdownIsOnByDefaultAndDecodesTolerantly() throws {
        #expect(PrompterSettings().markdown)
        let decoder = JSONDecoder()
        #expect(try decoder.decode(PrompterSettings.self, from: Data("{}".utf8)).markdown)
        #expect(try !decoder.decode(PrompterSettings.self, from: Data(#"{"markdown": false}"#.utf8)).markdown)
        #expect(try decoder.decode(PrompterSettings.self, from: Data(#"{"markdown": "maybe"}"#.utf8)).markdown)
        var settings = PrompterSettings()
        settings.markdown = false
        let data = try JSONEncoder().encode(settings)
        #expect(try !decoder.decode(PrompterSettings.self, from: data).markdown)
    }

    @Test(arguments: ["md", "markdown", "mdown", "MD"])
    func importsMarkdownFilesAsWritten(fileExtension: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MarkdownImport-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Launch video.\(fileExtension)")
        let body = "# Launch\n\nThis is **big** news.\n- one\n- two"
        try Data(body.utf8).write(to: url)
        let imported = try ScriptImporter.importFile(at: url)
        #expect(imported.title == "Launch video")
        #expect(imported.body == body)
    }

    @Test func pickersOfferMarkdown() {
        #expect(ScriptImporter.importableTypes.contains { $0.identifier == "net.daringfireball.markdown" })
    }
}
