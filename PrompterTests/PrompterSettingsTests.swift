import Foundation
import Testing
@testable import Prompter

struct PrompterSettingsTests {
    private func decode(_ json: String) throws -> PrompterSettings {
        try JSONDecoder().decode(PrompterSettings.self, from: Data(json.utf8))
    }

    @Test func defaultsMatchTheSpec() {
        let settings = PrompterSettings()
        #expect(settings.mirrorHorizontal)
        #expect(!settings.flipVertical)
        #expect(settings.rotation == PrompterSettings.Rotation.none)
        #expect(settings.lockLandscape)
        #expect(settings.fontSize == 72)
        #expect(settings.fontWeight == .heavy)
        #expect(settings.lineSpacing == 1.6)
        #expect(settings.sideMargin == 0.06)
        #expect(settings.scheme == .whiteOnBlack)
        #expect(settings.readingLinePosition == 1.0 / 3.0)
        #expect(settings.dimmedOpacity == 0.35)
        #expect(settings.countdownSeconds == 5)
        #expect(settings.countdownBeep)
        #expect(settings.scrollMode == .wpm)
        #expect(settings.wordsPerMinute == 140)
        #expect(settings.clamped() == settings)
    }

    @Test func roundTrip() throws {
        var settings = PrompterSettings()
        settings.mirrorHorizontal = false
        settings.flipVertical = true
        settings.rotation = .threeQuarters
        settings.lockLandscape = false
        settings.fontSize = 96
        settings.fontWeight = .black
        settings.scheme = .yellowOnBlack
        settings.countdownSeconds = 10
        settings.countdownBeep = false
        settings.scrollMode = .finishIn
        settings.speedLevel = 4.2
        settings.finishInSeconds = 600

        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(PrompterSettings.self, from: data) == settings)
    }

    @Test func decodesEmptyObjectToDefaults() throws {
        #expect(try decode("{}") == PrompterSettings())
    }

    @Test func missingKeysKeepTheirDefaults() throws {
        let settings = try decode(#"{"fontSize": 90, "mirrorHorizontal": false}"#)
        var expected = PrompterSettings()
        expected.fontSize = 90
        expected.mirrorHorizontal = false
        #expect(settings == expected)
    }

    @Test func lockLandscapeDefaultsToOnWhenTheKeyIsMissing() throws {
        // Settings saved before the key existed (M1 builds) must come back with the landscape lock on.
        #expect(try decode(#"{"fontSize": 90, "mirrorHorizontal": false}"#).lockLandscape)
        #expect(try decode("{}").lockLandscape)
    }

    @Test func lockLandscapeIsDecodedWhenPresent() throws {
        #expect(try decode(#"{"lockLandscape": false}"#).lockLandscape == false)
        #expect(try decode(#"{"lockLandscape": true}"#).lockLandscape)
        // A value of the wrong type keeps the default instead of failing the decode.
        #expect(try decode(#"{"lockLandscape": "no", "fontSize": 80}"#).lockLandscape)
    }

    @Test func ignoresUnknownKeys() throws {
        let settings = try decode(#"{"fontSize": 90, "futureFeature": {"enabled": true}, "voiceFollow": 1}"#)
        var expected = PrompterSettings()
        expected.fontSize = 90
        #expect(settings == expected)
    }

    @Test func clampsOutOfRangeValues() throws {
        let settings = try decode(#"""
        {"fontSize": 999, "countdownSeconds": 7, "speedLevel": 0, "lineSpacing": 0.2, "sideMargin": -1,
         "readingLinePosition": 5, "dimmedOpacity": 2, "finishInSeconds": 1, "wordsPerMinute": 1000}
        """#)
        #expect(settings.fontSize == 200)
        #expect(settings.countdownSeconds == 5)
        #expect(settings.speedLevel == 1)
        #expect(settings.lineSpacing == 1)
        #expect(settings.sideMargin == 0)
        #expect(settings.readingLinePosition == 0.9)
        #expect(settings.dimmedOpacity == 1)
        #expect(settings.finishInSeconds == 10)
        #expect(settings.wordsPerMinute == 300)
    }

    @Test func nanBecomesTheDefault() {
        var settings = PrompterSettings()
        settings.wordsPerMinute = .nan
        settings.fontSize = .nan
        settings.speedLevel = .nan
        let clamped = settings.clamped()
        #expect(clamped.wordsPerMinute == 140)
        #expect(clamped.fontSize == 72)
        #expect(clamped.speedLevel == 3)
    }

    @Test(arguments: [(-3, 0), (0, 0), (2, 3), (7, 5), (12, 10), (100, 15), (Int.max, 15), (Int.min, 0)])
    func countdownSnapsToNearestOption(seconds: Int, expected: Int) {
        var settings = PrompterSettings()
        settings.countdownSeconds = seconds
        #expect(settings.clamped().countdownSeconds == expected)
    }

    @Test func unknownEnumValuesFallBackToDefaults() throws {
        let settings = try decode(#"{"scheme": "purple", "rotation": 45, "fontWeight": "ultra", "scrollMode": "teleport", "fontSize": 80}"#)
        var expected = PrompterSettings()
        expected.fontSize = 80
        #expect(settings == expected)
    }

    @Test func voiceModeDecodesAndRoundTrips() throws {
        let settings = try decode(#"{"scrollMode": "voice", "wordsPerMinute": 150}"#)
        #expect(settings.scrollMode == .voice)
        #expect(settings.wordsPerMinute == 150)
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(PrompterSettings.self, from: data) == settings)
    }

    /// Settings saved by the build before voice mode existed still decode exactly.
    @Test func settingsFromBeforeVoiceModeStayValid() throws {
        let old = try decode(#"{"scrollMode": "finishIn", "finishInSeconds": 240, "countdownSeconds": 10, "mirrorHorizontal": true}"#)
        #expect(old.scrollMode == .finishIn)
        #expect(old.finishInSeconds == 240)
        #expect(old.countdownSeconds == 10)
        #expect(PrompterSettings.ScrollMode.allCases == [.speed, .finishIn, .wpm, .voice])
    }

    @Test func wrongTypesFallBackToDefaults() throws {
        let settings = try decode(#"{"fontSize": "huge", "mirrorHorizontal": "yes", "countdownSeconds": 2.5}"#)
        #expect(settings == PrompterSettings())
    }
}
