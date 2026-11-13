import Foundation
import Testing
@testable import Prompter

struct SampleScriptTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func sampleHasAFixedIDAndExplainsTheControls() {
        let sample = SampleScript.make(now: now)
        #expect(sample.id == SampleScript.id)
        #expect(sample.title == "Welcome to Prompter")
        #expect(sample.createdAt == now)
        #expect(sample.updatedAt == now)
        #expect((150...300).contains(ReadingStats.wordCount(of: sample.body)))
        #expect(ScriptImporter.normalize(sample.body) == sample.body)
    }

    /// The library row shows the first line under the title, so it must not say the title again.
    @Test func firstLineDoesNotRepeatTheTitle() {
        let sample = SampleScript.make(now: now)
        #expect(!sample.firstLine.localizedCaseInsensitiveContains("Welcome to Prompter"))
        #expect(sample.firstLine.hasPrefix("This sample script shows how the prompter works."))
    }

    @Test func stepsAndWatchLineSayWhatTheAppDoes() {
        let body = SampleScript.body
        #expect(body.contains("Tap Prompt to open the prompter, then tap the screen to start. After a short countdown the text scrolls up past the reading line, about a third of the way down the screen. Keep your eyes on that line."))
        #expect(body.contains("Wearing an Apple Watch? With the prompter open on your iPhone, open Prompter on your wrist to start, pause and change the speed from across the room. Turn the Digital Crown to change the speed."))
    }

    @Test func usesAmericanSpelling() {
        let body = SampleScript.body.lowercased()
        #expect(body.contains("colors"))
        for british in ["colour", "recognis", "centre", "grey", "way round"] {
            #expect(!body.contains(british), "\(british)")
        }
    }

    @Test func demoDataUsesAmericanSpelling() {
        let text = DemoData.scripts(now: now).map(\.body).joined(separator: "\n").lowercased()
        #expect(text.contains("memorizing"))
        for british in ["memoris", "colour", "recognis", "centre"] {
            #expect(!text.contains(british), "\(british)")
        }
    }

    @Test func demoDataIsTheSamplePlusThreeScripts() {
        let scripts = DemoData.scripts(now: now)
        #expect(scripts.count == 4)
        #expect(scripts.contains { $0.id == SampleScript.id })
        #expect(Set(scripts.map(\.id)).count == 4)
        #expect(Set(scripts.map(\.updatedAt)).count == 4, "edit times are spread out")
        for script in scripts {
            #expect(!script.isBlank)
            #expect(script.updatedAt <= now)
            #expect(script.createdAt <= script.updatedAt)
            #expect(ScriptImporter.normalize(script.body) == script.body)
        }
    }
}

struct SampleScriptMarkupTests {
    /// The sample shows the markup once each: a note, a timed pause, and a sentence saying how.
    @Test func sampleDemonstratesNotesAndPauses() {
        let body = SampleScript.body
        let kinds = ScriptMarkup.lines(of: body).map(\.kind)
        #expect(kinds.filter { $0 == .note }.count == 1)
        #expect(kinds.filter { $0 == .pause(seconds: 2) }.count == 1)
        #expect(kinds.allSatisfy { $0 == .text || $0 == .note || $0 == .pause(seconds: 2) })
        #expect(body.contains("\n// Notes like this one are for you: dimmed and not counted.\n"))
        #expect(body.contains("\n[pause 2]\n"))

        let stats = ReadingStats(text: body)
        #expect(stats.holdSeconds == 2)
        // The note and the cue aren't timed words; the explaining sentence (with its inline // and [pause 2]) is.
        let note = "Notes like this one are for you: dimmed and not counted."
        #expect(stats.wordCount == ReadingStats.wordCount(of: body) - ReadingStats.wordCount(of: note) - 2)
        #expect((150...300).contains(stats.wordCount))
    }

    @Test func samplePromptsTheNoteAndTheCue() {
        let document = PrompterDocument(body: SampleScript.body)
        let note = PrompterDocument.Paragraph(text: "Notes like this one are for you: dimmed and not counted.", kind: .note)
        #expect(document.paragraphs.contains(note))
        #expect(document.paragraphs.contains(.init(text: "PAUSE 2s", kind: .pause(seconds: 2))))
        #expect(document.holds.count == 1)
        #expect(document.paragraphs.last?.text == "That's it. Good luck with your take.")
    }
}
