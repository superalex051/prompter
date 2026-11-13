import AppKit
import SwiftUI

/// The script's plain-text editor: an `NSTextView` in a scroll view, so the text column can be centered at any window
/// width, the scroll bar sits at the window's edge, smart quotes and dashes stay off (a script isn't prose to correct),
/// and notes and pause cues are coloured as you type. With Markdown formatting on, the Markdown shows live too: bold in
/// amber, italic, headings larger and amber, the markers dimmed (they stay in the text: it is still plain text). Edits go through the window's undo manager, so ⌘Z works as usual.
struct ScriptTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// Each change moves keyboard focus into the text (Return in the title field).
    var focusRequest = 0
    var margin: Double
    var fontSize: CGFloat = 17
    var lineSpacing: CGFloat = 6
    /// Settings → Markdown formatting.
    var markdown = false

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        makeScrollView(coordinator: context.coordinator)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        update(scrollView, coordinator: context.coordinator)
    }

    /// `makeNSView` without SwiftUI's context (the tests use it too).
    func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        let textView = ScriptNSTextView()
        textView.delegate = coordinator
        textView.onCompositionEnded = { [weak coordinator, weak textView] in
            guard let coordinator, let textView else { return }
            coordinator.compositionEnded(in: textView)
        }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = Self.lineFragmentPadding
        textView.textContainerInset = NSSize(width: max(margin - Self.lineFragmentPadding, 0), height: 14)
        textView.insertionPointColor = NSColor(named: "AccentColor") ?? .controlAccentColor
        textView.setAccessibilityLabel("Script text")
        scrollView.documentView = textView

        coordinator.configure(textView, from: self)
        coordinator.watchUndo(of: textView)
        coordinator.apply(text: text, to: textView)
        coordinator.lastFocusRequest = focusRequest
        return scrollView
    }

    /// `updateNSView` without SwiftUI's context.
    func update(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let textView = scrollView.documentView as? ScriptNSTextView else { return }
        coordinator.parent = self
        if coordinator.highlightedMarkdown != markdown { coordinator.highlight(textView) }
        let inset = NSSize(width: max(margin - Self.lineFragmentPadding, 0), height: 14)
        if textView.textContainerInset != inset { textView.textContainerInset = inset }
        if coordinator.lastFocusRequest != focusRequest {
            coordinator.lastFocusRequest = focusRequest
            textView.window?.makeFirstResponder(textView)
        }
        // Only outside changes (a new version from the iPhone). Typing already matches, so the cursor stays.
        if textView.string != text {
            coordinator.receive(outsideText: text, in: textView)
        }
    }

    static let lineFragmentPadding: CGFloat = 5

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScriptTextEditor
        var lastFocusRequest = 0
        private var attributes: [NSAttributedString.Key: Any] = [:]
        /// A new text from outside that arrived in the middle of a composition (marked text: an accent or an input
        /// method), with the editor's text at that moment, with and without the composition. It goes in once the
        /// composition ends, unless the person changed the text by then (their edit then wins, and is saved and synced as
        /// usual).
        private var pendingOutsideText: (text: String, textThen: String, textThenWithoutComposition: String)?
        /// Set while the editor puts in a text from outside, so `textDidChange` doesn't hand it back as typing.
        private var isApplyingOutsideText = false
        private weak var textView: NSTextView?
        private var undoObservers: [any NSObjectProtocol] = []

        isolated deinit {
            for observer in undoObservers { NotificationCenter.default.removeObserver(observer) }
        }

        /// Undo and Redo change the text without a `textDidChange`: take the result into the binding (so it is saved and
        /// synced) after each.
        func watchUndo(of textView: NSTextView) {
            self.textView = textView
            for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                undoObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) {
                    [weak self] notification in
                    nonisolated(unsafe) let manager = notification.object as AnyObject?
                    MainActor.assumeIsolated { self?.undoManagerChanged(manager) }
                })
            }
        }

        private func undoManagerChanged(_ manager: AnyObject?) {
            guard let textView, let manager, manager === textView.undoManager, !textView.hasMarkedText(),
                  textView.string != parent.text
            else { return }
            parent.text = textView.string
            highlight(textView)
        }

        init(_ parent: ScriptTextEditor) {
            self.parent = parent
        }

        func configure(_ textView: NSTextView, from editor: ScriptTextEditor) {
            let font = NSFont.systemFont(ofSize: editor.fontSize, weight: .regular)
            let style = NSMutableParagraphStyle()
            style.lineSpacing = editor.lineSpacing
            attributes = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
            textView.font = font
            textView.textColor = .labelColor
            textView.defaultParagraphStyle = style
            textView.typingAttributes = attributes
        }

        /// Fills the editor with the script's text (when it opens; not an undoable change).
        func apply(text: String, to textView: NSTextView) {
            let selection = textView.selectedRange()
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
            highlight(textView)
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        }

        /// A new text from outside (sync). Put in as one undoable change, so the undo steps of earlier typing still fit
        /// the text they were made on (⌘Z first takes the outside change back, then the typing before it). During a
        /// composition it waits for the composition to end.
        func receive(outsideText text: String, in textView: NSTextView) {
            if textView.hasMarkedText() {
                let current = textView.string
                let marked = textView.markedRange()
                let withoutComposition = marked.location == NSNotFound
                    ? current
                    : (current as NSString).replacingCharacters(in: marked, with: "")
                pendingOutsideText = (text, current, withoutComposition)
                return
            }
            pendingOutsideText = nil
            replaceAll(with: text, in: textView)
        }

        /// The composition ended (committed or cancelled): a text from outside that waited for it goes in now, unless the
        /// person changed the text since it arrived.
        func compositionEnded(in textView: NSTextView) {
            guard let pending = pendingOutsideText, !textView.hasMarkedText() else { return }
            pendingOutsideText = nil
            guard Self.isUnchanged(textView.string, since: pending) else {
                // The composition put something new in: the person's edit wins (`textDidChange` saved it).
                if parent.text != textView.string { parent.text = textView.string }
                return
            }
            if textView.string != pending.text { replaceAll(with: pending.text, in: textView) }
            if parent.text != pending.text { parent.text = pending.text }
        }

        /// The text is what it was when the outside text arrived (the composition was committed as it stood, or
        /// cancelled).
        private static func isUnchanged(
            _ current: String, since pending: (text: String, textThen: String, textThenWithoutComposition: String)
        ) -> Bool {
            current == pending.textThen || current == pending.textThenWithoutComposition
        }

        /// Replaces the whole text as one undoable change.
        private func replaceAll(with text: String, in textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let selection = textView.selectedRange()
            let whole = NSRange(location: 0, length: storage.length)
            isApplyingOutsideText = true
            defer { isApplyingOutsideText = false }
            textView.breakUndoCoalescing()
            if textView.shouldChangeText(in: whole, replacementString: text) {
                storage.replaceCharacters(in: whole, with: NSAttributedString(string: text, attributes: attributes))
                textView.didChangeText()
            } else {
                // Not editable right now: replace it outright, and drop undo steps that no longer fit the text.
                storage.setAttributedString(NSAttributedString(string: text, attributes: attributes))
                textView.undoManager?.removeAllActions(withTarget: storage)
                textView.undoManager?.removeAllActions(withTarget: textView)
            }
            textView.breakUndoCoalescing()
            highlight(textView)
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, !isApplyingOutsideText else { return }
            if let pending = pendingOutsideText, !textView.hasMarkedText(), Self.isUnchanged(textView.string, since: pending) {
                // The composition ended without changing anything: don't save the old text over the new one from
                // outside; `compositionEnded` (right after this) puts the new one in.
                highlight(textView)
                return
            }
            parent.text = textView.string
            highlight(textView)
        }

        /// The Markdown setting the text was last highlighted with (nil: not yet).
        private(set) var highlightedMarkdown: Bool?

        /// Editor sizes of Markdown headings (`#`, `##`, `###` and deeper); the text is 17 pt.
        static let headingSizes: [CGFloat] = [24, 21, 19]

        /// Notes are dimmed and pause cues are amber; with Markdown on, headings are larger and amber, bold is amber,
        /// italic and strikethrough show, and the markers are dimmed. Plain attribute changes: no undo steps, the cursor
        /// stays.
        func highlight(_ textView: NSTextView) {
            guard let storage = textView.textStorage, !textView.hasMarkedText() else { return }
            let markdown = parent.markdown
            highlightedMarkdown = markdown
            let whole = NSRange(location: 0, length: storage.length)
            let accent = NSColor(named: "AccentColor") ?? .controlAccentColor
            storage.beginEditing()
            storage.removeAttribute(.strikethroughStyle, range: whole)
            storage.addAttributes(attributes, range: whole)
            for span in ScriptHighlight.spans(in: storage.string, markdown: markdown)
            where NSMaxRange(span.range) <= storage.length {
                switch span.kind {
                case .note:
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: span.range)
                case .pause:
                    storage.addAttribute(.foregroundColor, value: accent, range: span.range)
                case .heading(let level):
                    let size = Self.headingSizes[min(max(level, 1), Self.headingSizes.count) - 1]
                    storage.addAttributes(
                        [.font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: accent],
                        range: span.range
                    )
                case .rule, .marker:
                    storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: span.range)
                case .styled(let style):
                    applyInline(style, to: storage, range: span.range, accent: accent)
                }
            }
            storage.endEditing()
            textView.typingAttributes = attributes
        }

        /// Bold: amber and bold; italic: italic; strikethrough: struck and dimmed; code: monospaced. Fonts keep their
        /// size, so a bold word in a heading stays heading-sized.
        private func applyInline(_ style: MarkdownStyle, to storage: NSTextStorage, range: NSRange, accent: NSColor) {
            if style.contains(.bold) { storage.addAttribute(.foregroundColor, value: accent, range: range) }
            if style.contains(.strikethrough) {
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
            }
            guard style.contains(.bold) || style.contains(.italic) || style.contains(.code) else { return }
            storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                guard let font = value as? NSFont else { return }
                var converted = font
                if style.contains(.code) {
                    converted = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
                }
                if style.contains(.bold) { converted = NSFontManager.shared.convert(converted, toHaveTrait: .boldFontMask) }
                if style.contains(.italic) {
                    converted = NSFontManager.shared.convert(converted, toHaveTrait: .italicFontMask)
                }
                storage.addAttribute(.font, value: converted, range: subrange)
            }
        }
    }
}

/// The editor's `NSTextView`: a subclass so the representable can find it again in `updateNSView`, and to hear when a
/// composition (marked text) ends.
final class ScriptNSTextView: NSTextView {
    var onCompositionEnded: (() -> Void)?
    /// How deep inside the text input calls below this is (they call each other: `unmarkText` inserts the marked text).
    /// The end of a composition is reported once the outermost one has returned, never while AppKit is still at it.
    private var inputCallDepth = 0

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        trackComposition { super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange) }
    }

    override func unmarkText() {
        trackComposition { super.unmarkText() }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        trackComposition { super.insertText(string, replacementRange: replacementRange) }
    }

    private func trackComposition(_ call: () -> Void) {
        let wasComposing = hasMarkedText()
        inputCallDepth += 1
        call()
        inputCallDepth -= 1
        if inputCallDepth == 0, wasComposing, !hasMarkedText() { onCompositionEnded?() }
    }
}
