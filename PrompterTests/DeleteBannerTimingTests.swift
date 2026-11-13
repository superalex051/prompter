import Testing
@testable import Prompter

struct DeleteBannerTimingTests {
    @Test func hidesAfterSixSecondsWithoutVoiceOver() {
        #expect(DeleteBannerTiming.autoHideDelay(voiceOverEnabled: false) == .seconds(6))
    }

    @Test func staysUpWithVoiceOverSoUndoCanBeReached() {
        #expect(DeleteBannerTiming.autoHideDelay(voiceOverEnabled: true) == nil)
    }
}
