import Testing
import UIKit
@testable import Prompter

struct PrompterKeyMapTests {
    @Test(arguments: [
        // Play / pause
        (UIKeyboardHIDUsage.keyboardSpacebar, false, PrompterKeyAction.togglePlay),
        (.keyboardSpacebar, true, .togglePlay),
        (.keyboardReturnOrEnter, false, .togglePlay),
        (.keyboardReturn, false, .togglePlay),
        (.keypadEnter, false, .togglePlay),
        // Forward a line (Shift: a paragraph)
        (.keyboardDownArrow, false, .stepLine(1)),
        (.keyboardRightArrow, false, .stepLine(1)),
        (.keyboardPageDown, false, .stepLine(1)),
        (.keyboardDownArrow, true, .stepParagraph(1)),
        (.keyboardRightArrow, true, .stepParagraph(1)),
        (.keyboardPageDown, true, .stepParagraph(1)),
        // Back a line (Shift: a paragraph)
        (.keyboardUpArrow, false, .stepLine(-1)),
        (.keyboardLeftArrow, false, .stepLine(-1)),
        (.keyboardPageUp, false, .stepLine(-1)),
        (.keyboardUpArrow, true, .stepParagraph(-1)),
        (.keyboardLeftArrow, true, .stepParagraph(-1)),
        (.keyboardPageUp, true, .stepParagraph(-1)),
        // Speed
        (.keyboardEqualSign, false, .speedStep(5)),
        (.keyboardEqualSign, true, .speedStep(5)),     // Shift-"=" is "+"
        (.keypadPlus, false, .speedStep(5)),
        (.keyboardHyphen, false, .speedStep(-5)),
        (.keypadHyphen, false, .speedStep(-5)),
        // Back to top, exit
        (.keyboard0, false, .backToTop),
        (.keypad0, false, .backToTop),
        (.keyboardEscape, false, .exit),
    ])
    func mapsKey(usage: UIKeyboardHIDUsage, shift: Bool, expected: PrompterKeyAction) {
        #expect(PrompterKeyMap.action(for: usage, shift: shift) == expected)
    }

    @Test(arguments: [
        UIKeyboardHIDUsage.keyboardA, .keyboardB, .keyboard1, .keyboardTab, .keyboardF5, .keyboardDeleteOrBackspace,
        .keyboardPeriod, .keypad1,
    ])
    func unmappedKeyDoesNothing(usage: UIKeyboardHIDUsage) {
        #expect(PrompterKeyMap.action(for: usage, shift: false) == nil)
        #expect(PrompterKeyMap.action(for: usage, shift: true) == nil)
    }
}
