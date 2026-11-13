import Foundation

/// The laid-out script as the scroll engine sees it: where each visual line starts, in points from the top of the text,
/// and which UTF-16 character it starts with. Built by the text view from TextKit after every layout pass.
struct PrompterLayout: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        /// Top of the line fragment, relative to the top of the text (first line y = 0).
        var y: Double
        var height: Double
        /// UTF-16 offset of the first character of the line.
        var characterIndex: Int
        /// The first line of a paragraph with text (paragraph steps and "jump back" land only on these).
        var startsParagraph: Bool
    }

    /// A place in the text that survives relayout: the first character of a line plus how far through that line's span
    /// (its top to the next line's top) the position is, 0…1.
    struct Anchor: Equatable, Sendable {
        var characterIndex: Int
        var fraction: Double
    }

    /// A `[pause N]` cue: playing holds the text for `seconds` when the position reaches `y` (the top of the cue's line).
    struct Hold: Equatable, Sendable {
        var y: Double
        var seconds: Double
        /// UTF-16 offset of the cue's first character; identifies the cue across relayouts.
        var characterIndex: Int
    }

    /// Document order, y ascending.
    var lines: [Line]
    /// Height of all laid-out text.
    var contentHeight: Double
    /// Words on text lines only (notes and cues aren't read, so they don't set the WPM pace).
    var wordCount: Int
    /// y ascending.
    var holds: [Hold]
    /// The part of `contentHeight` the words are spread over: the spans of the text paragraphs' lines (see
    /// `timedHeight(of:contentHeight:isTimed:)`). Notes and cues scroll past at the same speed but hold no words, so the
    /// WPM pace is `wordCount` words per `timedHeight`, and each spoken line takes as long with notes as without.
    var timedHeight: Double

    /// `timedHeight` nil: every line is text (it is then `contentHeight`).
    init(lines: [Line], contentHeight: Double, wordCount: Int, holds: [Hold] = [], timedHeight: Double? = nil) {
        self.lines = lines
        self.contentHeight = contentHeight
        self.wordCount = wordCount
        self.holds = holds
        self.timedHeight = timedHeight ?? contentHeight
    }

    static let empty = PrompterLayout(lines: [], contentHeight: 0, wordCount: 0)

    /// The summed spans of the lines `isTimed` picks. A line's span runs from its top to the next line's top (the last
    /// line's to `contentHeight`), so it carries the line spacing and the paragraph gap after it; the first line's span
    /// starts at 0. With every line picked that is exactly `contentHeight`.
    static func timedHeight(of lines: [Line], contentHeight: Double, isTimed: (Line) -> Bool) -> Double {
        var total = 0.0
        for (index, line) in lines.enumerated() where isTimed(line) {
            let top = index == 0 ? min(line.y, 0) : line.y
            let bottom = index + 1 < lines.count ? lines[index + 1].y : max(contentHeight, line.y)
            total += max(bottom - top, 0)
        }
        return total
    }

    /// Every hold together.
    var totalHoldSeconds: Double {
        holds.reduce(0) { $0 + max($1.seconds, 0) }
    }

    /// contentHeight / lines.count, or 1 when there is nothing to measure (so speeds never become 0 or NaN).
    var averageLinePitch: Double {
        guard !lines.isEmpty, contentHeight.isFinite, contentHeight > 0 else { return 1 }
        return contentHeight / Double(lines.count)
    }

    /// The line containing `position`: the last line whose top is at or above it (so a paragraph gap belongs to the
    /// line above it). Clamped to the first and last line; nil if there are no lines.
    func lineIndex(at position: Double) -> Int? {
        guard !lines.isEmpty else { return nil }
        guard !position.isNaN else { return 0 }
        // Binary search for the first line whose top is below `position`.
        var low = 0
        var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].y <= position { low = mid + 1 } else { high = mid }
        }
        return max(low - 1, 0)
    }

    /// The first character of the line at `position`; 0 if there are no lines.
    func characterIndex(at position: Double) -> Int {
        lineIndex(at: position).map { lines[$0].characterIndex } ?? 0
    }

    /// The top of the line containing the character at `index` (clamped to the first and last line); 0 if no lines.
    func position(ofCharacterIndex index: Int) -> Double {
        lineIndex(containingCharacter: index).map { lines[$0].y } ?? 0
    }

    /// The anchor for `position`; see `Anchor`.
    func anchor(at position: Double) -> Anchor {
        guard let index = lineIndex(at: position) else { return Anchor(characterIndex: 0, fraction: 0) }
        let span = span(ofLine: index)
        let fraction = span > 0 ? (position - lines[index].y) / span : 0
        return Anchor(characterIndex: lines[index].characterIndex, fraction: min(max(fraction, 0), 1))
    }

    /// Where `anchor` is in this layout: the line now holding its character, the same fraction through that line's span.
    /// Clamped to 0…contentHeight.
    func position(of anchor: Anchor) -> Double {
        guard let index = lineIndex(containingCharacter: anchor.characterIndex) else { return 0 }
        let fraction = anchor.fraction.isFinite ? min(max(anchor.fraction, 0), 1) : 0
        let position = lines[index].y + fraction * span(ofLine: index)
        return min(max(position, 0), max(contentHeight, 0))
    }

    // MARK: Private

    /// The last line starting at or before character `index`, clamped to the first line; nil if no lines.
    private func lineIndex(containingCharacter index: Int) -> Int? {
        guard !lines.isEmpty else { return nil }
        var low = 0
        var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].characterIndex <= index { low = mid + 1 } else { high = mid }
        }
        return max(low - 1, 0)
    }

    /// From this line's top to the next line's top (or to the end of the text for the last line).
    private func span(ofLine index: Int) -> Double {
        let end = index + 1 < lines.count ? lines[index + 1].y : contentHeight
        let span = end - lines[index].y
        return span > 0 ? span : max(lines[index].height, 0)
    }
}
