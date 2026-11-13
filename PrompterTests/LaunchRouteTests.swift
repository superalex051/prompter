import Foundation
import Testing
@testable import Prompter

struct LaunchRouteTests {
    private let newest = Script(title: "Newest", body: "Words")
    private let sample = SampleScript.make(now: Date(timeIntervalSince1970: 1_800_000_000))
    private var library: [Script] { [newest, sample] }

    /// The regression: the library's first appearance came while the store was still waiting for protected data, with no
    /// scripts. That call must not use the route up; the call after loading opens the prompter.
    @Test func thePrompterRouteWaitsForTheLibraryToLoad() {
        var route = LaunchRoute(route: .prompter)
        #expect(route.next(isLoading: true, scripts: []) == nil)
        #expect(!route.isDone)
        #expect(route.next(isLoading: true, scripts: []) == nil)

        #expect(route.next(isLoading: false, scripts: library) == .openPrompter(newest.id, autoStart: false))
        #expect(route.isDone)
        // Once only: the library reappearing after the prompter closes opens nothing.
        #expect(route.next(isLoading: false, scripts: library) == nil)
    }

    @Test func aLibraryThatIsAlreadyLoadedOpensAtOnce() {
        var route = LaunchRoute(route: .prompter, autoStart: true)
        #expect(route.next(isLoading: false, scripts: library) == .openPrompter(newest.id, autoStart: true))
    }

    @Test func eachRouteOpensItsScreen() {
        var editor = LaunchRoute(route: .editor)
        #expect(editor.next(isLoading: false, scripts: library) == .openEditor(newest.id))
        var prompterSettings = LaunchRoute(route: .prompterSettings)
        #expect(prompterSettings.next(isLoading: false, scripts: library) == .openPrompterSettings(newest.id))
        var settings = LaunchRoute(route: .settings)
        #expect(settings.next(isLoading: true, scripts: []) == nil, "settings wait for the stores too")
        #expect(settings.next(isLoading: false, scripts: []) == .openSettings)
        var stay = LaunchRoute(route: .library)
        #expect(stay.next(isLoading: false, scripts: library) == nil)
        #expect(stay.isDone)
    }

    @Test func theSampleChoiceFallsBackToTheNewest() {
        var withSample = LaunchRoute(route: .editor, script: .sample)
        #expect(withSample.next(isLoading: false, scripts: library) == .openEditor(SampleScript.id))
        var sampleDeleted = LaunchRoute(route: .editor, script: .sample)
        #expect(sampleDeleted.next(isLoading: false, scripts: [newest]) == .openEditor(newest.id))
    }

    /// A library that loaded empty has nothing to open; the route is used up rather than firing on a later new script.
    @Test func anEmptyLibraryAfterLoadingUsesTheRouteUp() {
        var route = LaunchRoute(route: .prompter)
        #expect(route.next(isLoading: false, scripts: []) == nil)
        #expect(route.isDone)
        #expect(route.next(isLoading: false, scripts: library) == nil)
    }
}

extension LaunchRouteTests {
    @Test func theSyncSettingsRouteOpensSyncWithMac() {
        #expect(LaunchOptions(arguments: ["-route", "syncSettings"]).route == .syncSettings)
        var route = LaunchRoute(route: .syncSettings)
        #expect(route.next(isLoading: true, scripts: []) == nil)
        #expect(route.next(isLoading: false, scripts: []) == .openSyncSettings)
        #expect(route.next(isLoading: false, scripts: []) == nil)
    }
}
