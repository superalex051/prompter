import UIKit

enum PrompterKeyMap {
    /// Space, Return, keypad Enter → togglePlay. Down/Right/PageDown → stepLine(+1) (Shift: stepParagraph(+1)).
    /// Up/Left/PageUp → stepLine(-1) (Shift: stepParagraph(-1)). "=" / Shift-"=" / keypad + → speedStep(+5).
    /// "-" / keypad - → speedStep(-5). "0" / keypad 0 → backToTop. Escape → exit. Anything else → nil.
    /// Shift only matters for the arrow and page keys.
    static func action(for usage: UIKeyboardHIDUsage, shift: Bool) -> PrompterKeyAction? {
        switch usage {
        case .keyboardSpacebar, .keyboardReturnOrEnter, .keyboardReturn, .keypadEnter:
            .togglePlay
        case .keyboardDownArrow, .keyboardRightArrow, .keyboardPageDown:
            shift ? .stepParagraph(1) : .stepLine(1)
        case .keyboardUpArrow, .keyboardLeftArrow, .keyboardPageUp:
            shift ? .stepParagraph(-1) : .stepLine(-1)
        case .keyboardEqualSign, .keypadPlus:
            .speedStep(5)
        case .keyboardHyphen, .keypadHyphen:
            .speedStep(-5)
        case .keyboard0, .keypad0:
            .backToTop
        case .keyboardEscape:
            .exit
        default:
            nil
        }
    }
}
