import SwiftUI
import Testing
@testable import Prompter

struct EditorSideBarTests {
    @Test func theCameraLeftBarWithTheKeyboardUpGetsThePlainSymbol() {
        #expect(EditorSideBar.promptGlyph(edge: .leading, keyboardShows: true) == .inMenu)
    }

    @Test func everywhereElseThePlaySymbolIsBlackOnAmber() {
        #expect(EditorSideBar.promptGlyph(edge: .leading, keyboardShows: false) == .onAmber)
        #expect(EditorSideBar.promptGlyph(edge: .trailing, keyboardShows: true) == .onAmber)
        #expect(EditorSideBar.promptGlyph(edge: .trailing, keyboardShows: false) == .onAmber)
        #expect(EditorSideBar.promptGlyph(edge: nil, keyboardShows: true) == .onAmber)
        #expect(EditorSideBar.promptGlyph(edge: nil, keyboardShows: false) == .onAmber)
    }

    @Test func onlyAFullKeyboardCountsAsTheSoftwareKeyboard() {
        // The cover held on its side has the smallest software keyboard seen: 230 pt (466 - 236).
        #expect(EditorSideBar.isSoftwareKeyboard(height: 230))
        #expect(EditorSideBar.isSoftwareKeyboard(height: 355))
        // A hardware keyboard's bar of suggestions, and a keyboard frame that is gone.
        #expect(!EditorSideBar.isSoftwareKeyboard(height: 55))
        #expect(!EditorSideBar.isSoftwareKeyboard(height: 0))
    }
}
