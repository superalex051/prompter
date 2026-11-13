import Testing
@testable import Prompter

struct TimeFormattingTests {
    @Test(arguments: [
        (0.0, "0:00"),
        (59.4, "0:59"),
        (59.5, "1:00"),
        (176, "2:56"),
        (3600, "1:00:00"),
        (3725, "1:02:05"),
        (36_000, "10:00:00"),
    ])
    func clock(seconds: Double, expected: String) {
        #expect(TimeFormatting.clock(seconds) == expected)
    }

    @Test(arguments: [-5, Double.nan, .infinity, -.infinity])
    func invalidValuesShowZero(seconds: Double) {
        #expect(TimeFormatting.clock(seconds) == "0:00")
    }

    @Test func hugeFiniteValuesDoNotCrash() {
        #expect(!TimeFormatting.clock(.greatestFiniteMagnitude).isEmpty)
    }
}
