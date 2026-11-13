import Foundation
import Testing
import UIKit
@testable import Prompter

@MainActor
final class SettingsStoreTests {
    let suiteName = "test-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    @Test func defaultsWhenEmpty() {
        #expect(SettingsStore(defaults: defaults).settings == PrompterSettings())
    }

    @Test func changesPersistToANewStore() {
        let store = SettingsStore(defaults: defaults)
        store.settings.fontSize = 96
        store.settings.mirrorHorizontal = false
        store.settings.scrollMode = .speed

        var expected = PrompterSettings()
        expected.fontSize = 96
        expected.mirrorHorizontal = false
        expected.scrollMode = .speed
        #expect(store.settings == expected)
        #expect(SettingsStore(defaults: defaults).settings == expected)
    }

    @Test func assignmentsAreClamped() {
        let store = SettingsStore(defaults: defaults)
        store.settings.fontSize = 999
        store.settings.countdownSeconds = 7
        #expect(store.settings.fontSize == 200)
        #expect(store.settings.countdownSeconds == 5)
        #expect(SettingsStore(defaults: defaults).settings.fontSize == 200)
    }

    @Test func resetRestoresDefaults() {
        let store = SettingsStore(defaults: defaults)
        store.settings.wordsPerMinute = 180
        store.reset()
        #expect(store.settings == PrompterSettings())
        #expect(SettingsStore(defaults: defaults).settings == PrompterSettings())
    }

    @Test func corruptDataFallsBackToDefaults() {
        defaults.set(Data("garbage".utf8), forKey: "prompterSettings")
        #expect(SettingsStore(defaults: defaults).settings == PrompterSettings())

        defaults.set("not data at all", forKey: "prompterSettings")
        #expect(SettingsStore(defaults: defaults).settings == PrompterSettings())
    }

    @Test func usesTheGivenKey() {
        let store = SettingsStore(defaults: defaults, key: "otherKey")
        store.settings.fontSize = 120
        #expect(defaults.data(forKey: "otherKey") != nil)
        #expect(defaults.data(forKey: "prompterSettings") == nil)
        #expect(SettingsStore(defaults: defaults, key: "otherKey").settings.fontSize == 120)
    }

    // MARK: Before the first unlock

    /// What a store made while `isProtectedDataAvailable` reads false gets: before the first unlock after a restart, but
    /// also (seen on the simulator) during `App.init` on a perfectly normal launch.
    private func makeLockedStore(center: NotificationCenter) -> SettingsStore {
        SettingsStore(defaults: defaults, isProtectedDataAvailable: false, notificationCenter: center)
    }

    /// The saved settings becoming readable at the first unlock, simulated: before it `UserDefaults` has nothing.
    private func unlock(revealing settings: PrompterSettings) throws {
        defaults.set(try JSONEncoder().encode(settings), forKey: "prompterSettings")
    }

    /// The regression: the flag read false in `App.init` on a normal launch. Settings that can be read are used at once.
    @Test func readableSettingsLoadAtOnceEvenIfTheFlagSaysLocked() {
        let saved = SettingsStore(defaults: defaults)
        saved.settings.fontSize = 120
        saved.settings.scrollMode = .speed

        let center = NotificationCenter()
        let store = makeLockedStore(center: center)
        #expect(!store.isWaitingForProtectedData)
        #expect(store.settings == saved.settings)

        // Changes save as usual, and a later notice changes nothing.
        store.settings.fontSize = 96
        center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        #expect(store.settings.fontSize == 96)
        #expect(SettingsStore(defaults: defaults).settings.fontSize == 96)
    }

    @Test func nothingSavedWithTheFlagSayingUnlockedIsNotAWait() {
        let store = SettingsStore(defaults: defaults, isProtectedDataAvailable: true, notificationCenter: NotificationCenter())
        #expect(!store.isWaitingForProtectedData)
        #expect(store.settings == PrompterSettings())
    }

    /// Launched by the watch before the first unlock after a restart: `UserDefaults` has nothing yet. The store holds the
    /// defaults and saves nothing (a first change used to overwrite the real settings with defaults), then reads the saved
    /// settings once protected data becomes available; they win over anything changed meanwhile.
    @Test func beforeTheFirstUnlockNothingIsSavedOverTheRealSettings() throws {
        var expected = PrompterSettings()
        expected.fontSize = 120
        expected.scrollMode = .speed

        let center = NotificationCenter()
        let store = makeLockedStore(center: center)
        #expect(store.isWaitingForProtectedData)
        #expect(store.settings == PrompterSettings())
        store.settings.wordsPerMinute = 200
        #expect(defaults.object(forKey: "prompterSettings") == nil, "nothing is saved before the settings were read")

        try unlock(revealing: expected)
        center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        #expect(!store.isWaitingForProtectedData)
        #expect(store.settings == expected)

        // From here on changes save as usual.
        store.settings.fontSize = 96
        #expect(SettingsStore(defaults: defaults).settings.fontSize == 96)
        #expect(SettingsStore(defaults: defaults).settings.scrollMode == .speed)
    }

    /// Nothing turned up after the unlock either: there was nothing to protect, so a change made while waiting (such as
    /// `-scrollMode voice` at a demo launch) is kept and saved instead of being reset to the defaults.
    @Test func whenNothingWasSavedTheChangesMadeWhileWaitingAreKept() {
        let center = NotificationCenter()
        let store = makeLockedStore(center: center)
        #expect(store.isWaitingForProtectedData)
        store.settings.scrollMode = .voice
        #expect(defaults.object(forKey: "prompterSettings") == nil)

        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(!store.isWaitingForProtectedData)
        #expect(store.settings.scrollMode == .voice)
        #expect(SettingsStore(defaults: defaults).settings.scrollMode == .voice)
    }

    @Test func becomingActiveAlsoReadsWaitingSettings() throws {
        let center = NotificationCenter()
        let store = makeLockedStore(center: center)
        #expect(store.isWaitingForProtectedData)
        var saved = PrompterSettings()
        saved.fontSize = 150
        try unlock(revealing: saved)
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(store.settings.fontSize == 150)
        // Already read: a later notice changes nothing.
        store.settings.fontSize = 100
        store.protectedDataBecameAvailable()
        #expect(store.settings.fontSize == 100)
    }
}
