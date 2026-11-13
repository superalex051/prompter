import AppKit
import QuartzCore

/// Shows the prompter canvas (`PrompterCanvasLayers`) and moves its text every frame with the view's display link
/// (`NSView.displayLink`, so it runs at the refresh rate of the screen the view is on, ProMotion included).
///
/// - `.output`: the teleprompter screen. The canvas fills the view, mirrored, flipped and rotated per the settings, and
///   it hands the engine its text layout.
/// - `.preview`: the Presenter view's live preview. The same canvas at the output's size, scaled to fit, readable or
///   "as on the teleprompter".
///
/// A layer-hosting view: AppKit leaves the layer tree alone, so the canvas transform is exactly the one set here.
final class PrompterCanvasView: NSView {
    enum Role: Equatable, Sendable { case output, preview }

    let role: Role
    let session: PresenterSession
    /// The output on a screen of its own hides the mouse pointer over it.
    var hidesCursor = false {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    private let canvas = PrompterCanvasLayers()
    private var link: CADisplayLink?
    /// Kept here: the display link may not keep its target alive. (It holds the view weakly, so no cycle.)
    private var linkProxy: CanvasLinkProxy?
    private var previousFrameTime: CFTimeInterval?
    private var smoother = DisplayPositionSmoother()
    /// Points of the canvas per point of this view, and device pixels per canvas point.
    private var canvasScale: CGFloat = 1
    private var pixelsPerCanvasPoint: CGFloat = 2

    init(session: PresenterSession, role: Role) {
        self.session = session
        self.role = role
        super.init(frame: .zero)
        let host = CALayer()
        host.backgroundColor = NSColor.black.cgColor
        host.actions = TextTileLayer.noActions
        layer = host
        wantsLayer = true
        host.addSublayer(canvas.root)
        session.register(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The layer tree, for snapshots.
    var canvasRootLayer: CALayer { canvas.root }

    // MARK: Layout

    override func layout() {
        super.layout()
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startDisplayLink()
            refresh()
        } else {
            stopDisplayLink()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        refresh()
    }

    /// Applies the session's settings, script and output size, and shows the engine's position. Called on layout and by
    /// the session whenever something changed.
    func refresh() {
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
        let settings = session.settings
        let backing = window?.backingScaleFactor ?? 2
        let canvasSize: CGSize
        let transform: CGAffineTransform
        switch role {
        case .output:
            canvasSize = CanvasGeometry.canvasSize(screenSize: bounds.size, rotation: settings.rotation)
            transform = CanvasGeometry.layerTransform(
                rotation: settings.rotation, mirror: settings.mirrorHorizontal, flip: settings.flipVertical
            )
            canvasScale = 1
        case .preview:
            let preview = CanvasGeometry.previewTransform(
                settings: settings,
                outputScreenSize: session.outputScreenSize,
                showsAsOnTeleprompter: session.showsAsOnTeleprompter,
                in: bounds.size
            )
            canvasSize = preview.canvasSize
            transform = preview.transform
            canvasScale = max(preview.scale, 0.01)
        }
        pixelsPerCanvasPoint = backing * canvasScale

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.root.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        canvas.root.bounds = CGRect(origin: .zero, size: canvasSize)
        canvas.root.position = CGPoint(x: bounds.midX, y: bounds.midY)
        canvas.root.setAffineTransform(transform)
        let newLayout = canvas.configure(
            document: session.document, settings: settings, canvasSize: canvasSize, contentsScale: pixelsPerCanvasPoint
        )
        let engine = session.engine
        if let newLayout, role == .output || !session.hasOutputCanvas {
            engine.updateLayout(newLayout)
        }
        // Never ease a relayout: the content itself moved under the position.
        smoother.reset(to: engine.position)
        canvas.show(position: aligned(engine.position))
        canvas.update(status: status())
        CATransaction.commit()
        wake()
        // The previews follow the output's size (after the engine has its layout, so they show the right place).
        if role == .output { session.outputScreenSizeChanged(to: bounds.size, from: self) }
    }

    // MARK: Display link

    /// Runs the display link until the engine and the eased position are both at rest.
    func wake() {
        guard let link, link.isPaused else { return }
        previousFrameTime = nil
        link.isPaused = false
    }

    private func startDisplayLink() {
        guard link == nil else { return }
        let proxy = CanvasLinkProxy(view: self)
        linkProxy = proxy
        let link = displayLink(target: proxy, selector: #selector(CanvasLinkProxy.step(_:)))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        self.link = link
        wake()
    }

    func stopDisplayLink() {
        link?.invalidate()
        link = nil
        linkProxy = nil
        previousFrameTime = nil
    }

    fileprivate func step(_ link: CADisplayLink) {
        session.noteDisplayLinkFrame()
        let dt = previousFrameTime.map { link.targetTimestamp - $0 } ?? (link.targetTimestamp - link.timestamp)
        if renderFrame(at: link.targetTimestamp, dt: dt) {
            link.isPaused = true
            previousFrameTime = nil
        }
    }

    /// True while the display link is running.
    var isRunningFrames: Bool { link.map { !$0.isPaused } ?? false }

    /// A frame from the session's fallback timer, used only while no display link fires (see
    /// `PresenterSession.noteDisplayLinkFrame()`).
    func fallbackFrame(at time: TimeInterval) {
        let dt = previousFrameTime.map { time - $0 } ?? 1.0 / 60
        if renderFrame(at: time, dt: dt) {
            link?.isPaused = true
            previousFrameTime = nil
        }
    }

    /// Advances the engine to `time` and shows its (eased) position. Returns true when everything is at rest.
    private func renderFrame(at time: TimeInterval, dt: Double) -> Bool {
        previousFrameTime = time
        session.advance(to: time)
        let engine = session.engine
        let target = engine.position
        let shown = smoother.next(target: target, dt: dt)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.show(position: aligned(shown))
        canvas.update(status: status())
        CATransaction.commit()
        return !engine.needsFrames && smoother.current == target
    }

    private func aligned(_ position: Double) -> Double {
        CanvasGeometry.pixelAligned(position, pixelsPerPoint: pixelsPerCanvasPoint)
    }

    private func status() -> PrompterCanvasLayers.Status {
        let engine = session.engine
        return PrompterCanvasLayers.Status(
            state: engine.state,
            remaining: TimeFormatting.clock(engine.remainingSeconds),
            speed: engine.speedLabel,
            word: PresenterStatus.hudWord(for: engine.state, holdSeconds: engine.holdSecondsLeft),
            progress: engine.progress
        )
    }

    // MARK: Input

    /// The scroll wheel or a two-finger swipe moves the text like a finger drag on the iPhone (and pauses it).
    override func scrollWheel(with event: NSEvent) {
        var delta = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { delta *= 40 }
        guard delta != 0 else { return }
        session.scrub(by: -delta / canvasScale)
    }

    override func resetCursorRects() {
        if hidesCursor { addCursorRect(bounds, cursor: Self.blankCursor) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        guard hidesCursor else { return }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        if hidesCursor { Self.blankCursor.set() } else { super.cursorUpdate(with: event) }
    }

    /// An invisible pointer.
    static let blankCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    override var acceptsFirstResponder: Bool { false }
}

/// Holds the canvas view weakly, so the display link never keeps it alive.
@MainActor
private final class CanvasLinkProxy: NSObject {
    weak var view: PrompterCanvasView?

    init(view: PrompterCanvasView) {
        self.view = view
    }

    /// The display link fires on the main run loop.
    @objc func step(_ link: CADisplayLink) {
        guard let view else {
            link.invalidate()
            return
        }
        view.step(link)
    }
}
