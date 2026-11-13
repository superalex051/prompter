import AppKit

/// Which key presses the prompter takes while presenting. Pure apart from reading the event.
enum PresenterKeyRouting {
    /// Where a key press happened.
    enum Target: Equatable, Sendable {
        /// The Presenter view or the output window.
        case presenting
        /// Another window of the app (the library, Settings).
        case otherWindow
    }

    /// The kind of control that has keyboard focus in the presenting windows (Full Keyboard Access), when it is one that
    /// uses some of the prompter's keys itself.
    enum FocusedControl: Equatable, Sendable {
        case none
        /// A slider (or segmented control): ← and → move it.
        case slider
        /// A button: Space and Return press it.
        case button
    }

    /// The prompter's action for a key press, or nil to let it through: only in the presenting windows, never while
    /// typing in a text field (Escape included: it belongs to the field there), never with ⌘, ⌃ or ⌥ held, so menu
    /// shortcuts keep working (`MacKeyMap`), and never a key the focused control uses (← → on a slider, Space and Return
    /// on a button).
    static func action(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        target: Target,
        isEditingText: Bool,
        focusedControl: FocusedControl = .none
    ) -> PrompterKeyAction? {
        guard target == .presenting, !isEditingText,
              modifiers.intersection([.command, .control, .option]).isEmpty
        else { return nil }
        typealias Key = MacKeyMap.KeyCode
        switch focusedControl {
        case .slider where keyCode == Key.leftArrow || keyCode == Key.rightArrow:
            return nil
        case .button where keyCode == Key.space || keyCode == Key.returnKey || keyCode == Key.keypadEnter:
            return nil
        default:
            return MacKeyMap.action(forKeyCode: keyCode, shift: modifiers.contains(.shift))
        }
    }

    /// True when `responder` takes typed text (a text field's editor or a text view that is editable).
    @MainActor
    static func isTextInput(_ responder: NSResponder?) -> Bool {
        guard let textView = responder as? NSTextView else { return false }
        return textView.isEditable || textView.isFieldEditor
    }

    /// The kind of focused control `responder` is, as far as the prompter's keys are concerned.
    @MainActor
    static func focusedControl(_ responder: NSResponder?) -> FocusedControl {
        switch responder {
        case let control as NSControl where !control.isEnabled:
            .none
        case is NSSlider, is NSSegmentedControl:
            .slider
        case is NSButton:
            .button
        default:
            .none
        }
    }

    /// What Esc does while presenting.
    enum EscapeOutcome: Equatable, Sendable {
        case pause
        case stopPresenting
    }

    /// Esc while the text runs (or counts down) pauses it; a second Esc, or Esc when nothing runs, stops presenting.
    static func escapeOutcome(for state: PlaybackState) -> EscapeOutcome {
        switch state {
        case .playing, .countdown: .pause
        case .idle, .paused, .finished: .stopPresenting
        }
    }
}
