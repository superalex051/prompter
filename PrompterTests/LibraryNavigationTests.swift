import Foundation
import Testing
@testable import Prompter

struct LibraryNavigationTests {
    private let a = UUID()
    private let b = UUID()

    @Test func compactWidthPushesOntoThePath() {
        var navigation = LibraryNavigation()
        navigation.open(a, isRegular: false)
        #expect(navigation.path == [a])
        #expect(navigation.selection == nil)
    }

    @Test func regularWidthSelectsInTheDetailAndReplacesThePreviousScript() {
        var navigation = LibraryNavigation()
        navigation.open(a, isRegular: true)
        navigation.open(b, isRegular: true)
        #expect(navigation.selection == b)
        #expect(navigation.path.isEmpty)
    }

    @Test func turningRegularCarriesThePushedScriptIntoTheDetail() {
        var navigation = LibraryNavigation()
        navigation.open(a, isRegular: false)
        navigation.widthClassChanged(isRegular: true)
        #expect(navigation.selection == a)
        #expect(navigation.path.isEmpty)
    }

    @Test func turningCompactPushesTheSelectedScript() {
        var navigation = LibraryNavigation()
        navigation.open(a, isRegular: true)
        navigation.widthClassChanged(isRegular: false)
        #expect(navigation.path == [a])
        #expect(navigation.selection == nil)
    }

    @Test func changingWidthWithNothingOpenStaysEmpty() {
        var navigation = LibraryNavigation()
        navigation.widthClassChanged(isRegular: true)
        #expect(navigation == LibraryNavigation())
        navigation.widthClassChanged(isRegular: false)
        #expect(navigation == LibraryNavigation())
    }

    @Test func deletingTheOpenScriptClearsTheDetail() {
        var navigation = LibraryNavigation()
        navigation.open(a, isRegular: true)
        let wasOpen = navigation.removed(a)
        #expect(wasOpen)
        #expect(navigation.selection == nil)
    }

    @Test func deletingAnotherScriptLeavesTheDetailAlone() {
        var navigation = LibraryNavigation()
        navigation.open(a, isRegular: true)
        let wasOpen = navigation.removed(b)
        #expect(!wasOpen)
        #expect(navigation.selection == a)
    }

    @Test func undoReopensTheScriptOnlyIfItWasOpenAndNothingElseIs() {
        var navigation = LibraryNavigation()
        navigation.open(a, isRegular: true)
        let wasOpen = navigation.removed(a)
        navigation.restored(a, wasOpen: wasOpen)
        #expect(navigation.selection == a)

        // The user opened something else after the delete: Undo must not pull them away from it.
        navigation.removed(a)
        navigation.open(b, isRegular: true)
        navigation.restored(a, wasOpen: true)
        #expect(navigation.selection == b)

        // The deleted script was not the open one: Undo only puts it back in the list.
        navigation.restored(a, wasOpen: false)
        #expect(navigation.selection == b)
    }
}
