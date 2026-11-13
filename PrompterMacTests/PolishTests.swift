import CoreGraphics
import Foundation
import Testing
@testable import PrompterMac

// M8 polish: the words and thresholds the Mac UI computes (the views themselves are checked in the screenshots).

struct SyncSettingsCopyTests {
    @Test func aFailedListenerAlwaysWarnsAboutLocalNetwork() {
        #expect(MacSyncStatusText.warnsAboutLocalNetwork(.failed("denied"), startedLongAgo: false))
        #expect(MacSyncStatusText.warnsAboutLocalNetwork(.failed("denied"), startedLongAgo: true))
    }

    @Test func aStartingListenerWarnsOnlyOnceItHasTakenTooLong() {
        #expect(!MacSyncStatusText.warnsAboutLocalNetwork(.starting, startedLongAgo: false))
        #expect(MacSyncStatusText.warnsAboutLocalNetwork(.starting, startedLongAgo: true))
    }

    @Test func aWorkingOrIdleListenerNeverWarns() {
        #expect(!MacSyncStatusText.warnsAboutLocalNetwork(.off, startedLongAgo: true))
        #expect(!MacSyncStatusText.warnsAboutLocalNetwork(.advertising(port: 5000), startedLongAgo: true))
    }

    @Test func theLocalNetworkHintNamesTheSettingsPathAndOpensThePrivacyPane() {
        #expect(MacSyncStatusText.localNetworkWarning.contains("System Settings → Privacy & Security → Local Network"))
        #expect(MacSyncStatusText.localNetworkSettingsURL.absoluteString.hasSuffix("Privacy_LocalNetwork"))
    }

    @Test func pairedIsGoodNewsAndEverythingElseIsAFailure() {
        #expect(!MacSyncStatusText.isPairingFailure("Paired with Sam's iPhone."))
        #expect(MacSyncStatusText.isPairingFailure("The code expired. Click Pair an iPhone to get a new one."))
        #expect(MacSyncStatusText.isPairingFailure("Too many wrong codes. Click Pair an iPhone to try again."))
    }

    @MainActor @Test func clearingThePairingMessageEmptiesIt() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "PolishTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = SyncHost(
            library: ScriptStore(directory: directory), pairing: PairingStore(directory: directory), name: "Mac",
            advertises: false
        )
        host.beginPairing()
        host.cancelPairing(message: "The code expired. Click Pair an iPhone to get a new one.")
        #expect(host.pairingMessage != nil)
        host.clearPairingMessage()
        #expect(host.pairingMessage == nil)
    }
}

struct PresenterPolishTests {
    @Test func startPromptAsksForSpaceOrStartOnlyWhileNothingRuns() {
        #expect(PresenterStatus.startPrompt(for: .idle) == "Press Space or click Start")
        #expect(PresenterStatus.startPrompt(for: .finished) == "Press Space or click Restart")
        #expect(PresenterStatus.startPrompt(for: .playing) == nil)
        #expect(PresenterStatus.startPrompt(for: .paused) == nil)
        #expect(PresenterStatus.startPrompt(for: .countdown(3)) == nil)
    }

    @Test func aMacBookGetsTheWideLayoutAndTheCompactOneWithSettingsOpen() {
        // 14" MacBook Pro: 1512 pt wide; 13" MacBook Air: 1470 pt. The wide layout needs about 1420 pt (1830 with the
        // settings panel beside it), so below that the compact layout takes over rather than overflow the window.
        #expect(PresenterView.isWide(width: 1512, settingsOpen: false))
        #expect(PresenterView.isWide(width: 1470, settingsOpen: false))
        #expect(!PresenterView.isWide(width: 1280, settingsOpen: false))
        #expect(!PresenterView.isWide(width: 1512, settingsOpen: true))
        #expect(PresenterView.isWide(width: 2560, settingsOpen: true))
    }

    @Test func theNotchInsetIsTheScreensTopSafeArea() {
        #expect(PresentingController.topInset(safeAreaTop: 38) == 38)
        #expect(PresentingController.topInset(safeAreaTop: 0) == 0)
        #expect(PresentingController.topInset(safeAreaTop: -4) == 0)
    }

    @Test func aScreensResolutionReadsWidthByHeight() {
        let screen = DisplayDescriptor(
            id: 2, name: "27GL850", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), isBuiltIn: false,
            hasMenuBar: false
        )
        #expect(screen.resolutionText == "2560 × 1440")
    }
}
