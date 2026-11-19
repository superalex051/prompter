import Foundation
import Testing
@testable import Prompter

struct EditorKeyboardTests {
    private let a = UUID()
    private let b = UUID()

    @Test func aLayoutSwitchWhileTypingHandsTheFieldToTheNewEditor() {
        var keyboard = EditorKeyboard()
        keyboard.focusChanged(to: .body, in: a)
        keyboard.layoutChanged(openScript: a)
        #expect(keyboard.take(for: a) == EditorKeyboard.Handoff(scriptID: a, field: .body))
        // Taken once: a later editor of the same script opens as usual.
        #expect(keyboard.take(for: a) == nil)
    }

    @Test func theTitleFieldIsHandedOverToo() {
        var keyboard = EditorKeyboard()
        keyboard.focusChanged(to: .title, in: a)
        keyboard.layoutChanged(openScript: a)
        #expect(keyboard.take(for: a)?.field == .title)
    }

    @Test func aSwitchWithTheKeyboardDownKeepsItDown() {
        var keyboard = EditorKeyboard()
        keyboard.focusChanged(to: .body, in: a)
        keyboard.focusChanged(to: nil, in: a)
        keyboard.layoutChanged(openScript: a)
        let handoff = keyboard.take(for: a)
        #expect(handoff == EditorKeyboard.Handoff(scriptID: a, field: nil))
    }

    @Test func anEditorOpenedWithoutASwitchGetsNothing() {
        var keyboard = EditorKeyboard()
        keyboard.focusChanged(to: .body, in: a)
        #expect(keyboard.take(for: a) == nil)
    }

    @Test func theHandoffIsOnlyForTheScriptThatWasOpen() {
        var keyboard = EditorKeyboard()
        keyboard.focusChanged(to: .body, in: a)
        keyboard.layoutChanged(openScript: a)
        #expect(keyboard.take(for: b) == nil)
        #expect(keyboard.take(for: a)?.field == .body)
    }

    @Test func focusFromAnotherScriptsEditorIsNotHandedOver() {
        var keyboard = EditorKeyboard()
        keyboard.focusChanged(to: .body, in: a)
        keyboard.layoutChanged(openScript: b)
        #expect(keyboard.take(for: b) == EditorKeyboard.Handoff(scriptID: b, field: nil))
    }

    @Test func aSwitchWithNothingOpenLeavesNothing() {
        var keyboard = EditorKeyboard()
        keyboard.focusChanged(to: .body, in: a)
        keyboard.layoutChanged(openScript: nil)
        #expect(keyboard.take(for: a) == nil)
    }
}
