import AppKit
import QuartzCore

/// The script's text laid out once by TextKit 2 (`PrompterLayoutExtractor.TextKitStack`, exactly the layout the scroll
/// engine gets) and drawn on demand, a horizontal band at a time, into the canvas's text tiles.
///
/// Coordinates are the text container's: x = 0 at the left text margin, y = 0 at the top of the first line, growing
/// down, as in `PrompterLayout`.
@MainActor
final class CanvasTextRenderer {
    let document: PrompterDocument
    let style: PrompterTextStyle
    /// What the scroll engine needs (lines, holds, content height).
    let layout: PrompterLayout

    private let stack: PrompterLayoutExtractor.TextKitStack
    /// Every layout fragment (one per paragraph) with the rectangle its glyphs may draw in, in document order.
    private var fragments: [(fragment: NSTextLayoutFragment, origin: CGPoint, drawRect: CGRect)] = []

    init(document: PrompterDocument, style: PrompterTextStyle) {
        self.document = document
        self.style = style
        stack = PrompterLayoutExtractor.TextKitStack(
            attributedString: PrompterText.attributedString(document, style: style),
            width: style.textWidth
        )
        // Lays the whole document out (so nothing below is an estimate) and reads the lines for the engine.
        layout = PrompterLayoutExtractor.layout(of: stack.layoutManager, document: document)
        let manager = stack.layoutManager
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            let surface = fragment.renderingSurfaceBounds.offsetBy(dx: frame.minX, dy: frame.minY)
            self.fragments.append((fragment, frame.origin, surface.union(frame)))
            return true
        }
    }

    /// The height of all the text (0 when empty).
    var contentHeight: Double { layout.contentHeight }

    /// Draws every fragment that reaches into `rect` (container coordinates). `context` must already map container
    /// coordinates (y down) to the target, and `NSGraphicsContext.current` be a flipped context on it.
    func draw(_ rect: CGRect, in context: CGContext) {
        // Fragments are in y order; skip the ones wholly above, stop after the ones wholly below.
        var low = 0
        var high = fragments.count
        while low < high {
            let mid = (low + high) / 2
            if fragments[mid].drawRect.maxY < rect.minY { low = mid + 1 } else { high = mid }
        }
        // A tall glyph of an earlier fragment can reach down into the band: back up a little.
        var index = max(low - 1, 0)
        while index < fragments.count {
            let entry = fragments[index]
            if entry.drawRect.minY > rect.maxY, entry.origin.y > rect.maxY { break }
            if entry.drawRect.intersects(rect) {
                entry.fragment.draw(at: entry.origin, in: context)
            }
            index += 1
        }
    }
}

/// One horizontal band of the text, drawn once when it comes near the screen and then only moved.
final class TextTileLayer: CALayer {
    /// Band `index` starts at container y `index × tileHeight` and runs for the layer's height.
    var index = 0
    var tileHeight: CGFloat = 0
    /// The canvas's side inset: container x = 0 sits this far in from the tile's left edge.
    var leftInset: CGFloat = 0
    var fillColor: CGColor = .black
    weak var renderer: CanvasTextRenderer?

    override init() {
        super.init()
        isOpaque = true
        needsDisplayOnBoundsChange = true
        actions = Self.noActions
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? TextTileLayer {
            index = other.index
            tileHeight = other.tileHeight
            leftInset = other.leftInset
            fillColor = other.fillColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Core Animation's implicit animations, off: tiles appear and move instantly.
    nonisolated(unsafe) static let noActions: [String: any CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "frame": NSNull(),
        "hidden": NSNull(), "sublayers": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(),
        "contentsScale": NSNull(), "backgroundColor": NSNull(), "transform": NSNull(), "opacity": NSNull(),
    ]

    override func draw(in context: CGContext) {
        context.setFillColor(fillColor)
        context.fill(bounds)
        let index = index
        let tileHeight = tileHeight
        let leftInset = leftInset
        let size = bounds.size
        let renderer = renderer
        // Core Animation draws on the main thread here (no asynchronous drawing is turned on).
        nonisolated(unsafe) let context = context
        MainActor.assumeIsolated {
            guard let renderer else { return }
            context.saveGState()
            // Layer coordinates run up; TextKit draws with y down from the band's top.
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: leftInset, y: -CGFloat(index) * tileHeight)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let band = CGRect(x: -leftInset, y: CGFloat(index) * tileHeight, width: size.width, height: size.height)
            renderer.draw(band, in: context)
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
        }
    }
}

/// A single line of text drawn centred on its glyphs (the countdown digit), so it sits in the middle optically.
final class CenteredTextLayer: CALayer {
    var text = "" { didSet { if text != oldValue { setNeedsDisplay() } } }
    var font: NSFont = .systemFont(ofSize: 100) { didSet { setNeedsDisplay() } }
    var textColor: NSColor = .white { didSet { setNeedsDisplay() } }

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
        actions = TextTileLayer.noActions
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? CenteredTextLayer {
            text = other.text
            font = other.font
            textColor = other.textColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func draw(in context: CGContext) {
        guard !text.isEmpty else { return }
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: textColor])
        let line = CTLineCreateWithAttributedString(attributed)
        let glyphs = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let advance = CTLineGetTypographicBounds(line, nil, nil, nil)
        guard glyphs.width > 0, glyphs.height > 0 else { return }
        // Centre the glyphs' ink horizontally by their advance (stable as digits change) and vertically by their ink.
        let x = (bounds.width - advance) / 2
        let y = (bounds.height - glyphs.height) / 2 - glyphs.minY
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
