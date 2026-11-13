import AppKit
import QuartzCore

/// The prompter canvas as a Core Animation layer tree: the scrolling text (in tiles), the dimming above the reading line
/// with its amber markers, the HUD strip and the big countdown. Everything is inside `root`, so one transform on it
/// mirrors, flips, rotates or scales the whole canvas (output and preview alike), with no AppKit view geometry involved.
///
/// `root` is `canvasSize` in points, in Core Animation's upward coordinates; the text math is done top-down (as in
/// `PrompterLayout`) and converted here.
@MainActor
final class PrompterCanvasLayers {
    let root = CALayer()

    /// Height of one text tile in points.
    static let tileHeight: CGFloat = 384
    /// How far each tile extends past its band at the bottom.
    static let tileOverlap: CGFloat = 8

    private let textContent = CALayer()
    private let dimming = CALayer()
    private let dimSolid = CALayer()
    private let dimFeather = CAGradientLayer()
    private let leftMarker = CAShapeLayer()
    private let rightMarker = CAShapeLayer()
    private let hud = CALayer()
    private let hudFeather = CAGradientLayer()
    private let hudSolid = CALayer()
    private let hudTime = CATextLayer()
    private let hudWord = CATextLayer()
    private let hudSpeed = CATextLayer()
    private let hudTrack = CALayer()
    private let hudFill = CALayer()
    private let countdown = CALayer()
    private let countdownDigit = CenteredTextLayer()
    private let emptyMessage = CATextLayer()

    private var renderer: CanvasTextRenderer?
    /// The style applied last (the renderer's, except for the reading line and the dimming).
    private var style: PrompterTextStyle?
    private var tiles: [Int: TextTileLayer] = [:]
    private var canvasSize: CGSize = .zero
    private var settings = PrompterSettings()
    private var contentsScale: CGFloat = 2
    private var shownPosition: Double = 0
    private var hudFontSize: CGFloat = 20
    /// What the HUD and the countdown show now, so a frame only touches what changed.
    private var shownStatus: Status?

    init() {
        for layer in [root, textContent, dimming, dimSolid, dimFeather, leftMarker, rightMarker, hud, hudFeather, hudSolid,
                      hudTime, hudWord, hudSpeed, hudTrack, hudFill, countdown, countdownDigit, emptyMessage] as [CALayer] {
            layer.actions = TextTileLayer.noActions
        }
        root.masksToBounds = true
        root.backgroundColor = .black
        textContent.anchorPoint = .zero
        textContent.bounds = .zero

        dimming.addSublayer(dimSolid)
        dimming.addSublayer(dimFeather)
        // Unit coordinates run up on the Mac: transparent at the bottom (the reading line), opaque above.
        dimFeather.startPoint = CGPoint(x: 0.5, y: 0)
        dimFeather.endPoint = CGPoint(x: 0.5, y: 1)

        hudFeather.startPoint = CGPoint(x: 0.5, y: 0)
        hudFeather.endPoint = CGPoint(x: 0.5, y: 1)
        for text in [hudTime, hudWord, hudSpeed, emptyMessage] {
            text.truncationMode = .end
            text.isWrapped = false
        }
        hudTime.alignmentMode = .left
        hudWord.alignmentMode = .center
        hudSpeed.alignmentMode = .right
        emptyMessage.alignmentMode = .center
        emptyMessage.isWrapped = true
        for layer in [hudFeather, hudSolid, hudTrack, hudFill, hudTime, hudSpeed, hudWord] as [CALayer] {
            hud.addSublayer(layer)
        }
        countdown.addSublayer(countdownDigit)
        countdown.opacity = 0

        for layer in [textContent, dimming, leftMarker, rightMarker, emptyMessage, hud, countdown] {
            root.addSublayer(layer)
        }
    }

    /// The text's height, for the engine and the tests.
    var contentHeight: Double { renderer?.contentHeight ?? 0 }

    // MARK: Configuration

    /// Applies the document, settings and size. Returns the new layout when the text was laid out again (the output then
    /// hands it to the engine); nil when only colours, the reading line or the dimming changed, or nothing did.
    @discardableResult
    func configure(
        document: PrompterDocument,
        settings: PrompterSettings,
        canvasSize: CGSize,
        contentsScale: CGFloat
    ) -> PrompterLayout? {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let style = PrompterTextStyle(settings: settings, canvasSize: canvasSize, isPad: true)
        let scaleChanged = abs(contentsScale - self.contentsScale) > 0.001
        self.settings = settings
        self.canvasSize = canvasSize
        self.contentsScale = contentsScale

        var newLayout: PrompterLayout?
        // Colours and the reading line don't change the layout; the tiles are redrawn for a new colour scheme.
        if renderer == nil || renderer?.document != document || style.needsNewText(comparedTo: renderer?.style) {
            let renderer = CanvasTextRenderer(document: document, style: style)
            self.renderer = renderer
            newLayout = renderer.layout
            removeAllTiles()
        }
        self.style = style
        if scaleChanged {
            for tile in tiles.values {
                tile.contentsScale = contentsScale
                tile.setNeedsDisplay()
            }
        }

        let background = settings.scheme.backgroundColor.cgColor
        root.bounds = CGRect(origin: .zero, size: canvasSize)
        root.backgroundColor = background
        layoutDimming(style: style)
        layoutHUD(style: style)
        layoutCountdown()
        layoutEmptyMessage(isEmpty: document.isEmpty)
        shownStatus = nil
        show(position: shownPosition)
        return newLayout
    }

    // MARK: Per frame

    /// Puts `position` (the engine's, already pixel-aligned) at the reading line and makes sure the tiles around the
    /// screen exist.
    func show(position: Double) {
        shownPosition = position
        guard let renderer, let style, canvasSize.height > 0 else { return }
        let tileHeight = Self.tileHeight
        // The container's y = 0 sits at the reading line when position is 0; in upward canvas coordinates:
        // On a whole device pixel (the reading line can sit at a fractional point), so the tiles never resample.
        let offset = CanvasGeometry.pixelAligned(canvasSize.height - style.readingLineY + position,
                                                 pixelsPerPoint: contentsScale)
        textContent.position = CGPoint(x: 0, y: offset)

        let contentHeight = renderer.contentHeight
        guard contentHeight > 0 else {
            removeAllTiles()
            return
        }
        let top = position - style.readingLineY
        let low = top - tileHeight / 2
        let high = top + canvasSize.height + canvasSize.height / 2
        let lastIndex = Int((max(contentHeight - 1, 0) / tileHeight).rounded(.down))
        let first = max(Int((low / tileHeight).rounded(.down)), 0)
        let last = min(Int((high / tileHeight).rounded(.down)), lastIndex)
        guard first <= last else {
            removeAllTiles()
            return
        }
        for (index, tile) in tiles where index < first - 1 || index > last + 1 {
            tile.removeFromSuperlayer()
            tiles[index] = nil
        }
        for index in first...last where tiles[index] == nil {
            let tile = TextTileLayer()
            tile.index = index
            tile.tileHeight = tileHeight
            tile.leftInset = style.sideInset
            tile.fillColor = settings.scheme.backgroundColor.cgColor
            tile.renderer = renderer
            tile.contentsScale = contentsScale
            tile.anchorPoint = .zero
            // Each tile reaches a little into the next (same pixels there), so no seam shows between them.
            let overlap = Self.tileOverlap
            tile.frame = CGRect(x: 0, y: -CGFloat(index + 1) * tileHeight - overlap, width: canvasSize.width,
                                height: tileHeight + overlap)
            tile.setNeedsDisplay()
            textContent.addSublayer(tile)
            tiles[index] = tile
        }
    }

    /// The HUD's and the countdown's values. Cheap when nothing changed.
    struct Status: Equatable {
        var state: PlaybackState
        var remaining: String
        var speed: String
        var word: String?
        var progress: Double
    }

    func update(status: Status) {
        guard status != shownStatus else { return }
        let previous = shownStatus
        shownStatus = status
        let foreground = settings.scheme.foregroundColor
        let font = Self.hudFont(size: hudFontSize)
        func attributed(_ string: String) -> NSAttributedString {
            NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: foreground.withAlphaComponent(0.8)])
        }
        // After a reconfigure (`shownStatus` nil) everything is set again.
        if previous == nil || previous?.remaining != status.remaining { hudTime.string = attributed(status.remaining) }
        if previous == nil || previous?.speed != status.speed { hudSpeed.string = attributed(status.speed) }
        if previous == nil || previous?.word != status.word { hudWord.string = status.word.map(attributed) }
        if previous == nil || previous?.progress != status.progress { layoutProgress(status.progress) }

        if case .countdown(let digit) = status.state {
            countdownDigit.text = "\(digit)"
            setCountdownVisible(true)
        } else {
            setCountdownVisible(false)
        }
    }

    // MARK: Layout

    private func layoutDimming(style: PrompterTextStyle) {
        let width = canvasSize.width
        let height = canvasSize.height
        let readingLine = min(max(style.readingLineY, 0), height)
        let fontScale = PrompterTextStyle.fontScale(canvasSize: canvasSize, isPad: true)
        let feather = min(24 * fontScale, readingLine)
        let background = settings.scheme.backgroundColor
        dimming.frame = root.bounds
        dimming.opacity = Float(1 - min(max(settings.dimmedOpacity, 0), 1))
        dimSolid.backgroundColor = background.cgColor
        dimSolid.frame = CGRect(x: 0, y: height - readingLine + feather, width: width, height: max(readingLine - feather, 0))
        dimFeather.colors = [background.withAlphaComponent(0).cgColor, background.cgColor]
        dimFeather.frame = CGRect(x: 0, y: height - readingLine, width: width, height: feather)

        // Amber chevrons in the side margins, pointing at the reading line.
        let size = min(max(style.sideInset * 0.4, 12 * fontScale), 22 * fontScale)
        let center = max(style.sideInset / 2, size / 2 + 4)
        let y = height - readingLine
        for (marker, pointsRight) in [(leftMarker, true), (rightMarker, false)] {
            let markerWidth = size * 0.8
            let path = CGMutablePath()
            if pointsRight {
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: markerWidth, y: size / 2))
                path.addLine(to: CGPoint(x: 0, y: size))
            } else {
                path.move(to: CGPoint(x: markerWidth, y: 0))
                path.addLine(to: CGPoint(x: 0, y: size / 2))
                path.addLine(to: CGPoint(x: markerWidth, y: size))
            }
            path.closeSubpath()
            marker.path = path
            marker.fillColor = settings.scheme.cueColor.cgColor
            marker.bounds = CGRect(x: 0, y: 0, width: markerWidth, height: size)
            marker.position = CGPoint(x: pointsRight ? center : width - center, y: y)
        }
    }

    private func layoutHUD(style: PrompterTextStyle) {
        let width = canvasSize.width
        let shortSide = min(canvasSize.width, canvasSize.height)
        hudFontSize = min(max(shortSide * 0.028, 16), 40)
        let unit = hudFontSize / 20
        let inset = max(style.sideInset, 44 * unit)
        let bottomPadding = 10 * unit
        let barHeight = max(3 * unit, 3)
        let spacing = 6 * unit
        let labelHeight = ceil(hudFontSize * 1.3)
        let feather = 16 * unit
        let topPadding = 8 * unit
        let height = bottomPadding + barHeight + spacing + labelHeight + topPadding + feather
        let background = settings.scheme.backgroundColor
        let foreground = settings.scheme.foregroundColor

        hud.frame = CGRect(x: 0, y: 0, width: width, height: height)
        hudSolid.backgroundColor = background.cgColor
        hudSolid.frame = CGRect(x: 0, y: 0, width: width, height: height - feather)
        hudFeather.colors = [background.cgColor, background.withAlphaComponent(0).cgColor]
        hudFeather.frame = CGRect(x: 0, y: height - feather, width: width, height: feather)

        let labelY = bottomPadding + barHeight + spacing
        let labelWidth = max(width - 2 * inset, 0)
        for text in [hudTime, hudWord, hudSpeed] {
            text.contentsScale = contentsScale
            text.frame = CGRect(x: inset, y: labelY, width: labelWidth, height: labelHeight)
        }
        hudTrack.backgroundColor = foreground.withAlphaComponent(0.2).cgColor
        hudTrack.cornerRadius = barHeight / 2
        hudTrack.frame = CGRect(x: inset, y: bottomPadding, width: labelWidth, height: barHeight)
        hudFill.backgroundColor = settings.scheme.cueColor.cgColor
        hudFill.cornerRadius = barHeight / 2
        layoutProgress(shownStatus?.progress ?? 0)
    }

    private func layoutProgress(_ progress: Double) {
        let track = hudTrack.frame
        let fraction = progress.isFinite ? min(max(progress, 0), 1) : 0
        hudFill.frame = CGRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height)
    }

    private func layoutCountdown() {
        countdown.frame = root.bounds
        countdown.backgroundColor = settings.scheme.backgroundColor.withAlphaComponent(0.75).cgColor
        countdownDigit.frame = root.bounds
        countdownDigit.contentsScale = contentsScale
        // As tall as 80% of the canvas, but never wider than it (a sideways canvas is narrow).
        let size = min(canvasSize.height * 0.8, canvasSize.width * 0.9 / 0.62)
        countdownDigit.font = Self.roundedFont(size: size, weight: .heavy)
        countdownDigit.textColor = settings.scheme.foregroundColor
    }

    private func layoutEmptyMessage(isEmpty: Bool) {
        emptyMessage.isHidden = !isEmpty
        guard isEmpty else { return }
        let size = min(canvasSize.width, canvasSize.height) * 0.05
        let foreground = settings.scheme.foregroundColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let message = NSMutableAttributedString(string: "This script is empty\n", attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .heavy), .foregroundColor: foreground, .paragraphStyle: paragraph,
        ])
        message.append(NSAttributedString(string: "Add some text in the editor, then come back.", attributes: [
            .font: NSFont.systemFont(ofSize: size * 0.6, weight: .regular),
            .foregroundColor: foreground.withAlphaComponent(0.7), .paragraphStyle: paragraph,
        ]))
        emptyMessage.string = message
        emptyMessage.contentsScale = contentsScale
        let height = size * 3
        emptyMessage.frame = CGRect(x: canvasSize.width * 0.1, y: (canvasSize.height - height) / 2,
                                    width: canvasSize.width * 0.8, height: height)
    }

    private func setCountdownVisible(_ visible: Bool) {
        let target: Float = visible ? 1 : 0
        guard countdown.opacity != target else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = countdown.presentation()?.opacity ?? countdown.opacity
        fade.toValue = target
        fade.duration = 0.2
        countdown.opacity = target
        countdown.add(fade, forKey: "fade")
    }

    private func removeAllTiles() {
        for tile in tiles.values { tile.removeFromSuperlayer() }
        tiles.removeAll()
    }

    // MARK: Fonts

    static func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: rounded, size: size) ?? base
    }

    static func hudFont(size: CGFloat) -> NSFont {
        roundedFont(size: size, weight: .semibold)
    }
}
