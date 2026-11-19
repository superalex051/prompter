import UIKit

/// The scrolling text of the prompter, in UIKit so it can move every frame without SwiftUI re-rendering.
///
/// A non-interactive TextKit 2 `UITextView` shows the script; its `textContainerInset.top` is the reading line, so
/// `contentOffset.y` is exactly the engine's position. A `CADisplayLink` (through a weak proxy) ticks the engine and moves
/// the text each frame, and pauses itself when nothing moves. The view also owns the touch gestures (inside the mirrored
/// canvas, so drags follow the finger) and the hardware keys (as first responder).
final class PrompterTextView: UIView {
    struct Callbacks {
        /// Any touch on the canvas (the screen shows the close button for a few seconds).
        var onTouch: () -> Void = {}
        /// Long-press or two-finger tap.
        var onOpenSettings: () -> Void = {}
        /// Escape key.
        var onExit: () -> Void = {}
        /// A pinch ended at this font size (settings units).
        var onFontSizeCommit: (Double) -> Void = { _ in }
    }

    let engine: ScrollEngine
    var callbacks = Callbacks()

    private let textView = UITextView(usingTextLayoutManager: true)
    private var displayLink: CADisplayLink?
    private var previousFrameTime: CFTimeInterval?
    private var smoother = DisplayPositionSmoother()

    private var document = PrompterDocument.empty
    private var settings = PrompterSettings()
    /// What the text view shows now (nil before the first pass with a real size).
    private var appliedStyle: PrompterTextStyle?
    private var appliedDocument: PrompterDocument?

    /// The live font size (settings units) while a pinch is in progress.
    private var pinchFontSize: Double?
    private var pinchStartFontSize = 0.0
    private var lastPanTranslation = 0.0
    /// Presses this view handled, so their ends and cancels don't go up the responder chain either.
    private var handledPresses = Set<UIPress>()

    init(engine: ScrollEngine) {
        self.engine = engine
        super.init(frame: .zero)
        configureTextView()
        configureGestures()
        configureAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: Content

    /// New text or settings from SwiftUI. Relayouts only when the text or something that moves it changed.
    func update(document newDocument: PrompterDocument, settings newSettings: PrompterSettings) {
        if newDocument != document { document = newDocument }
        settings = newSettings
        applyContentIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if textView.frame != bounds { textView.frame = bounds }
        applyContentIfNeeded()
    }

    private var isPad: Bool { traitCollection.userInterfaceIdiom == .pad }

    /// Rebuilds the text and the engine's layout when needed, keeping the same line at the reading line.
    private func applyContentIfNeeded() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let style = PrompterTextStyle(settings: settings, canvasSize: size, isPad: isPad, fontSize: pinchFontSize)
        guard style != appliedStyle || document != appliedDocument else { return }

        let replacesText = document != appliedDocument || style.needsNewText(comparedTo: appliedStyle)
        if replacesText {
            backgroundColor = style.scheme.backgroundUIColor
            textView.backgroundColor = style.scheme.backgroundUIColor
            textView.attributedText = PrompterText.attributedString(document, style: style)
        }
        if textView.textContainerInset != style.textContainerInset {
            textView.textContainerInset = style.textContainerInset
        }
        appliedStyle = style
        appliedDocument = document

        // A new attributed string, even one that only changes the colours, throws TextKit 2's layout away; it then lays
        // out lazily around the viewport and only estimates everything above it, so deep in a long script the line drawn
        // at the reading line could disagree with the engine. So every time: lay out the whole document again and hand
        // the engine the result (it ignores a layout that didn't change, so the place and the state stay put).
        if replacesText, let layoutManager = textView.textLayoutManager {
            let probeBefore = DuoProbe.isEnabled ? probeReadingPoint() : nil
            let started = CACurrentMediaTime()
            textView.layoutIfNeeded()
            engine.updateLayout(PrompterLayoutExtractor.layout(of: layoutManager, document: document))
            if let probeBefore {
                let ms = Int(((CACurrentMediaTime() - started) * 1000).rounded())
                DuoProbe.log("relayout \(Int(size.width))x\(Int(size.height)) font \(Int(style.fontSize.rounded())) "
                    + "lines \(engine.layout.lines.count) \(ms) ms · \(engine.state) · before \(probeBefore) · after \(probeReadingPoint())")
            }
        } else if DuoProbe.isEnabled {
            DuoProbe.log("restyle \(Int(size.width))x\(Int(size.height)) reading line \(Int(style.readingLineY)) · \(probeReadingPoint())")
        }
        // Never ease a relayout: the content itself moved under the offset.
        smoother.reset(to: engine.position)
        showOffset(engine.position)
        wakeDisplayLink()
    }

    // MARK: Display link

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if DuoProbe.isEnabled { DuoProbe.log("text view \(window != nil ? "in a window" : "out of the window")") }
        if window != nil {
            startDisplayLink()
            // Keys: become first responder once the presentation has settled.
            Task { @MainActor [weak self] in self?.focusKeys() }
        } else {
            stopDisplayLink()
        }
    }

    /// Runs the display link until the engine and the eased display position are both at rest.
    /// Call after anything that can move the text: gestures, keys, engine events and state changes.
    func wakeDisplayLink() {
        guard let displayLink, displayLink.isPaused else { return }
        previousFrameTime = nil
        displayLink.isPaused = false
    }

    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        previousFrameTime = nil
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: DisplayLinkProxy(view: self), selector: #selector(DisplayLinkProxy.step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        displayLink = link
        wakeDisplayLink()
    }

    fileprivate func step(_ link: CADisplayLink) {
        let frameTime = link.targetTimestamp
        let dt = previousFrameTime.map { frameTime - $0 } ?? (link.targetTimestamp - link.timestamp)
        previousFrameTime = frameTime
        if DuoProbe.isEnabled { probeFrame(at: frameTime, dt: dt) }

        engine.tick(now: frameTime)
        let target = engine.position
        showOffset(smoother.next(target: target, dt: dt))

        if !engine.needsFrames, smoother.current == target {
            link.isPaused = true
            previousFrameTime = nil
        }
    }

    /// Moves the text so `position` sits at the reading line, on a whole device pixel (crisp glyphs while moving).
    private func showOffset(_ position: Double) {
        let scale = max(traitCollection.displayScale, 1)
        let y = (position * scale).rounded() / scale
        if textView.contentOffset.y != y || textView.contentOffset.x != 0 {
            textView.contentOffset = CGPoint(x: 0, y: y)
        }
    }

    // MARK: Setup

    private func configureTextView() {
        clipsToBounds = true
        backgroundColor = .black
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = true
        textView.isUserInteractionEnabled = false
        textView.showsVerticalScrollIndicator = false
        textView.showsHorizontalScrollIndicator = false
        textView.scrollsToTop = false
        textView.contentInsetAdjustmentBehavior = .never
        textView.textContainer.lineFragmentPadding = 0
        textView.backgroundColor = .black
        textView.isAccessibilityElement = false
        addSubview(textView)
    }

    private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))

    private func configureGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap))
        twoFingerTap.numberOfTouchesRequired = 2
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        // A one-finger tap waits only for these to fail, which they do the moment the finger lifts.
        tap.require(toFail: twoFingerTap)
        tap.require(toFail: longPress)
        for recognizer in [tap, twoFingerTap, longPress, pan, pinch] as [UIGestureRecognizer] {
            addGestureRecognizer(recognizer)
        }
    }

    private func configureAccessibility() {
        isAccessibilityElement = true
        accessibilityIdentifier = "prompter.canvas"
        accessibilityLabel = "Script"
        accessibilityHint = "Tap to start or pause. Long-press or tap with two fingers for settings."
        accessibilityTraits = [.allowsDirectInteraction]
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Settings") { [weak self] _ in
                self?.callbacks.onOpenSettings()
                return true
            },
            UIAccessibilityCustomAction(name: "Back to top") { [weak self] _ in
                self?.engine.backToTop()
                self?.wakeDisplayLink()
                return true
            },
        ]
    }

    override func accessibilityActivate() -> Bool {
        engine.togglePlay()
        wakeDisplayLink()
        return true
    }

    // MARK: Touch

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        callbacks.onTouch()
    }

    @objc private func handleTap() {
        engine.togglePlay()
        wakeDisplayLink()
    }

    @objc private func handleTwoFingerTap() {
        callbacks.onOpenSettings()
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        callbacks.onOpenSettings()
    }

    /// The text follows the finger: dragging up moves further into the script. Scrubbing pauses (or cancels a countdown).
    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self).y
        switch recognizer.state {
        case .began:
            lastPanTranslation = 0
            engine.scrubBegan()
            fallthrough
        case .changed:
            let delta = translation - lastPanTranslation
            lastPanTranslation = translation
            engine.scrub(by: -delta)
            smoother.reset(to: engine.position)
            showOffset(engine.position)
        default:
            lastPanTranslation = 0
        }
        wakeDisplayLink()
    }

    /// Live text size (24…200, whole points), re-anchored by the engine; saved when the fingers lift.
    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        let range = PrompterSettings.fontSizeRange
        switch recognizer.state {
        case .began:
            pinchStartFontSize = pinchFontSize ?? settings.fontSize
            fallthrough
        case .changed:
            let size = min(max((pinchStartFontSize * recognizer.scale).rounded(), range.lowerBound), range.upperBound)
            guard size != pinchFontSize else { return }
            pinchFontSize = size
            applyContentIfNeeded()
        case .ended, .cancelled, .failed:
            guard let size = pinchFontSize else { return }
            // The store gets the same value synchronously, so the next update already carries it.
            settings.fontSize = size
            pinchFontSize = nil
            callbacks.onFontSizeCommit(size)
        default:
            break
        }
    }

    // MARK: Probe (debug, `-duoProbe`)

    private var probeFrames = 0
    private var probeSince: CFTimeInterval?
    private var probeLongestFrame = 0.0

    /// Once a second while the link runs: how many frames came, the longest gap, where the text is.
    private func probeFrame(at time: CFTimeInterval, dt: CFTimeInterval) {
        probeFrames += 1
        probeLongestFrame = max(probeLongestFrame, dt)
        guard let since = probeSince else { probeSince = time; return }
        guard time - since >= 1 else { return }
        DuoProbe.log("frames \(probeFrames) in \(String(format: "%.2f", time - since)) s, longest \(Int((probeLongestFrame * 1000).rounded())) ms"
            + " · \(engine.state) · \(probeReadingPoint())")
        probeFrames = 0
        probeLongestFrame = 0
        probeSince = time
    }

    /// The place at the reading line: position, the line's first character plus the fraction through it, the character
    /// that interpolates to, and the start of that line's text.
    private func probeReadingPoint() -> String {
        let layout = engine.layout
        let position = engine.position
        guard let index = layout.lineIndex(at: position) else { return "pos \(Int(position)) (no layout)" }
        let anchor = layout.anchor(at: position)
        let start = layout.lines[index].characterIndex
        let end = index + 1 < layout.lines.count ? layout.lines[index + 1].characterIndex : document.text.utf16.count
        let point = Double(start) + anchor.fraction * Double(end - start)
        let utf16 = Array(document.text.utf16)
        let lower = min(max(start, 0), utf16.count)
        let upper = min(lower + 28, utf16.count)
        let text = String(decoding: utf16[lower..<upper], as: UTF16.self).replacingOccurrences(of: "\n", with: " / ")
        return "pos \(String(format: "%.1f", position)) line \(index) char \(start)+\(String(format: "%.2f", anchor.fraction)) "
            + "= \(String(format: "%.1f", point)) \"\(text)\""
    }

    // MARK: Keys

    override var canBecomeFirstResponder: Bool { true }

    func focusKeys() {
        guard window != nil, !isFirstResponder else { return }
        becomeFirstResponder()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key,
                  key.modifierFlags.isDisjoint(with: [.command, .control, .alternate]),
                  let action = PrompterKeyMap.action(for: key.keyCode, shift: key.modifierFlags.contains(.shift))
            else {
                unhandled.insert(press)
                continue
            }
            handledPresses.insert(press)
            perform(action)
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        forwardUnhandled(presses) { super.pressesEnded($0, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        forwardUnhandled(presses) { super.pressesCancelled($0, with: event) }
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.subtracting(handledPresses)
        if !unhandled.isEmpty { super.pressesChanged(unhandled, with: event) }
    }

    private func forwardUnhandled(_ presses: Set<UIPress>, to forward: (Set<UIPress>) -> Void) {
        let unhandled = presses.subtracting(handledPresses)
        handledPresses.subtract(presses)
        if !unhandled.isEmpty { forward(unhandled) }
    }

    private func perform(_ action: PrompterKeyAction) {
        switch action {
        case .togglePlay: engine.togglePlay()
        case .stepLine(let n): engine.stepLine(n)
        case .stepParagraph(let n): engine.stepParagraph(n)
        case .speedStep(let n): engine.speedStep(n)
        case .backToTop: engine.backToTop()
        case .exit: callbacks.onExit()
        }
        wakeDisplayLink()
    }
}

/// Holds the text view weakly so the display link (which retains its target) never keeps it alive.
@MainActor
private final class DisplayLinkProxy: NSObject {
    weak var view: PrompterTextView?

    init(view: PrompterTextView) {
        self.view = view
    }

    @objc func step(_ link: CADisplayLink) {
        guard let view else {
            link.invalidate()
            return
        }
        view.step(link)
    }
}
