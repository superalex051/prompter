import Foundation

/// A script as the prompter shows it: one paragraph per non-blank line, each with its markup kind, plus what the engine
/// needs for timing (the words on text lines and where the timed `[pause N]` cues are). Pure, built once when the prompter
/// opens.
struct PrompterDocument: Equatable, Sendable {
    struct Paragraph: Equatable, Sendable {
        /// What is drawn: a text line as written (trailing spaces trimmed, indentation kept), a note without its `//`,
        /// a cue as "PAUSE" / "PAUSE 3s". With Markdown on, without its markers (a heading without its `#`s, a bullet
        /// as "• ", a rule as `ScriptMarkdown.ruleText`).
        var text: String
        var kind: ScriptLineKind
        /// Markdown's inline styles in `text` (UTF-16 offsets); empty with Markdown off.
        var runs: [MarkdownInline.Run] = []
    }

    /// A timed cue in `text`: the UTF-16 offset its paragraph starts at, and how long to hold there.
    struct HoldMark: Equatable, Sendable {
        var characterIndex: Int
        var seconds: Double
    }

    let paragraphs: [Paragraph]
    /// The paragraphs joined by "\n" (what TextKit lays out).
    let text: String
    /// Words on text paragraphs only; the WPM speed is based on these.
    let timedWordCount: Int
    /// Document order.
    let holds: [HoldMark]

    static let empty = PrompterDocument(body: "")

    /// Blank lines are dropped because paragraph spacing already separates paragraphs; a blank line at 72 pt with 1.6×
    /// spacing would leave a gap of half the screen. An empty note (`//` alone) shows nothing and is dropped too.
    ///
    /// `markdown` (Settings → Markdown formatting): text lines show their Markdown (`ScriptMarkdown`) instead of the
    /// symbols; headings and rules become paragraphs of their own kind, which, like notes, hold no spoken words. Notes
    /// take inline Markdown too. Off: every line is shown as written.
    init(body: String, markdown: Bool = false) {
        var paragraphs: [Paragraph] = []
        for line in ScriptMarkup.lines(of: body, markdown: markdown) {
            let source = body[line.range]
            switch line.kind {
            case .text, .heading:
                if markdown {
                    let parsed = ScriptMarkdown.parse(source)
                    guard parsed.text.contains(where: { !$0.isWhitespace }) else { continue }
                    paragraphs.append(Paragraph(text: parsed.text, kind: line.kind, runs: parsed.runs))
                } else {
                    var shown = source
                    while let last = shown.last, last.isWhitespace { shown.removeLast() }
                    guard shown.contains(where: { !$0.isWhitespace }) else { continue }
                    paragraphs.append(Paragraph(text: String(shown), kind: .text))
                }
            case .rule:
                paragraphs.append(Paragraph(text: ScriptMarkdown.ruleText, kind: .rule))
            case .note:
                let note = ScriptMarkup.noteText(source)
                if markdown {
                    let parsed = MarkdownInline.parse(note)
                    guard parsed.text.contains(where: { !$0.isWhitespace }) else { continue }
                    paragraphs.append(Paragraph(text: parsed.text, kind: .note, runs: parsed.runs))
                } else {
                    guard !note.isEmpty else { continue }
                    paragraphs.append(Paragraph(text: note, kind: .note))
                }
            case .pause(let seconds):
                paragraphs.append(Paragraph(text: ScriptMarkup.cueLabel(seconds: seconds), kind: line.kind))
            }
        }
        self.init(paragraphs: paragraphs)
    }

    init(paragraphs: [Paragraph]) {
        self.paragraphs = paragraphs
        var words = 0
        var marks: [HoldMark] = []
        var offset = 0
        for paragraph in paragraphs {
            switch paragraph.kind {
            case .text: words += ReadingStats.wordCount(of: paragraph.text)
            case .pause(let seconds?): marks.append(HoldMark(characterIndex: offset, seconds: Double(seconds)))
            case .note, .pause(.none), .heading, .rule: break
            }
            offset += paragraph.text.utf16.count + 1   // + the "\n" after it
        }
        text = paragraphs.map(\.text).joined(separator: "\n")
        timedWordCount = words
        holds = marks
    }

    var isEmpty: Bool { paragraphs.isEmpty }
}
