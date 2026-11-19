import CoreGraphics
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// How the prompter turns a script and the settings into text on the canvas. Pure functions, so they can be tested.
enum PrompterText {
    /// The iPhone 17 Pro screen in landscape, which the font size setting is calibrated for. On iPad the font scales so the
    /// text fills a similar share of the canvas (see `PrompterTextStyle.fontScale`).
    static let referenceSize = CGSize(width: 874, height: 402)

    /// The script body as the prompter shows it (see `PrompterDocument`): one paragraph per non-blank line, trailing
    /// spaces trimmed, notes without their `//`, pause cues as "PAUSE" / "PAUSE 3s".
    static func displayText(from body: String) -> String {
        PrompterDocument(body: body).text
    }

    /// Notes are drawn at this fraction of the font size, italic, at this opacity of the text colour.
    static let noteScale = 0.55
    static let noteOpacity = 0.45
    /// Pause cues are drawn at this fraction of the font size, heavy, centred, amber, letter-spaced by this many ems.
    static let cueScale = 0.5
    static let cueTracking = 0.12

    /// Markdown headings: this many times the font size for `#`, `##`, and `###` and deeper.
    static let headingScales: [Double] = [1.2, 1.1, 1.0]
    /// Markdown rules are drawn at the note size and opacity, in a regular weight (a thin line).
    static let ruleScale = noteScale
    /// Markdown `~~strike~~` text keeps this share of its colour's opacity.
    static let strikethroughOpacity = 0.5

    static func headingScale(level: Int) -> Double {
        headingScales[min(max(level, 1), headingScales.count) - 1]
    }

    /// The whole document: text paragraphs as `attributedString(_:style:)`, notes small, italic and dimmed, pause cues as
    /// a short centred amber "PAUSE" line, Markdown headings as slightly larger amber titles and rules as a thin dimmed
    /// line. Markdown's inline styles go on top (`applyInline`): bold in amber, italic, strikethrough dimmed. Every
    /// paragraph keeps the same paragraph spacing, so the gaps match.
    static func attributedString(_ document: PrompterDocument, style: PrompterTextStyle) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var attributesByKind: [ScriptLineKind: [NSAttributedString.Key: Any]] = [:]
        let last = document.paragraphs.count - 1
        for (index, paragraph) in document.paragraphs.enumerated() {
            // Cues share one look whatever their duration.
            let key: ScriptLineKind = if case .pause = paragraph.kind { .pause(seconds: nil) } else { paragraph.kind }
            let attributes = attributesByKind[key] ?? Self.attributes(for: key, style: style)
            attributesByKind[key] = attributes
            // The line break belongs to its paragraph, so it carries that paragraph's style.
            let string = index < last ? paragraph.text + "\n" : paragraph.text
            let start = result.length
            result.append(NSAttributedString(string: string, attributes: attributes))
            for run in paragraph.runs {
                applyInline(run.style, to: result, range: NSRange(location: start + run.range.lowerBound,
                                                                  length: run.range.count),
                            base: attributes, style: style)
            }
        }
        return result
    }

    /// Markdown's inline styles over `range`, on top of its paragraph's `base` attributes: bold takes the scheme's
    /// amber cue colour (at the paragraph's opacity, so a bold word in a note stays dim), italic the italic of the same
    /// font, strikethrough a line through the text and half its opacity. `code` changes nothing.
    static func applyInline(
        _ inline: MarkdownStyle,
        to string: NSMutableAttributedString,
        range: NSRange,
        base: [NSAttributedString.Key: Any],
        style: PrompterTextStyle
    ) {
        guard range.location >= 0, NSMaxRange(range) <= string.length, range.length > 0 else { return }
        guard let baseColor = base[.foregroundColor] as? PlatformColor,
              let baseFont = base[.font] as? PlatformFont
        else { return }
        var color = baseColor
        if inline.contains(.bold) {
            color = style.scheme.cueColor.withAlphaComponent(baseColor.cgColor.alpha)
        }
        if inline.contains(.strikethrough) {
            color = color.withAlphaComponent(color.cgColor.alpha * strikethroughOpacity)
            string.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            string.addAttribute(.strikethroughColor, value: color, range: range)
        }
        if color != baseColor { string.addAttribute(.foregroundColor, value: color, range: range) }
        if inline.contains(.italic) {
            string.addAttribute(.font, value: italicSystemFont(ofSize: baseFont.pointSize, weight: style.fontWeight),
                                range: range)
        }
    }

    /// Plain script text, every paragraph styled as `.text`: system font, extra line spacing below each line (so a line's
    /// glyphs start right under the reading line), half a font size between paragraphs.
    static func attributedString(_ text: String, style: PrompterTextStyle) -> NSAttributedString {
        NSAttributedString(string: text, attributes: attributes(for: .text, style: style))
    }

    /// The attributes of one kind of paragraph. Line spacing follows each kind's own font, so a small note line is
    /// spaced like the text, only smaller; the paragraph spacing is the text's for every kind.
    static func attributes(for kind: ScriptLineKind, style: PrompterTextStyle) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = style.paragraphSpacing
        paragraph.alignment = .natural
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.hyphenationFactor = 0
        let foreground = style.scheme.foregroundColor

        switch kind {
        case .text:
            let font = PlatformFont.systemFont(ofSize: style.fontSize, weight: style.fontWeight)
            paragraph.lineSpacing = style.lineSpacing(for: font)
            return [.font: font, .foregroundColor: foreground, .paragraphStyle: paragraph]
        case .note:
            let font = italicSystemFont(ofSize: style.fontSize * noteScale, weight: style.fontWeight)
            paragraph.lineSpacing = style.lineSpacing(for: font)
            return [
                .font: font,
                .foregroundColor: foreground.withAlphaComponent(noteOpacity),
                .paragraphStyle: paragraph,
            ]
        case .heading(let level):
            let font = PlatformFont.systemFont(ofSize: style.fontSize * headingScale(level: level), weight: style.fontWeight)
            paragraph.lineSpacing = style.lineSpacing(for: font)
            return [.font: font, .foregroundColor: style.scheme.cueColor, .paragraphStyle: paragraph]
        case .rule:
            let font = PlatformFont.systemFont(ofSize: style.fontSize * ruleScale, weight: .regular)
            paragraph.lineSpacing = style.lineSpacing(for: font)
            paragraph.alignment = .center
            return [
                .font: font,
                .foregroundColor: foreground.withAlphaComponent(noteOpacity),
                .paragraphStyle: paragraph,
            ]
        case .pause:
            let size = style.fontSize * cueScale
            let font = PlatformFont.systemFont(ofSize: size, weight: style.weight == .black ? .black : .heavy)
            paragraph.lineSpacing = style.lineSpacing(for: font)
            paragraph.alignment = .center
            return [
                .font: font,
                .foregroundColor: style.scheme.cueColor,
                .kern: size * cueTracking,
                .paragraphStyle: paragraph,
            ]
        }
    }

    /// The system font at `weight`, italic (SF has an italic for every weight). Upright if no italic resolves.
    static func italicSystemFont(ofSize size: Double, weight: PlatformFont.Weight) -> PlatformFont {
        let upright = PlatformFont.systemFont(ofSize: size, weight: weight)
        #if canImport(UIKit)
        let traits = upright.fontDescriptor.symbolicTraits.union(.traitItalic)
        guard let descriptor = upright.fontDescriptor.withSymbolicTraits(traits) else { return upright }
        return UIFont(descriptor: descriptor, size: size)
        #else
        let traits = upright.fontDescriptor.symbolicTraits.union(.italic)
        let descriptor = upright.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: size) ?? upright
        #endif
    }
}

/// Everything about the canvas that decides how the text is drawn and laid out, in points.
struct PrompterTextStyle: Equatable, Sendable {
    var fontSize: Double
    var weight: PrompterSettings.Weight
    var lineSpacingMultiple: Double
    var sideInset: Double
    var readingLineY: Double
    var scheme: PrompterSettings.Scheme
    var canvasSize: CGSize

    /// - Parameters:
    ///   - fontSize: the size in settings units (iPhone points), e.g. the live size during a pinch; nil uses the settings.
    ///   - isPad: scales the font to the canvas, see `fontScale`.
    init(settings: PrompterSettings, canvasSize: CGSize, isPad: Bool, fontSize: Double? = nil) {
        let size = min(max(fontSize ?? settings.fontSize, PrompterSettings.fontSizeRange.lowerBound),
                       PrompterSettings.fontSizeRange.upperBound)
        self.fontSize = size * Self.fontScale(canvasSize: canvasSize, isPad: isPad)
        weight = settings.fontWeight
        lineSpacingMultiple = settings.lineSpacing
        sideInset = settings.sideMargin * canvasSize.width
        readingLineY = settings.readingLinePosition * canvasSize.height
        scheme = settings.scheme
        self.canvasSize = canvasSize
    }

    /// 1 on iPhone. On iPad: `min(shortSide / 402, longSide / 874)`, never below 1, so the canvas holds as many lines
    /// and as many words per line as the iPhone 17 Pro in landscape, whichever is tighter. (Scaling by the short side
    /// alone gave 149 pt on an 11-inch iPad, which breaks words mid-word in portrait, and iPadOS windowing doesn't let
    /// the app force landscape.) Landscape and portrait get the same size.
    static func fontScale(canvasSize: CGSize, isPad: Bool) -> Double {
        guard isPad else { return 1 }
        let shortSide = min(canvasSize.width, canvasSize.height)
        let longSide = max(canvasSize.width, canvasSize.height)
        guard shortSide.isFinite, longSide.isFinite, shortSide > 0 else { return 1 }
        let reference = PrompterText.referenceSize
        return max(min(shortSide / reference.height, longSide / reference.width), 1)
    }

    /// A canvas whose short side is at least this many points is a large canvas (see `scalesToCanvas`). No iPhone screen
    /// comes near it (the biggest is 440 pt across); the open iPhone Duo (951 × 669, either way up) is over it, folded
    /// (466 × 678) it is under.
    static let largeCanvasShortSide = 600.0

    /// Whether the font takes the canvas scaling (`fontScale`): on an iPad, as always, and on any large canvas, which is
    /// how the open iPhone Duo gets it while its idiom stays phone. Decided from the canvas, never from the device's
    /// orientation, so both prompter views (the overlays and the text) agree on every size a fold passes through.
    static func scalesToCanvas(isPad: Bool, canvasSize: CGSize) -> Bool {
        if isPad { return true }
        let shortSide = min(canvasSize.width, canvasSize.height)
        return shortSide.isFinite && shortSide >= largeCanvasShortSide
    }

    var fontWeight: PlatformFont.Weight {
        switch weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        }
    }

    /// The extra space below each line: (multiple − 1) × the font's line height.
    func lineSpacing(for font: PlatformFont) -> Double {
        max(lineSpacingMultiple - 1, 0) * font.prompterLineHeight
    }

    var paragraphSpacing: Double { fontSize * 0.5 }

    /// The width the text wraps to: the canvas less a side inset on each side (never negative).
    var textWidth: Double {
        max(canvasSize.width - 2 * sideInset, 0)
    }

    #if canImport(UIKit)
    /// The text container insets that put text offset 0 at the reading line, so `contentOffset.y` equals the engine's
    /// position: top = reading line, bottom = height − reading line. (AppKit's `NSTextView.textContainerInset` is one
    /// symmetric size, so the Mac places its text container with `readingLineY` / `sideInset` itself.)
    var textContainerInset: UIEdgeInsets {
        UIEdgeInsets(
            top: readingLineY,
            left: sideInset,
            bottom: max(canvasSize.height - readingLineY, 0),
            right: sideInset
        )
    }
    #endif

    /// True when `other` lays the text out differently (anything but the colours and the reading line).
    func needsRelayout(comparedTo other: PrompterTextStyle) -> Bool {
        fontSize != other.fontSize || weight != other.weight || lineSpacingMultiple != other.lineSpacingMultiple
            || sideInset != other.sideInset || canvasSize.width != other.canvasSize.width
    }

    /// True when the text view needs a new attributed string to show this style after `applied` (nil: nothing shown
    /// yet): a different layout or different colours. The text view lays the whole document out again every time it
    /// replaces the string, colour-only changes included.
    func needsNewText(comparedTo applied: PrompterTextStyle?) -> Bool {
        guard let applied else { return true }
        return needsRelayout(comparedTo: applied) || scheme != applied.scheme
    }
}

extension PrompterSettings.Scheme {
    var foregroundColor: PlatformColor {
        switch self {
        case .whiteOnBlack: .white
        case .yellowOnBlack: Self.rgb(1, 0xD6 / 255, 0x0A / 255)   // #FFD60A
        case .blackOnWhite: .black
        }
    }

    var backgroundColor: PlatformColor {
        self == .blackOnWhite ? .white : .black
    }

    /// Pause cues: the app's amber on black, a deeper orange next to yellow text, a dark amber on white.
    var cueColor: PlatformColor {
        switch self {
        case .whiteOnBlack: Self.rgb(1, 0xB0 / 255, 0x20 / 255)          // #FFB020, the accent colour
        case .yellowOnBlack: Self.rgb(1, 0x8C / 255, 0)                  // #FF8C00
        case .blackOnWhite: Self.rgb(0xA8 / 255, 0x5A / 255, 0)          // #A85A00
        }
    }

    /// An opaque sRGB colour on either platform.
    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> PlatformColor {
        #if canImport(UIKit)
        UIColor(red: red, green: green, blue: blue, alpha: 1)
        #else
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        #endif
    }

    #if canImport(UIKit)
    // The names the iOS app (and its tests) have always used.
    var foregroundUIColor: UIColor { foregroundColor }
    var backgroundUIColor: UIColor { backgroundColor }
    var cueUIColor: UIColor { cueColor }
    #endif
}

/// The mirror/flip/rotation of the whole canvas as one exact affine transform about the canvas centre.
///
/// Built from exact 0/±1 matrices rather than `rotationEffect`, whose 90° rotation (cos π/2 ≈ 6e-17) isn't quite
/// axis-aligned, so Core Animation resampled the text and it came out blurry.
enum PrompterCanvasTransform {
    /// Rotation first, then the mirror/flip in screen space. For 90°/270° the canvas is `canvasSize` with width and
    /// height already swapped relative to the screen, so the rotated canvas covers the screen exactly.
    static func make(
        rotation: PrompterSettings.Rotation,
        mirror: Bool,
        flip: Bool,
        canvasSize: CGSize
    ) -> CGAffineTransform {
        let rotate = switch rotation {
        case .none: CGAffineTransform.identity
        case .quarter: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
        case .half: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        case .threeQuarters: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)
        }
        let scale = CGAffineTransform(scaleX: mirror ? -1 : 1, y: flip ? -1 : 1)
        let halfWidth = canvasSize.width / 2
        let halfHeight = canvasSize.height / 2
        return CGAffineTransform(translationX: -halfWidth, y: -halfHeight)
            .concatenating(rotate)
            .concatenating(scale)
            .concatenating(CGAffineTransform(translationX: halfWidth, y: halfHeight))
    }

    /// True for 90° and 270°, where the canvas is the screen with width and height swapped.
    static func isSideways(_ rotation: PrompterSettings.Rotation) -> Bool {
        rotation == .quarter || rotation == .threeQuarters
    }
}
