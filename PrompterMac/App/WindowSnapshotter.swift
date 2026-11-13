import AppKit

/// Writes PNGs of the app's own windows (debug `-snapshot <dir>`), rendered by the app itself: nothing outside Prompter's
/// windows ends up in the image, and no screen-recording permission is needed (the window server's capture APIs need
/// it even for an app's own windows, and return a blank image without it).
///
/// The views draw themselves with `cacheDisplay`, which can't render Liquid Glass or vibrancy: an `NSGlassEffectView`
/// (the floating sidebar, toolbar platters) comes out transparent, and the vibrant content inside it draws as a black
/// alpha mask. So each glass view is drawn as a flat dark panel of its shape, its content is drawn on top as a white
/// mask (titles and secondary text alike), and a selected sidebar row gets a plain grey highlight. Close to the screen,
/// minus the glass sheen and the secondary text's dimming; good enough to check layout and content.
enum WindowSnapshotter {
    /// The flat stand-in for dark Liquid Glass.
    static let glassFill = NSColor(white: 0.17, alpha: 1)
    /// The flat stand-in for a selected row's highlight in a glass sidebar.
    static let selectionFill = NSColor(white: 0.32, alpha: 1)

    /// Waits (up to `timeout`) for the app's first visible window, gives SwiftUI `settle` seconds to lay it out, then
    /// writes the snapshots.
    @MainActor @discardableResult
    static func snapshotWhenReady(to directory: URL, timeout: Double = 15, settle: Double = 1.5) async -> [URL] {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !NSApp.windows.contains(where: \.isVisible), Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .seconds(settle))
        return writeSnapshots(of: NSApp.windows, to: directory)
    }

    /// One PNG per visible window, named `window-<n>.png` in on-screen order (front first). Returns the files written.
    @MainActor @discardableResult
    static func writeSnapshots(of windows: [NSWindow], to directory: URL) -> [URL] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        let visible = windows.filter { $0.isVisible && $0.contentView != nil }
            .sorted { $0.orderedIndex < $1.orderedIndex }
        for (index, window) in visible.enumerated() {
            guard let data = pngData(of: window) else { continue }
            let url = directory.appending(path: "window-\(index + 1).png")
            if (try? data.write(to: url)) != nil { written.append(url) }
        }
        return written
    }

    /// The window's frame view (content plus title bar) at the screen's backing scale, glass drawn as described above.
    @MainActor
    static func pngData(of window: NSWindow) -> Data? {
        guard let frameView = window.contentView?.superview ?? window.contentView else { return nil }
        let bounds = frameView.bounds
        guard bounds.width > 0, bounds.height > 0, let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        frameView.cacheDisplay(in: bounds, to: rep)

        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            for glass in glassViews(in: frameView) where !glass.isHiddenOrHasHiddenAncestor {
                drawFlattened(glass, in: frameView)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Private

    /// Every glass view under `view`, outermost first (so nested glass draws on top of its container).
    @MainActor
    private static func glassViews(in view: NSView) -> [NSGlassEffectView] {
        var found: [NSGlassEffectView] = []
        for subview in view.subviews {
            if let glass = subview as? NSGlassEffectView { found.append(glass) }
            found += glassViews(in: subview)
        }
        return found
    }

    /// The glass's shape filled flat, selected rows highlighted, then its content view drawn on top as a white mask.
    @MainActor
    private static func drawFlattened(_ glass: NSGlassEffectView, in frameView: NSView) {
        let rect = glass.convert(glass.bounds, to: frameView)
        guard rect.width > 0, rect.height > 0 else { return }
        let radius = min(glass.cornerRadius, rect.width / 2, rect.height / 2)
        glassFill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        guard let content = glass.contentView, content.bounds.width > 0, content.bounds.height > 0 else { return }
        // A selected row's highlight is a vibrant effect view, which caches as an opaque black box: hide it while
        // caching and draw a plain one instead.
        let selectedRows = descendants(of: content).compactMap { $0 as? NSTableRowView }.filter(\.isSelected)
        var hidden: [NSView] = []
        for row in selectedRows {
            for highlight in row.subviews where highlight is NSVisualEffectView && !highlight.isHidden {
                highlight.isHidden = true
                hidden.append(highlight)
            }
            let highlightRect = row.convert(row.bounds.insetBy(dx: 10, dy: 0), to: frameView)
            selectionFill.setFill()
            NSBezierPath(roundedRect: highlightRect, xRadius: 8, yRadius: 8).fill()
        }
        defer { hidden.forEach { $0.isHidden = false } }

        drawWhitened(content, rect: content.bounds, in: frameView)
        // Caching the content view skips what scroll views inside it show (the sidebar's rows): draw each one's
        // visible part from its document view.
        for scrollView in descendants(of: content).compactMap({ $0 as? NSScrollView }) {
            guard let document = scrollView.documentView else { continue }
            drawWhitened(document, rect: scrollView.contentView.documentVisibleRect, in: frameView)
        }
    }

    @MainActor
    private static func drawWhitened(_ view: NSView, rect: NSRect, in frameView: NSView) {
        guard rect.width > 0, rect.height > 0, let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return }
        view.cacheDisplay(in: rect, to: rep)
        whiten(rep)
        rep.draw(in: view.convert(rect, to: frameView), from: .zero, operation: .sourceOver,
                 fraction: 1, respectFlipped: true, hints: nil)
    }

    @MainActor
    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// Every pixel becomes white at its own alpha (the vibrant content caches as a black mask).
    private static func whiten(_ rep: NSBitmapImageRep) {
        guard let data = rep.bitmapData, rep.bitsPerSample == 8, rep.samplesPerPixel == 4, !rep.isPlanar else { return }
        let alphaFirst = rep.bitmapFormat.contains(.alphaFirst)
        let premultiplied = !rep.bitmapFormat.contains(.alphaNonpremultiplied)
        let alphaIndex = alphaFirst ? 0 : 3
        let colourIndices = alphaFirst ? [1, 2, 3] : [0, 1, 2]
        for y in 0..<rep.pixelsHigh {
            let row = data + y * rep.bytesPerRow
            for x in 0..<rep.pixelsWide {
                let pixel = row + x * 4
                let value = premultiplied ? pixel[alphaIndex] : 255
                for index in colourIndices { pixel[index] = value }
            }
        }
    }
}
