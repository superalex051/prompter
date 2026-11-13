import Foundation
import Testing
@testable import Prompter

/// Small pieces of settings and editor copy that are built in code (the rest is plain text in the views).
@MainActor
struct SettingsCopyTests {
    @Test func percentHasNoSpaceBeforeTheSign() {
        #expect(PrompterSettingsSections.percent(0.06) == "6%")
        #expect(PrompterSettingsSections.percent(0.35) == "35%")
        #expect(PrompterSettingsSections.percent(0) == "0%")
        #expect(PrompterSettingsSections.percent(1) == "100%")
    }

    /// The voice footer keeps the problem, what to do about it and the explainer as three paragraphs.
    @Test func voiceFooterSeparatesProblemRemedyAndExplainer() {
        let footer = PrompterSettingsSections.footer(for: .voice, voiceProblem: .microphoneDenied)
        let paragraphs = footer.components(separatedBy: "\n\n")
        #expect(paragraphs.count == 3)
        #expect(paragraphs.first == VoiceProblem.microphoneDenied.message)
        #expect(paragraphs.dropFirst().first == VoiceProblem.microphoneDenied.remedy)
        #expect(paragraphs.last?.hasPrefix("The text follows your voice") == true)
    }

    @Test func voiceFooterWithoutAProblemOrWithoutARemedy() {
        let plain = PrompterSettingsSections.footer(for: .voice)
        #expect(!plain.contains("\n\n"))
        #expect(plain.hasPrefix("The text follows your voice"))

        let noRemedy = PrompterSettingsSections.footer(for: .voice, voiceProblem: .unsupported)
        #expect(noRemedy.components(separatedBy: "\n\n").count == 2)   // no empty paragraph where the remedy would be
    }

    @Test func voiceProblemsSayWhatHappensInPlainWords() {
        let all: [VoiceProblem] = [.microphoneDenied, .speechDenied, .unsupported, .modelUnavailable, .failed]
        for problem in all {
            #expect(!problem.message.contains("WPM"), "\(problem)")
            #expect(problem.message.hasSuffix("Scrolling at your set pace instead."), "\(problem)")
        }
    }
}

struct EditorTipTests {
    @Test func showsWhileTheScriptHasNoNotesOrPauses() {
        #expect(EditorTip.isShown(for: ""))
        #expect(EditorTip.isShown(for: "Hello there.\n\nSecond paragraph."))
        // Markup in the middle of a line is read as written, so it does not count as markup.
        #expect(EditorTip.isShown(for: "See https://example.com // not a note, and [pause 2] is not a cue here."))
    }

    @Test func goesAwayOnceTheScriptHasANoteOrAPause() {
        #expect(!EditorTip.isShown(for: "// remember to smile\nHello there."))
        #expect(!EditorTip.isShown(for: "Hello there.\n[pause 2]\nNext."))
        #expect(!EditorTip.isShown(for: "Hello there.\n[pause]\nNext."))
    }

    @Test func tipTeachesBothMarkups() {
        #expect(EditorTip.text == "Tip: start a line with // for a note, or write [pause 2] to hold.")
        // The tip's own example is markup the app understands.
        #expect(ScriptMarkup.kind(of: "// for a note") == .note)
        #expect(ScriptMarkup.kind(of: "[pause 2]") == .pause(seconds: 2))
    }
}

struct SyncCopyTests {
    @Test func theSettingsRowSaysNotPairedUntilAMacIsPaired() {
        #expect(SyncStatusText.settingsRowValue(macName: nil) == "Not paired")
        #expect(SyncStatusText.settingsRowValue(macName: "Sam's MacBook Pro") == "Sam's MacBook Pro")
    }

    @Test func aRefusedMacSaysSoPlainly() {
        #expect(SyncStatusText.detail(status: .refused, macName: "Studio", lastSyncedAt: nil)
            == "Your Mac no longer recognizes this iPhone. Pair again.")
    }

    @Test func aWrongCodeSaysCodesExpire() {
        let wrong = "That code didn't work. Check the code on your Mac and try again."
        #expect(SyncStatusText.pairingFailure(wrong).hasSuffix("Codes expire after 5 minutes."))
        // Other failures are left alone, and the sentence is never added twice.
        #expect(SyncStatusText.pairingFailure("Couldn't reach Studio.") == "Couldn't reach Studio.")
        let once = SyncStatusText.pairingFailure(wrong)
        #expect(SyncStatusText.pairingFailure(once) == once)
    }

    @Test func theNotSeeingYourMacHintSaysWhereToPair() {
        #expect(SyncStatusText.notSeeingMacHint.contains("Prompter → Settings → iPhone"))
        #expect(SyncStatusText.notSeeingMacHint.contains("Pair an iPhone"))
        #expect(SyncStatusText.notSeeingMacHint.contains("Local Network"))
    }
}
