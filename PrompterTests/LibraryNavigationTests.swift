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
