import Foundation

/// The inline styles Markdown can give a stretch of script text.
struct MarkdownStyle: OptionSet, Hashable, Sendable {
    let rawValue: UInt8

    /// `**bold**` or `__bold__`: drawn in the scheme's amber cue colour on the prompter.
    static let bold = MarkdownStyle(rawValue: 1 << 0)
    /// `*italic*` or `_italic_`.
    static let italic = MarkdownStyle(rawValue: 1 << 1)
    /// `~~strike~~`: struck through and dimmed.
    static let strikethrough = MarkdownStyle(rawValue: 1 << 2)
    /// `` `code` ``: shown as plain text on the prompter (the editor may set it apart).
    static let code = MarkdownStyle(rawValue: 1 << 3)
}

/// Inline Markdown in one line of a script, parsed with the source kept in view: what the prompter shows (`text`, with
/// its styled `runs`), and for the editor where the hidden markers and the styled spans are in the source.
///
/// A small parser of our own rather than Foundation's `AttributedString(markdown:)`, because the Mac editor needs to know
/// exactly which source characters are markers (to dim them) and which are styled, and both apps must agree on it. It
/// follows CommonMark's rules where they matter for a script, and a test checks it against Foundation's parser:
/// - **Emphasis** with `*` and `_` uses CommonMark's delimiter-run algorithm (left/right-flanking runs, `_` not inside
///   words, the "rule of 3"). An unmatched marker is shown as written, so a stray `*` or `**` never swallows text.
/// - `~~strike~~` (GitHub's strikethrough) needs exactly two tildes on each side; a single `~` stays a tilde.
/// - `` `code` `` spans are literal inside (no emphasis, no escapes); a backtick run without its match is shown as is.
/// - `[text](destination)` and `![alt](source)` show only the text. `[pause] for effect` (no `(…)` after it) stays.
/// - A backslash before ASCII punctuation (`\*`, `\_`, `\[`, `\\`) shows that character literally.
/// - Not handled (shown as written): HTML, entities (`&amp;`), autolinks (`<https://…>`).
enum MarkdownInline {
    /// A styled stretch: UTF-16 offsets into `Parsed.text` (or into the source, for `sourceRuns`).
    struct Run: Equatable, Hashable, Sendable {
        var range: Range<Int>
        var style: MarkdownStyle
    }

    struct Parsed: Equatable, Sendable {
        /// What the prompter shows: the source without its markers.
        var text: String
        /// The styled stretches of `text`, in order, never empty and never touching another run of the same style.
        var runs: [Run]
        /// The source's hidden markers (`**`, `_`, `` ` ``, `[`, `](url)`, the `\` of an escape), UTF-16 offsets into
        /// the source, in order, merged where adjacent.
        var markers: [Range<Int>]
        /// The styled stretches of the source (shown characters only), UTF-16 offsets into the source.
        var sourceRuns: [Run]

        /// A line with no Markdown in it.
        static func plain(_ text: String) -> Parsed {
            Parsed(text: text, runs: [], markers: [], sourceRuns: [])
        }
    }

    /// Characters that can start inline Markdown; a line without any of them is returned as it is.
    private static let triggers: Set<Character> = ["*", "_", "~", "`", "[", "\\"]

    static func parse(_ source: some StringProtocol) -> Parsed {
        let source = String(source)
        guard source.contains(where: { triggers.contains($0) }) else { return .plain(source) }
        var parser = Parser(source)
        parser.scan(0..<parser.chars.count)
        return parser.result()
    }

    // MARK: - Parser

    private struct Delimiter {
        var char: Character
        /// The run's remaining characters: openers are used up from the right, closers from the left.
        var lo: Int
        var hi: Int
        let length: Int
        let canOpen: Bool
        let canClose: Bool
        var isActive = true

        var remaining: Int { hi - lo }
    }

    private struct Parser {
        let chars: [Character]
        /// UTF-16 offset of each character in the source (one extra entry: the source's length).
        let offsets: [Int]
        var hidden: [Bool]
        var styles: [MarkdownStyle]

        init(_ source: String) {
            chars = Array(source)
            var offsets: [Int] = []
            offsets.reserveCapacity(chars.count + 1)
            var offset = 0
            for char in chars {
                offsets.append(offset)
                offset += char.utf16.count
            }
            offsets.append(offset)
            self.offsets = offsets
            hidden = Array(repeating: false, count: chars.count)
            styles = Array(repeating: [], count: chars.count)
        }

        /// Parses `range` (a whole line, or a link's text): code spans, escapes and links in one pass, then emphasis.
        mutating func scan(_ range: Range<Int>) {
            var delimiters: [Delimiter] = []
            var index = range.lowerBound
            let end = range.upperBound
            while index < end {
                let char = chars[index]
                if char == "\\", index + 1 < end, Self.isEscapable(chars[index + 1]) {
                    hidden[index] = true
                    index += 2
                } else if char == "`" {
                    index = codeSpan(at: index, end: end)
                } else if char == "[", let link = link(openingAt: index, end: end) {
                    hide(index..<(index + 1))
                    hide(link.textEnd..<(link.end))
                    scan((index + 1)..<link.textEnd)
                    index = link.end
                } else if char == "!", index + 1 < end, chars[index + 1] == "[",
                          let link = link(openingAt: index + 1, end: end) {
                    hide(index..<(index + 2))
                    hide(link.textEnd..<(link.end))
                    scan((index + 2)..<link.textEnd)
                    index = link.end
                } else if char == "*" || char == "_" || char == "~" {
                    var runEnd = index
                    while runEnd < end, chars[runEnd] == char { runEnd += 1 }
                    delimiters.append(delimiter(char, from: index, to: runEnd))
                    index = runEnd
                } else {
                    index += 1
                }
            }
            processEmphasis(&delimiters)
        }

        // MARK: Code spans

        /// A backtick run at `start`: a code span up to the next run of the same length (its content literal, one
        /// space trimmed from each side when both have one), or the run shown as written. Returns where to go on.
        mutating func codeSpan(at start: Int, end: Int) -> Int {
            let length = backtickRun(at: start, end: end)
            guard let close = closingBackticks(after: start + length, length: length, end: end) else {
                return start + length
            }
            hide(start..<(start + length))
            hide(close..<(close + length))
            var contentStart = start + length
            var contentEnd = close
            if contentEnd - contentStart >= 2, chars[contentStart] == " ", chars[contentEnd - 1] == " ",
               chars[contentStart..<contentEnd].contains(where: { $0 != " " }) {
                hide(contentStart..<(contentStart + 1))
                hide((contentEnd - 1)..<contentEnd)
                contentStart += 1
                contentEnd -= 1
            }
            for index in contentStart..<contentEnd { styles[index].insert(.code) }
            return close + length
        }

        func backtickRun(at start: Int, end: Int) -> Int {
            var index = start
            while index < end, chars[index] == "`" { index += 1 }
            return index - start
        }

        /// The start of the next backtick run of exactly `length` at or after `from`.
        func closingBackticks(after from: Int, length: Int, end: Int) -> Int? {
            var index = from
            while index < end {
                guard chars[index] == "`" else {
                    index += 1
                    continue
                }
                let run = backtickRun(at: index, end: end)
                if run == length { return index }
                index += run
            }
            return nil
        }

        // MARK: Links

        /// `[text](destination "title")` opening at `open`: the index of its `]` and the index just past its `)`.
        /// Brackets nest; escapes and code spans inside the text don't count. The destination may hold balanced
        /// parentheses; after a space only a quoted or parenthesised title may follow (else it isn't a link).
        func link(openingAt open: Int, end: Int) -> (textEnd: Int, end: Int)? {
            var depth = 1
            var index = open + 1
            var textEnd: Int?
            while index < end {
                let char = chars[index]
                if char == "\\", index + 1 < end, Self.isEscapable(chars[index + 1]) {
                    index += 2
                    continue
                }
                if char == "`" {
                    let length = backtickRun(at: index, end: end)
                    if let close = closingBackticks(after: index + length, length: length, end: end) {
                        index = close + length
                    } else {
                        index += length
                    }
                    continue
                }
                if char == "[" { depth += 1 }
                if char == "]" {
                    depth -= 1
                    if depth == 0 {
                        textEnd = index
                        break
                    }
                }
                index += 1
            }
            guard let textEnd, textEnd + 1 < end, chars[textEnd + 1] == "(" else { return nil }
            var parens = 1
            index = textEnd + 2
            while index < end {
                let char = chars[index]
                if char == "\\", index + 1 < end, Self.isEscapable(chars[index + 1]) {
                    index += 2
                    continue
                }
                if char == "(" { parens += 1 }
                if char == ")" {
                    parens -= 1
                    if parens == 0 { break }
                }
                index += 1
            }
            guard index < end, parens == 0 else { return nil }
            // The destination has no spaces; anything after one must be a title in quotes or parentheses.
            let inside = String(chars[(textEnd + 2)..<index]).trimmingCharacters(in: .whitespaces)
            if let space = inside.firstIndex(where: \.isWhitespace) {
                let title = inside[space...].drop(while: \.isWhitespace)
                guard let first = title.first, let last = title.last, title.count >= 2,
                      (first == "\"" && last == "\"") || (first == "'" && last == "'") || (first == "(" && last == ")")
                else { return nil }
            }
            return (textEnd, index + 1)
        }

        // MARK: Emphasis

        /// A run of `*`, `_` or `~` and what it can do, by CommonMark's flanking rules (a line's start and end count as
        /// whitespace; punctuation includes symbols).
        func delimiter(_ char: Character, from start: Int, to end: Int) -> Delimiter {
            let before: Character? = start > 0 ? chars[start - 1] : nil
            let after: Character? = end < chars.count ? chars[end] : nil
            let beforeIsSpace = before.map(\.isWhitespace) ?? true
            let afterIsSpace = after.map(\.isWhitespace) ?? true
            let beforeIsPunctuation = before.map(Self.isPunctuation) ?? false
            let afterIsPunctuation = after.map(Self.isPunctuation) ?? false
            let leftFlanking = !afterIsSpace && (!afterIsPunctuation || beforeIsSpace || beforeIsPunctuation)
            let rightFlanking = !beforeIsSpace && (!beforeIsPunctuation || afterIsSpace || afterIsPunctuation)
            let canOpen: Bool
            let canClose: Bool
            switch char {
            case "_":
                canOpen = leftFlanking && (!rightFlanking || beforeIsPunctuation)
                canClose = rightFlanking && (!leftFlanking || afterIsPunctuation)
            case "~":
                // Strikethrough takes exactly two tildes.
                canOpen = leftFlanking && end - start == 2
                canClose = rightFlanking && end - start == 2
            default:
                canOpen = leftFlanking
                canClose = rightFlanking
            }
            return Delimiter(char: char, lo: start, hi: end, length: end - start, canOpen: canOpen, canClose: canClose)
        }

        /// CommonMark's "process emphasis": each closer, left to right, pairs with the nearest opener of the same
        /// character that it may pair with; the delimiters between them become literal. Two of each side make bold
        /// (or a strikethrough with `~`), one makes italic; leftover characters stay to pair again or show as written.
        mutating func processEmphasis(_ delimiters: inout [Delimiter]) {
            for closerIndex in delimiters.indices where delimiters[closerIndex].canClose {
                while delimiters[closerIndex].isActive, delimiters[closerIndex].remaining > 0 {
                    let closer = delimiters[closerIndex]
                    guard let openerIndex = opener(for: closer, before: closerIndex, in: delimiters) else { break }
                    let opener = delimiters[openerIndex]
                    let used = closer.char == "~" ? 2 : (opener.remaining >= 2 && closer.remaining >= 2 ? 2 : 1)
                    let style: MarkdownStyle = closer.char == "~" ? .strikethrough : (used == 2 ? .bold : .italic)
                    let contentStart = opener.hi
                    let contentEnd = closer.lo
                    hide((opener.hi - used)..<opener.hi)
                    hide(closer.lo..<(closer.lo + used))
                    for index in contentStart..<contentEnd { styles[index].insert(style) }
                    delimiters[openerIndex].hi -= used
                    delimiters[closerIndex].lo += used
                    if delimiters[openerIndex].remaining == 0 { delimiters[openerIndex].isActive = false }
                    for between in (openerIndex + 1)..<closerIndex { delimiters[between].isActive = false }
                }
            }
        }

        func opener(for closer: Delimiter, before closerIndex: Int, in delimiters: [Delimiter]) -> Int? {
            var index = closerIndex - 1
            while index >= 0 {
                let candidate = delimiters[index]
                if candidate.isActive, candidate.canOpen, candidate.char == closer.char, candidate.remaining > 0 {
                    if closer.char == "~" {
                        if candidate.remaining == 2, closer.remaining == 2 { return index }
                    } else {
                        // The rule of 3: a run that can both open and close doesn't pair with one whose lengths add up
                        // to a multiple of 3, unless both are multiples of 3 (so "*foo**bar*" stays one emphasis).
                        let bothWays = candidate.canClose || closer.canOpen
                        let sum = candidate.length + closer.length
                        if !(bothWays && sum % 3 == 0 && !(candidate.length % 3 == 0 && closer.length % 3 == 0)) {
                            return index
                        }
                    }
                }
                index -= 1
            }
            return nil
        }

        // MARK: Output

        mutating func hide(_ range: Range<Int>) {
            for index in range where index < hidden.count { hidden[index] = true }
        }

        func result() -> Parsed {
            var text = ""
            var runs: [Run] = []
            var markers: [Range<Int>] = []
            var sourceRuns: [Run] = []
            var outputOffset = 0
            for index in chars.indices {
                let length = chars[index].utf16.count
                let sourceRange = offsets[index]..<(offsets[index] + length)
                if hidden[index] {
                    Self.append(sourceRange, to: &markers)
                    continue
                }
                text.append(chars[index])
                let style = styles[index]
                if !style.isEmpty {
                    Self.append(Run(range: outputOffset..<(outputOffset + length), style: style), to: &runs)
                    Self.append(Run(range: sourceRange, style: style), to: &sourceRuns)
                }
                outputOffset += length
            }
            return Parsed(text: text, runs: runs, markers: markers, sourceRuns: sourceRuns)
        }

        static func append(_ range: Range<Int>, to ranges: inout [Range<Int>]) {
            if let last = ranges.last, last.upperBound == range.lowerBound {
                ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
            } else {
                ranges.append(range)
            }
        }

        static func append(_ run: Run, to runs: inout [Run]) {
            if let last = runs.last, last.style == run.style, last.range.upperBound == run.range.lowerBound {
                runs[runs.count - 1].range = last.range.lowerBound..<run.range.upperBound
            } else {
                runs.append(run)
            }
        }

        /// CommonMark's escapable characters: ASCII punctuation.
        static func isEscapable(_ char: Character) -> Bool {
            char.isASCII && (char.isPunctuation || char.isSymbol)
        }

        /// Unicode punctuation or symbols (CommonMark counts both for flanking).
        static func isPunctuation(_ char: Character) -> Bool {
            char.isPunctuation || char.isSymbol
        }
    }
}
