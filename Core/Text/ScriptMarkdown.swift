import Foundation

/// Markdown in a script, one line at a time (Settings → Markdown formatting). Only lines that `ScriptMarkup` reads as
/// text get here: `// notes` and `[pause N]` cues win over Markdown on their own lines.
///
/// Blocks, on a single line each:
/// - `# `, `## ` … `###### ` (the `#`s then a space): a heading, shown as a section title (amber, a little larger). Not a
///   spoken line, so like a note it adds no words and scrolls past at the reading pace. `#hashtag` and `#1` stay text.
///   A closing run of `#`s is dropped.
/// - `---`, `***`, `___` (three or more, spaces allowed between): a rule, shown as a thin dimmed line.
/// - `- `, `* `, `+ `: a bullet, shown as "• ". Indentation before it is kept, so nested lists stay nested.
/// - `1. ` / `1) `: shown exactly as written (the number is kept, and read like any other word).
/// - `> ` (one or more): a quote, shown as plain text without the `>`s (a quoted bullet or heading works too).
/// Inside every line the inline Markdown of `MarkdownInline` applies.
enum ScriptMarkdown {
    enum Block: Equatable, Sendable {
        case text
        case heading(level: Int)
        case rule
    }

    struct Line: Equatable, Sendable {
        var block: Block
        /// What the prompter shows: indentation, "• " for a bullet, then the text without its markers; trailing spaces
        /// trimmed. Empty for a rule (the prompter draws `ruleText`).
        var text: String
        /// Inline styles in `text` (UTF-16 offsets).
        var runs: [MarkdownInline.Run]
        /// Markers in the source line, block and inline (UTF-16 offsets into the line), for the editor to dim.
        var markers: [Range<Int>]
        /// Styled stretches of the source line (UTF-16 offsets into the line), for the editor.
        var sourceRuns: [MarkdownInline.Run]
    }

    /// What a bullet's marker becomes on the prompter.
    static let bulletPrefix = "• "
    /// What a rule is drawn as: a short run of box-drawing lines (they join up into one thin line).
    static let ruleText = String(repeating: "\u{2500}", count: 12)

    /// The block of a line, without parsing its inline Markdown.
    static func block(of line: some StringProtocol) -> Block {
        Structure(String(line)).block
    }

    static func parse(_ line: some StringProtocol) -> Line {
        let structure = Structure(String(line))
        let chars = structure.chars
        let offsets = structure.offsets
        switch structure.block {
        case .rule:
            let whole = chars.isEmpty ? [] : [0..<offsets[chars.count]]
            return Line(block: .rule, text: "", runs: [], markers: whole, sourceRuns: [])
        case .heading, .text:
            let contentRange = structure.contentStart..<structure.contentEnd
            let inline = MarkdownInline.parse(String(chars[contentRange]))
            let shift = offsets[structure.contentStart]
            var markers = structure.blockMarkers
            for marker in inline.markers { markers.append((marker.lowerBound + shift)..<(marker.upperBound + shift)) }
            markers.sort { $0.lowerBound < $1.lowerBound }
            let sourceRuns = inline.sourceRuns.map {
                MarkdownInline.Run(range: ($0.range.lowerBound + shift)..<($0.range.upperBound + shift), style: $0.style)
            }
            let prefix = structure.shownPrefix
            let prefixLength = prefix.utf16.count
            var text = prefix + inline.text
            var runs = inline.runs.map {
                MarkdownInline.Run(
                    range: ($0.range.lowerBound + prefixLength)..<($0.range.upperBound + prefixLength), style: $0.style
                )
            }
            // Trailing spaces trimmed, as for a plain line; runs clipped to what's left.
            while let last = text.last, last.isWhitespace { text.removeLast() }
            let length = text.utf16.count
            runs = runs.compactMap { run in
                let upper = min(run.range.upperBound, length)
                return run.range.lowerBound < upper
                    ? MarkdownInline.Run(range: run.range.lowerBound..<upper, style: run.style) : nil
            }
            return Line(block: structure.block, text: text, runs: runs, markers: markers, sourceRuns: sourceRuns)
        }
    }

    // MARK: - Block structure

    /// The block markers of a line: quotes, then a rule, a heading or a bullet.
    private struct Structure {
        let chars: [Character]
        let offsets: [Int]
        var block: Block = .text
        /// The inline content, as character indices.
        var contentStart = 0
        var contentEnd = 0
        /// Shown before the content: the indentation (unquoted text and bullets) and "• " for a bullet.
        var shownPrefix = ""
        var blockMarkers: [Range<Int>] = []

        init(_ line: String) {
            chars = Array(line)
            var offsets: [Int] = []
            offsets.reserveCapacity(chars.count + 1)
            var offset = 0
            for char in chars {
                offsets.append(offset)
                offset += char.utf16.count
            }
            offsets.append(offset)
            self.offsets = offsets
            contentEnd = chars.count

            let count = chars.count
            var index = 0
            while index < count, Self.isSpace(chars[index]) { index += 1 }
            let indentEnd = index

            // Quotes: each `>` and the spaces after it.
            var isQuoted = false
            while index < count, chars[index] == ">" {
                isQuoted = true
                let start = index
                index += 1
                while index < count, Self.isSpace(chars[index]) { index += 1 }
                blockMarkers.append(offsets[start]..<offsets[index])
            }
            let indentation = isQuoted ? "" : String(chars[0..<indentEnd])

            if Self.isRule(chars[index...]) {
                block = .rule
                return
            }

            // A heading: 1…6 `#`s, then a space or the end of the line.
            var hashes = index
            while hashes < count, chars[hashes] == "#" { hashes += 1 }
            let level = hashes - index
            if (1...6).contains(level), hashes == count || Self.isSpace(chars[hashes]) {
                block = .heading(level: level)
                var start = hashes
                while start < count, Self.isSpace(chars[start]) { start += 1 }
                blockMarkers.append(offsets[index]..<offsets[start])
                var end = count
                while end > start, Self.isSpace(chars[end - 1]) { end -= 1 }
                // A closing run of `#`s, after a space (or making up the whole title), isn't part of the title.
                var closing = end
                while closing > start, chars[closing - 1] == "#" { closing -= 1 }
                if closing < end, closing == start || Self.isSpace(chars[closing - 1]) {
                    blockMarkers.append(offsets[closing]..<offsets[end])
                    end = closing
                    while end > start, Self.isSpace(chars[end - 1]) { end -= 1 }
                }
                contentStart = start
                contentEnd = end
                return
            }

            // A bullet: `-`, `*` or `+`, then a space.
            if index + 1 < count, ["-", "*", "+"].contains(chars[index]), Self.isSpace(chars[index + 1]) {
                var start = index + 1
                while start < count, Self.isSpace(chars[start]) { start += 1 }
                blockMarkers.append(offsets[index]..<offsets[start])
                contentStart = start
                shownPrefix = indentation + ScriptMarkdown.bulletPrefix
                return
            }

            // Text (numbered lines included, as written).
            contentStart = isQuoted ? index : indentEnd
            shownPrefix = indentation
        }

        /// Three or more of one of `-`, `*`, `_`, with nothing else but spaces.
        static func isRule(_ chars: ArraySlice<Character>) -> Bool {
            guard let mark = chars.first(where: { !isSpace($0) }), ["-", "*", "_"].contains(mark) else { return false }
            var marks = 0
            for char in chars {
                if char == mark {
                    marks += 1
                } else if !isSpace(char) {
                    return false
                }
            }
            return marks >= 3
        }

        static func isSpace(_ char: Character) -> Bool {
            char == " " || char == "\t"
        }
    }
}
