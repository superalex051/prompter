import Foundation

/// What one line of a script is to the prompter.
enum ScriptLineKind: Equatable, Hashable, Sendable {
    /// Words to read aloud (blank lines are text too; they simply have no words).
    case text
    /// `// …`: a note to the presenter, shown small and dimmed, never read or timed.
    case note
    /// `[pause]` or `[pause N]`: a cue line. With N seconds the prompter holds the text that long when the cue reaches
    /// the reading line; a bare `[pause]` is only a visual cue.
    case pause(seconds: Int?)
    /// Markdown on (`ScriptMarkdown`): `# Title` … `###### Title`, a section title. Shown, never read or timed.
    case heading(level: Int)
    /// Markdown on: `---`, `***` or `___`, a thin dividing line.
    case rule
}

/// The script markup, kept deliberately small so it can't surprise anyone:
/// - a line whose text (ignoring surrounding spaces) starts with `//` is a note;
/// - a line that is exactly `[pause]` or `[pause N]` (N = 1…60 seconds, any case, spaces around it allowed, an optional
///   `s` after the number) is a pause cue;
/// - everything else is script text. Only whole lines are markup: a `//` in the middle of a line (a URL, "and/or // aside")
///   or "[pause] for effect" inside a sentence is read as written.
enum ScriptMarkup {
    struct Line: Equatable, Sendable {
        /// The line in the body, without its line break.
        var range: Range<String.Index>
        var kind: ScriptLineKind
    }

    /// The longest timed pause a cue can ask for.
    static let pauseSecondsRange = 1...60

    /// Every line of `body` (blank ones included, as `.text`), in order. Lines break where the prompter breaks them
    /// (any newline character, CRLF counting as one). With `markdown`, headings and rules are told apart too (notes and
    /// cues win over Markdown on their own lines).
    static func lines(of body: String, markdown: Bool = false) -> [Line] {
        var result: [Line] = []
        var start = body.startIndex
        var index = body.startIndex
        while index < body.endIndex {
            if body[index].isNewline {
                result.append(Line(range: start..<index, kind: kind(of: body[start..<index], markdown: markdown)))
                start = body.index(after: index)
            }
            index = body.index(after: index)
        }
        result.append(Line(range: start..<body.endIndex, kind: kind(of: body[start..<body.endIndex], markdown: markdown)))
        return result
    }

    /// The kind of a single line (without its line break). With `markdown`, a text line may be a heading or a rule.
    static func kind(of line: some StringProtocol, markdown: Bool = false) -> ScriptLineKind {
        let trimmed = trimmed(line)
        if trimmed.hasPrefix("//") { return .note }
        if let seconds = pauseCue(trimmed) { return .pause(seconds: seconds) }
        guard markdown else { return .text }
        switch ScriptMarkdown.block(of: line) {
        case .text: return .text
        case .heading(let level): return .heading(level: level)
        case .rule: return .rule
        }
    }

    /// A note's text as the prompter shows it: the slashes and the spaces around the text removed. "" for an empty note.
    static func noteText(_ line: some StringProtocol) -> String {
        var text = trimmed(line)
        while text.first == "/" { text = text.dropFirst() }
        return String(trimmed(text))
    }

    /// "PAUSE" for a bare cue, "PAUSE 3s" for a timed one.
    static func cueLabel(seconds: Int?) -> String {
        seconds.map { "PAUSE \($0)s" } ?? "PAUSE"
    }

    // MARK: Private

    /// nil: not a cue. `.some(nil)`: a bare `[pause]`. `.some(n)`: `[pause n]` with n in 1…60.
    private static func pauseCue(_ line: Substring) -> Int?? {
        guard line.first == "[", line.last == "]", line.count >= 2 else { return nil }
        let inner = trimmed(line.dropFirst().dropLast())
        guard inner.prefix(5).lowercased() == "pause" else { return nil }
        let rest = inner.dropFirst(5)
        if rest.isEmpty { return .some(nil) }
        // "[pauses]" and "[pause3]" aren't cues.
        guard let first = rest.first, first.isWhitespace else { return nil }
        var number = trimmed(rest)
        if number.last == "s" || number.last == "S" { number = trimmed(number.dropLast()) }
        guard !number.isEmpty, number.count <= 2, number.allSatisfy({ $0.isASCII && $0.isNumber }),
              let seconds = Int(number), pauseSecondsRange.contains(seconds)
        else { return nil }
        return .some(seconds)
    }

    private static func trimmed(_ text: some StringProtocol) -> Substring {
        let text = Substring(text)
        guard let first = text.firstIndex(where: { !$0.isWhitespace }),
              let last = text.lastIndex(where: { !$0.isWhitespace })
        else { return text[text.endIndex...] }
        return text[first...last]
    }
}
