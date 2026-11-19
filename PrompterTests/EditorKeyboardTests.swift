import Foundation
import SwiftUI
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

    /// An editor that goes away while typing (another script picked in the split view) never reports the keyboard going
    /// down. Opening the script again with the keyboard down, then folding, must not raise it.
    @Test func openingAnotherScriptForgetsTheOldFocus() {
        var keyboard = EditorKeyboard()
        keyboard.focusChanged(to: .body, in: a)
        keyboard.openScriptChanged()   // b opened
        keyboard.openScriptChanged()   // a opened again, keyboard down
        keyboard.layoutChanged(openScript: a)
        #expect(keyboard.take(for: a) == EditorKeyboard.Handoff(scriptID: a, field: nil))
    }

    @Test func openingAnotherScriptDropsAHandoffNobodyTook() {
        var keyboard = EditorKeyboard()
        keyboard.focusChanged(to: .body, in: a)
        keyboard.layoutChanged(openScript: a)
        keyboard.openScriptChanged()
        #expect(keyboard.take(for: a) == nil)
    }

    /// The finding: after a switch the keyboard came back with the cursor at the end of the script, so the next words
    /// landed there and not where the person was writing.
    @Test func theCursorInTheScriptTextIsHandedOver() {
        var keyboard = EditorKeyboard()
        keyboard.focusChanged(to: .body, in: a)
        keyboard.selectionChanged(to: 120..<120, in: a)
        keyboard.layoutChanged(openScript: a)
        #expect(keyboard.take(for: a) == EditorKeyboard.Handoff(scriptID: a, field: .body, selection: 120..<120))
    }

    @Test func theLastCursorWinsAndAFocusChangeKeepsIt() {
        var keyboard = EditorKeyboard()
        keyboard.focusChanged(to: .body, in: a)
        keyboard.selectionChanged(to: 10..<10, in: a)
        keyboard.selectionChanged(to: 42..<47, in: a)
        keyboard.focusChanged(to: .title, in: a)
        keyboard.focusChanged(to: .body, in: a)
        keyboard.layoutChanged(openScript: a)
        #expect(keyboard.take(for: a)?.selection == 42..<47)
    }

    @Test func anotherScriptsCursorIsNotHandedOver() {
        var keyboard = EditorKeyboard()
        keyboard.focusChanged(to: .body, in: a)
        keyboard.selectionChanged(to: 30..<30, in: a)
        keyboard.layoutChanged(openScript: b)
        #expect(keyboard.take(for: b)?.selection == nil)
    }

    @Test func openingAnotherScriptForgetsTheCursor() {
        var keyboard = EditorKeyboard()
        keyboard.focusChanged(to: .body, in: a)
        keyboard.selectionChanged(to: 30..<30, in: a)
        keyboard.openScriptChanged()
        keyboard.focusChanged(to: .body, in: a)
        keyboard.layoutChanged(openScript: a)
        #expect(keyboard.take(for: a) == EditorKeyboard.Handoff(scriptID: a, field: .body, selection: nil))
    }

    @Test func aSwitchWithNothingOpenLeavesNothing() {
        var keyboard = EditorKeyboard()
        keyboard.focusChanged(to: .body, in: a)
        keyboard.layoutChanged(openScript: nil)
        #expect(keyboard.take(for: a) == nil)
    }
}

struct EditorSelectionTests {
    private let text = "Hello there. 👋🏽 Rig tour."

    @Test func aCursorRoundTripsThroughOffsets() throws {
        let index = try #require(text.firstIndex(of: "R"))
        let offsets = EditorSelection.offsets(of: TextSelection(insertionPoint: index), in: text)
        #expect(offsets == 18..<18)   // 13 characters, then the waving hand (4 UTF-16 units) and a space
        let back = EditorSelection.selection(at: try #require(offsets), in: text)
        #expect(back == TextSelection(insertionPoint: index))
    }

    @Test func aSelectedRangeRoundTripsToo() throws {
        let start = try #require(text.firstIndex(of: "t"))
        let end = text.index(start, offsetBy: 5)
        let offsets = try #require(EditorSelection.offsets(of: TextSelection(range: start..<end), in: text))
        #expect(offsets == 6..<11)
        #expect(EditorSelection.selection(at: offsets, in: text) == TextSelection(range: start..<end))
    }

    @Test func noSelectionGivesNoOffsets() {
        #expect(EditorSelection.offsets(of: nil, in: text) == nil)
    }

    /// The text view can report a cursor a moment before the text that goes with it.
    @Test func aCursorPastTheEndOfTheTextIsIgnored() {
        let longer = text + " More words."
        #expect(EditorSelection.offsets(of: TextSelection(insertionPoint: longer.endIndex), in: text) == nil)
    }

    /// The text may have changed between the switch and the new editor (a sync from the Mac): the cursor stays inside it.
    @Test func offsetsPastTheEndLandAtTheEnd() {
        #expect(EditorSelection.selection(at: 500..<520, in: text) == TextSelection(insertionPoint: text.endIndex))
        let tail = text.index(text.endIndex, offsetBy: -4)
        #expect(EditorSelection.selection(at: 23..<520, in: text) == TextSelection(range: tail..<text.endIndex))
    }

    /// An offset inside the waving hand (two scalars, four UTF-16 units) goes back to the start of the character.
    @Test func anOffsetInsideACharacterGoesToItsStart() throws {
        let hand = try #require(text.firstIndex(of: "👋🏽"))
        for offset in 14...16 {
            #expect(EditorSelection.selection(at: offset..<offset, in: text) == TextSelection(insertionPoint: hand))
        }
    }

    @Test func anEmptyTextTakesACursorAtItsStart() {
        #expect(EditorSelection.selection(at: 7..<7, in: "") == TextSelection(insertionPoint: "".startIndex))
    }
}
