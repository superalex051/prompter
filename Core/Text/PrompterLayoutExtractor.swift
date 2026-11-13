import CoreGraphics
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Reads line positions out of TextKit 2 for the scroll engine.
enum PrompterLayoutExtractor {
    /// The layout of `document` as laid out by `textLayoutManager`: its timed words, its holds, and the text paragraphs'
    /// share of the height (`PrompterLayout.timedHeight`).
    @MainActor
    static func layout(of textLayoutManager: NSTextLayoutManager, document: PrompterDocument) -> PrompterLayout {
        layout(
            of: textLayoutManager,
            wordCount: document.timedWordCount,
            holds: document.holds,
            timedRanges: document.timedRanges
        )
    }

    /// The layout of `document` drawn in `style`, laid out by a TextKit 2 stack of its own (no view): the attributed
    /// string from `PrompterText.attributedString(_:style:)` in a text container `style.textWidth` wide with no line
    /// fragment padding, exactly what the prompter's text view lays out between its side insets. Coordinates are the
    /// text container's (first line y = 0), so a text view whose container starts at the reading line shows position p
    /// at the reading line by scrolling to p. Used on the Mac, by previews and by tests.
    @MainActor
    static func layout(of document: PrompterDocument, style: PrompterTextStyle) -> PrompterLayout {
        layout(of: PrompterText.attributedString(document, style: style), width: style.textWidth, document: document)
    }

    /// The layout of an already built `attributedString` (the text of `document`), wrapped at `width` points.
    @MainActor
    static func layout(of attributedString: NSAttributedString, width: Double, document: PrompterDocument) -> PrompterLayout {
        let stack = TextKitStack(attributedString: attributedString, width: width)
        // The layout manager holds its content manager weakly: keep the whole stack alive while it lays out.
        return withExtendedLifetime(stack) { layout(of: stack.layoutManager, document: document) }
    }

    /// A view-less TextKit 2 stack: content storage → layout manager → container (unlimited height).
    @MainActor
    struct TextKitStack {
        let contentStorage: NSTextContentStorage
        let layoutManager: NSTextLayoutManager
        let container: NSTextContainer

        init(attributedString: NSAttributedString, width: Double) {
            contentStorage = NSTextContentStorage()
            layoutManager = NSTextLayoutManager()
            container = NSTextContainer(size: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            layoutManager.textContainer = container
            contentStorage.addTextLayoutManager(layoutManager)
            contentStorage.attributedString = attributedString
        }
    }

    /// Lays out the whole document and returns every non-blank line: y = fragment top + line top (text-container
    /// coordinates, first line 0), UTF-16 character index, and whether it starts a paragraph.
    /// contentHeight = bottom of the last layout fragment. Each hold mark becomes a hold at the top of its cue's line.
    /// timedHeight = the spans of the lines starting inside `timedRanges` (UTF-16 ranges of the text paragraphs, in
    /// order); nil: every line is text. Empty text → `.empty`.
    @MainActor
    static func layout(
        of textLayoutManager: NSTextLayoutManager,
        wordCount: Int,
        holds marks: [PrompterDocument.HoldMark] = [],
        timedRanges: [Range<Int>]? = nil
    ) -> PrompterLayout {
        guard let contentManager = textLayoutManager.textContentManager else { return .empty }
        let documentRange = textLayoutManager.documentRange
        guard !documentRange.isEmpty else { return .empty }
        let start = documentRange.location
        textLayoutManager.ensureLayout(for: documentRange)

        var lines: [PrompterLayout.Line] = []
        var bottom = 0.0
        textLayoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            bottom = max(bottom, frame.maxY)
            let elementOffset = contentManager.offset(from: start, to: fragment.rangeInElement.location)
            var isFirstLineWithText = true
            for line in fragment.textLineFragments {
                let source = line.attributedString.string
                guard let range = Range(line.characterRange, in: source),
                      source[range].contains(where: { !$0.isWhitespace }) else { continue }
                let bounds = line.typographicBounds
                lines.append(PrompterLayout.Line(
                    y: frame.minY + bounds.minY,
                    height: bounds.height,
                    characterIndex: elementOffset + line.characterRange.location,
                    startsParagraph: isFirstLineWithText
                ))
                isFirstLineWithText = false
            }
            return true
        }
        guard !lines.isEmpty, bottom.isFinite, bottom > 0 else { return .empty }
        lines.sort { $0.y < $1.y }
        let holds = marks.compactMap { mark -> PrompterLayout.Hold? in
            // A cue is one short line starting at the mark; fall back to the line holding that character.
            guard let line = lines.first(where: { $0.characterIndex == mark.characterIndex })
                ?? lines.last(where: { $0.characterIndex <= mark.characterIndex })
            else { return nil }
            return PrompterLayout.Hold(y: line.y, seconds: mark.seconds, characterIndex: mark.characterIndex)
        }
        let timedHeight = timedRanges.map { ranges in
            PrompterLayout.timedHeight(of: lines, contentHeight: bottom) { line in
                // The last range starting at or before the line's first character (binary search: ranges are in order).
                var low = 0
                var high = ranges.count
                while low < high {
                    let mid = (low + high) / 2
                    if ranges[mid].lowerBound <= line.characterIndex { low = mid + 1 } else { high = mid }
                }
                return low > 0 && ranges[low - 1].contains(line.characterIndex)
            }
        }
        return PrompterLayout(
            lines: lines,
            contentHeight: bottom,
            wordCount: wordCount,
            holds: holds.sorted { $0.y < $1.y },
            timedHeight: timedHeight
        )
    }
}

extension PrompterDocument {
    /// The UTF-16 ranges of the text paragraphs in `text` (notes and cues aren't read aloud), in order.
    var timedRanges: [Range<Int>] {
        var ranges: [Range<Int>] = []
        var offset = 0
        for paragraph in paragraphs {
            let length = paragraph.text.utf16.count
            if paragraph.kind == .text { ranges.append(offset..<(offset + length)) }
            offset += length + 1   // + the "\n" after it
        }
        return ranges
    }
}
