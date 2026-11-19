import Foundation
import Testing
@testable import Prompter

struct LibraryNavigationTests {
    private let a = UUID()
    private let b = UUID()

    @Test func openingPushesOnTheStackAndShowsInTheDetail() {
        var navigation = LibraryNavigation()
        navigation.open(a)
        #expect(navigation.path == [a])
        #expect(navigation.selection == a)
        #expect(navigation.isOpen(a))
    }

    @Test func openingAnotherScriptReplacesTheOpenOne() {
        var navigation = LibraryNavigation()
        navigation.open(a)
        navigation.open(b)
        #expect(navigation.selection == b)
        #expect(navigation.path == [b])
        #expect(!navigation.isOpen(a))
    }

    /// The iPhone Duo folding or unfolding switches between the stack and the split view. Both read the same open script,
    /// so nothing has to be handed over and the script stays open (no empty detail, no second push, no lost blank script).
    @Test func theOpenScriptIsTheSameForBothLayouts() {
        var navigation = LibraryNavigation()
        navigation.open(a)
        let stackPath = navigation.path
        let splitSelection = navigation.selection
        #expect(stackPath == [a])
        #expect(splitSelection == a)
    }

    @Test func poppingTheStackClosesTheScript() {
        var navigation = LibraryNavigation()
        navigation.open(a)
        navigation.setPath([])
        #expect(navigation.openScript == nil)
        #expect(navigation.path.isEmpty)
        #expect(navigation.selection == nil)
        #expect(!navigation.isOpen(a))
    }

    @Test func nothingOpenIsEmptyInBothLayouts() {
        let navigation = LibraryNavigation()
        #expect(navigation.path.isEmpty)
        #expect(navigation.selection == nil)
        #expect(navigation == LibraryNavigation())
    }

    @Test func deletingTheOpenScriptClearsTheDetail() {
        var navigation = LibraryNavigation()
        navigation.open(a)
        let wasOpen = navigation.removed(a)
        #expect(wasOpen)
        #expect(navigation.selection == nil)
    }

    @Test func deletingAnotherScriptLeavesTheDetailAlone() {
        var navigation = LibraryNavigation()
        navigation.open(a)
        let wasOpen = navigation.removed(b)
        #expect(!wasOpen)
        #expect(navigation.selection == a)
    }

    @Test func undoReopensTheScriptOnlyIfItWasOpenAndNothingElseIs() {
        var navigation = LibraryNavigation()
        navigation.open(a)
        let wasOpen = navigation.removed(a)
        navigation.restored(a, wasOpen: wasOpen)
        #expect(navigation.selection == a)

        // The user opened something else after the delete: Undo must not pull them away from it.
        navigation.removed(a)
        navigation.open(b)
        navigation.restored(a, wasOpen: true)
        #expect(navigation.selection == b)

        // The deleted script was not the open one: Undo only puts it back in the list.
        navigation.restored(a, wasOpen: false)
        #expect(navigation.selection == b)
    }
}

/// When a blank new script the person left is dropped: once the library has closed it and no editor shows it.
struct EditorPresenceTests {
    private let a = UUID()
    private let b = UUID()

    /// A back button tap: the library closes the script first, the editor goes away at the end of the slide.
    @Test func backButtonDropsWhenTheEditorGoes() {
        var presence = EditorPresence()
        presence.editorAppeared(a)
        #expect(!presence.scriptClosed(a))   // still sliding away: no "Script deleted" flash
        let left = presence.editorDisappeared(a, isOpen: false)
        #expect(left)
    }

    /// The finding: a swipe back may end with the editor gone before the stack's path changes. The library drops it then.
    @Test func swipeBackDropsWhenTheLibraryCloses() {
        var presence = EditorPresence()
        presence.editorAppeared(a)
        let leftByEditor = presence.editorDisappeared(a, isOpen: true)
        #expect(!leftByEditor)
        #expect(presence.scriptClosed(a))
    }

    /// The iPhone Duo folding or unfolding: one layout's editor goes, the other's comes, the script stays open.
    @Test func aLayoutSwitchNeverDrops() {
        var presence = EditorPresence()
        presence.editorAppeared(a)
        presence.editorAppeared(a)   // the new layout's editor
        let leftAfterOverlap = presence.editorDisappeared(a, isOpen: true)
        #expect(!leftAfterOverlap)
        // The other order: the old editor goes before the new one comes.
        let leftBeforeNew = presence.editorDisappeared(a, isOpen: true)
        #expect(!leftBeforeNew)
        presence.editorAppeared(a)
        #expect(!presence.scriptClosed(a))
    }

    /// After a switch two editors of the script can be on screen for a moment; closing it waits for the last one.
    @Test func closingDuringASwitchWaitsForTheLastEditor() {
        var presence = EditorPresence()
        presence.editorAppeared(a)
        presence.editorAppeared(a)
        #expect(!presence.scriptClosed(a))
        let leftByFirst = presence.editorDisappeared(a, isOpen: false)
        #expect(!leftByFirst)
        let leftByLast = presence.editorDisappeared(a, isOpen: false)
        #expect(leftByLast)
    }

    /// Picking another script in the split view: the old editor is replaced by the new one.
    @Test func pickingAnotherScriptDropsTheOldOneOnce() {
        var presence = EditorPresence()
        presence.editorAppeared(a)
        #expect(!presence.scriptClosed(a))
        presence.editorAppeared(b)
        let left = presence.editorDisappeared(a, isOpen: false)
        #expect(left)
        #expect(!presence.scriptClosed(b))
    }

    /// The full-screen prompter covers the editor and uncovers it again: nothing is dropped while the script is open.
    @Test func thePrompterCoveringTheEditorNeverDrops() {
        var presence = EditorPresence()
        presence.editorAppeared(a)
        let left = presence.editorDisappeared(a, isOpen: true)
        #expect(!left)
        presence.editorAppeared(a)
        #expect(!presence.scriptClosed(a))
    }

    @Test func anExtraDisappearanceDoesNotGoBelowNone() {
        var presence = EditorPresence()
        let left = presence.editorDisappeared(a, isOpen: false)
        #expect(left)
        presence.editorAppeared(a)
        #expect(!presence.scriptClosed(a))
    }
}
