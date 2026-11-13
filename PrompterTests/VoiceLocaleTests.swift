import Foundation
import Testing
@testable import Prompter

/// Which language voice-follow listens in, and which script words it primes the recogniser with.
struct VoiceLocaleTests {
    static let english = """
        Hey, welcome back. Today I'm showing you the setup I use to talk straight down the lens without memorizing a
        single line. It's simpler than it looks.
        """

    @Test func listensInTheScriptsLanguageWithTheDevicesRegion() {
        let romanian = Locale(identifier: "ro_RO")
        #expect(VoiceLocale.preferred(forScript: Self.english, current: romanian).identifier == "en_RO")
        #expect(VoiceLocale.preferred(forScript: Self.english, current: Locale(identifier: "en_GB")).identifier == "en_GB")
        // Too little text to tell: the device's own locale.
        #expect(VoiceLocale.preferred(forScript: "", current: romanian).identifier == "ro_RO")
    }

    @Test func bestSupportedLocale() {
        let supported = ["en_US", "en_GB", "en_AU", "fr_FR", "fr_CA", "de_DE"].map(Locale.init(identifier:))
        func best(_ id: String) -> String? { VoiceLocale.best(for: Locale(identifier: id), among: supported)?.identifier }
        #expect(best("en_GB") == "en_GB")            // exact
        #expect(best("en-GB") == "en_GB")            // either spelling
        #expect(best("en_RO") == "en_US")            // no Romanian English: the main variant
        #expect(best("fr_BE") == "fr_FR")
        #expect(best("de_AT") == "de_DE")
        #expect(best("ro_RO") == nil)                // nobody speaks it here
    }

    @Test func vocabularyIsTheScriptsLongerWordsOnce() {
        let document = PrompterDocument(body: "// not this note\nThe acrylic, the ACRYLIC and a camera.\n[pause 2]\nReflection!")
        let words = VoiceVocabulary.words(in: document)
        #expect(words == ["Reflection", "acrylic", "camera"])
        #expect(VoiceVocabulary.words(in: document, limit: 1) == ["Reflection"])
    }

    @Test func problemsSayWhatHappensInstead() {
        let all: [VoiceProblem] = [.microphoneDenied, .speechDenied, .unsupported, .modelUnavailable, .failed]
        for problem in all {
            #expect(problem.message.hasSuffix("Scrolling at your set pace instead."))
        }
        #expect(VoiceProblem.microphoneDenied.opensSettings)
        #expect(VoiceProblem.speechDenied.opensSettings)
        #expect(!VoiceProblem.unsupported.opensSettings)
        #expect(VoiceProblem.microphoneDenied.message == "Voice needs microphone access. Scrolling at your set pace instead.")
    }
}
