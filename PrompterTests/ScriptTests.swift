import Foundation
import Testing
@testable import Prompter

struct ScriptTests {
    @Test func displayTitleTrimsAndFallsBackToUntitled() {
        #expect(Script(title: "  Launch day \n", body: "").displayTitle == "Launch day")
        #expect(Script(title: " \n\t ", body: "Body").displayTitle == "Untitled")
        #expect(Script(title: "", body: "").displayTitle == "Untitled")
    }

    @Test func firstLineSkipsLeadingBlankLines() {
        #expect(Script(title: "", body: "\n  \n\t  First words here  \nSecond line").firstLine == "First words here")
        #expect(Script(title: "", body: "Only line").firstLine == "Only line")
        #expect(Script(title: "", body: " \n \n").firstLine == "")
        #expect(Script(title: "", body: "").firstLine == "")
    }

    @Test func isBlankNeedsBothTitleAndBodyEmpty() {
        #expect(Script(title: "", body: "").isBlank)
        #expect(Script(title: "  ", body: "\n\t ").isBlank)
        #expect(!Script(title: "Title", body: "").isBlank)
        #expect(!Script(title: "", body: "Body").isBlank)
    }

    @Test func updatedAtDefaultsToCreatedAt() {
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(Script(title: "", body: "", createdAt: created).updatedAt == created)

        let updated = created.addingTimeInterval(60)
        #expect(Script(title: "", body: "", createdAt: created, updatedAt: updated).updatedAt == updated)
    }

    @Test func codableRoundTrip() throws {
        let script = Script(
            title: "Intro",
            body: "Hello there.\n\nSecond paragraph.",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_060)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(Script.self, from: encoder.encode(script))
        #expect(decoded == script)
    }
}
