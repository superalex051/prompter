import AppKit
import QuartzCore

/// PNGs of the output and the Presenter view, drawn by the app itself (debug `-snapshot` with `-route prompter`; no
/// screen-recording permission needed, nothing else on screen captured).
///
/// The canvases are Core Animation layer trees, rendered with `CALayer.render(in:)`, which applies the canvas transform
/// (mirror, flip, rotation, preview scale) just as the screen does. The Presenter view's SwiftUI is drawn with
/// `cacheDisplay` and the live preview rendered on top where it sits.
@MainActor
enum PresenterSnapshotter {
    /// Writes `<prefix>-output.png` and `<prefix>-presenter.png`. Returns the files written.
    @discardableResult
    static func write(_ controller: PresentingController, to directory: URL, prefix: String) -> [URL] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        if let view = controller.outputView, let data = pngOfLayers(view) {
            let url = directory.appending(path: "\(prefix)-output.png")
            if (try? data.write(to: url)) != nil { written.append(url) }
        }
        if let window = controller.presenterWindow, let data = pngOfPresenter(window) {
            let url = directory.appending(path: "\(prefix)-presenter.png")
            if (try? data.write(to: url)) != nil { written.append(url) }
        }
        return written
    }

    /// A layer-hosting view's layer tree at its window's backing scale.
    static func pngOfLayers(_ view: NSView) -> Data? {
        guard let layer = view.layer, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let scale = view.window?.backingScaleFactor ?? 2
        let width = Int((view.bounds.width * scale).rounded())
        let height = Int((view.bounds.height * scale).rounded())
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// The Presenter window's content, with every live preview canvas rendered into its place.
    static func pngOfPresenter(_ window: NSWindow) -> Data? {
        guard let content = window.contentView, content.bounds.width > 0,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
        else { return nil }
        content.cacheDisplay(in: content.bounds, to: rep)
        if let graphics = NSGraphicsContext(bitmapImageRep: rep) {
            let context = graphics.cgContext
            let scale = CGFloat(rep.pixelsWide) / content.bounds.width
            for canvas in descendants(of: content).compactMap({ $0 as? PrompterCanvasView }) {
                guard let layer = canvas.layer, !canvas.isHiddenOrHasHiddenAncestor else { continue }
                // Window coordinates run up from the bottom left, like the bitmap's.
                let frame = canvas.convert(canvas.bounds, to: nil)
                let contentOrigin = content.convert(content.bounds, to: nil).origin
                context.saveGState()
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: frame.minX - contentOrigin.x, y: frame.minY - contentOrigin.y)
                context.clip(to: CGRect(origin: .zero, size: frame.size))
                layer.render(in: context)
                context.restoreGState()
            }
            context.flush()
        }
        return rep.representation(using: .png, properties: [:])
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
