import AppKit

/// The Mac's keys for the prompter (when Prompter is the active app), mapped to the same actions as the iPhone's
/// `PrompterKeyMap`. Works on hardware key codes (`NSEvent.keyCode`), so it doesn't depend on the keyboard layout
/// except for the punctuation keys, where the US-layout positions are used, as on the iPhone.
enum MacKeyMap {
    /// Virtual key codes (Carbon's `kVK_…` values).
    enum KeyCode {
        static let space: UInt16 = 49
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let downArrow: UInt16 = 125
        static let upArrow: UInt16 = 126
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
        static let pageDown: UInt16 = 121
        static let pageUp: UInt16 = 116
        static let equal: UInt16 = 24
        static let minus: UInt16 = 27
        static let keypadPlus: UInt16 = 69
        static let keypadMinus: UInt16 = 78
        static let zero: UInt16 = 29
        static let keypadZero: UInt16 = 82
        static let escape: UInt16 = 53
    }

    /// Space, Return, keypad Enter → togglePlay. Down/Right/PageDown → stepLine(+1) (Shift: stepParagraph(+1)).
    /// Up/Left/PageUp → stepLine(-1) (Shift: stepParagraph(-1)). "=" / Shift-"=" / keypad + → speedStep(+5).
    /// "-" / keypad - → speedStep(-5). "0" / keypad 0 → backToTop. Escape → exit. Anything else → nil.
    static func action(forKeyCode keyCode: UInt16, shift: Bool) -> PrompterKeyAction? {
        switch keyCode {
        case KeyCode.space, KeyCode.returnKey, KeyCode.keypadEnter:
            .togglePlay
        case KeyCode.downArrow, KeyCode.rightArrow, KeyCode.pageDown:
            shift ? .stepParagraph(1) : .stepLine(1)
        case KeyCode.upArrow, KeyCode.leftArrow, KeyCode.pageUp:
            shift ? .stepParagraph(-1) : .stepLine(-1)
        case KeyCode.equal, KeyCode.keypadPlus:
            .speedStep(5)
        case KeyCode.minus, KeyCode.keypadMinus:
            .speedStep(-5)
        case KeyCode.zero, KeyCode.keypadZero:
            .backToTop
        case KeyCode.escape:
            .exit
        default:
            nil
        }
    }

    /// The action for a key-down event, or nil (also nil with ⌘, ⌃ or ⌥ held, so menu shortcuts keep working).
    static func action(for event: NSEvent) -> PrompterKeyAction? {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        else { return nil }
        return action(forKeyCode: event.keyCode, shift: event.modifierFlags.contains(.shift))
    }
}
