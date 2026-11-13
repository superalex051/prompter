import Testing
@testable import Prompter

struct ReadingStatsTests {
    @Test(arguments: [
        ("", 0),
        ("Hello,   world!\n\nAgain", 3),
        ("— - •", 0),
        ("e-mail 2026 rock'n'roll", 3),
        ("Tabs\tand\u{00A0}non-breaking spaces", 4),
        ("  leading and trailing  ", 3),
    ])
    func wordCount(text: String, expected: Int) {
        #expect(ReadingStats.wordCount(of: text) == expected)
        #expect(ReadingStats(text: text).wordCount == expected)
    }

    @Test func readingSecondsAtWPM() {
        let text = Array(repeating: "word", count: 140).joined(separator: " ")
        let stats = ReadingStats(text: text)
        #expect(stats.wordCount == 140)
        #expect(stats.readingSeconds(atWPM: 140) == 60)
        #expect(stats.readingSeconds(atWPM: 70) == 120)
    }

    @Test(arguments: [0, -140, Double.nan, .infinity])
    func invalidWPMReadsInZeroSeconds(wpm: Double) {
        #expect(ReadingStats(text: "some words here").readingSeconds(atWPM: wpm) == 0)
    }
}
