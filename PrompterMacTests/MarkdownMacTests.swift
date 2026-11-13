import AppKit
import SwiftUI
import Testing
@testable import PrompterMac

/// Markdown on the Mac: the editor's live highlighting, the library's stats and tip, import, and the presenting session.
struct MarkdownMacLibraryTests {
    @Test func highlightFindsMarkdownAlongsideNotesAndCues() {
        let body = "# Intro\nSay **this**.\n// a note\n[pause 2]\n---\n- *one*"
        let all = ScriptHighlight.spans(in: body, markdown: true)
        let text = body as NSString
        func spans(_ kind: ScriptHighlight.Kind) -> [String] {
            all.filter { $0.kind == kind }.map { text.substring(with: $0.range) }
        }
        #expect(spans(.heading(level: 1)) == ["# Intro"])
        #expect(spans(.note) == ["// a note"])
        #expect(spans(.pause) == ["[pause 2]"])
        #expect(spans(.rule) == ["---"])
        #expect(spans(.styled(.bold)) == ["this"])
        #expect(spans(.styled(.italic)) == ["one"])
        #expect(spans(.marker) == ["# ", "**", "**", "- ", "*", "*"])
        // Off: only notes and cues, as before.
        #expect(ScriptHighlight.spans(in: body).map(\.kind) == [.note, .pause])
    }

    @Test func statsAndTipFollowTheSetting() {
        let body = "# A heading of five words\nSay **this** now."
        #expect(MacScriptStats.summary(ofBody: body, wordsPerMinute: 60) == "8 words · 0:08")
        #expect(MacScriptStats.summary(ofBody: body, wordsPerMinute: 60, markdown: true) == "3 words · 0:03")
        #expect(MacScriptStats.footer(ofBody: body, wordsPerMinute: 60, markdown: true) == "3 words · 0:03 at 60 wpm")
        #expect(MacEditorTip.text(markdown: false) == MacEditorTip.text)
        #expect(MacEditorTip.text(markdown: true).hasSuffix("Markdown works too: **bold** shows in amber, # starts a heading."))
    }

    @Test func acceptsMarkdownFiles() {
        for name in ["notes.md", "talk.markdown", "old.mdown", "LOUD.MD"] {
            #expect(ImportableFiles.accepts(URL(filePath: "/tmp/\(name)")), "\(name)")
        }
    }

    @Test func presenterLaunchPicksTheMarkdownDemo() {
        #expect(PresenterLaunchOptions(arguments: ["Prompter", "-script", "markdown"]).script == .markdown)
    }
}

/// The editor shows the Markdown live, and switching the setting re-highlights without touching the text.
@MainActor
struct MarkdownEditorHighlightTests {
    private final class TextBox {
        var text: String
        init(_ text: String) { self.text = text }
    }

    @Test func boldIsAmberHeadingsAreBiggerAndMarkersDimmed() throws {
        let box = TextBox("# Title\nSay **this** and *that*.")
        var editor = ScriptTextEditor(text: Binding(get: { box.text }, set: { box.text = $0 }), margin: 20, markdown: true)
        let coordinator = editor.makeCoordinator()
        let scrollView = editor.makeScrollView(coordinator: coordinator)
        let textView = try #require(scrollView.documentView as? ScriptNSTextView)
        let storage = try #require(textView.textStorage)
        let text = storage.string as NSString
        let accent = NSColor(named: "AccentColor") ?? .controlAccentColor
        func color(at word: String) -> NSColor? {
            storage.attribute(.foregroundColor, at: text.range(of: word).location, effectiveRange: nil) as? NSColor
        }
        func font(at word: String) -> NSFont? {
            storage.attribute(.font, at: text.range(of: word).location, effectiveRange: nil) as? NSFont
        }
        #expect(color(at: "this") == accent)
        #expect(font(at: "this")?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(font(at: "that")?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        #expect(color(at: "Title") == accent)
        #expect((font(at: "Title")?.pointSize ?? 0) > (font(at: "Say")?.pointSize ?? 0))
        #expect(color(at: "**") == .tertiaryLabelColor)
        #expect(color(at: "# ") == .tertiaryLabelColor)
        #expect(color(at: "Say") == .labelColor)

        // Off: plain text again (notes and cues would still be coloured), the text itself unchanged.
        editor.markdown = false
        editor.update(scrollView, coordinator: coordinator)
        #expect(color(at: "this") == .labelColor)
        #expect(font(at: "Title")?.pointSize == font(at: "Say")?.pointSize)
        #expect(storage.string == box.text)
    }
}

/// Presenting a Markdown script, and switching Markdown formatting from the Presenter view's settings.
@MainActor
struct MarkdownPresenterTests {
    @Test func sessionShowsMarkdownAndFollowsTheSwitch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MarkdownPresenter-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "MarkdownPresenter-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        let scriptStore = ScriptStore(directory: directory, initialScripts: { _ in [] })
        let script = scriptStore.create(title: "MD", body: DemoData.markdownBody)
        let settingsStore = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        let session = PresenterSession(
            scriptID: script.id, scriptStore: scriptStore, settingsStore: settingsStore,
            outputScreenSize: CGSize(width: 1920, height: 1080)
        )
        session.isMuted = true
        defer { session.close() }

        #expect(session.document == PrompterDocument(body: DemoData.markdownBody, markdown: true))
        #expect(session.document.text.hasPrefix("Cold open\nMost people freeze"))

        settingsStore.settings.markdown = false
        // The session hears about settings changes on the next main-actor turn.
        for _ in 0..<50 where session.document.text.hasPrefix("Cold open") {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(session.document == PrompterDocument(body: DemoData.markdownBody))
        #expect(session.document.text.hasPrefix("# Cold open"))
    }
}
