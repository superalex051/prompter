import AppKit
import Foundation
import SwiftUI
import Testing
@testable import PrompterMac

// The Mac library's logic: import filtering, search, row text, the model's selection / paste / import / delete-with-undo,
// and the debug launch options. (The views only draw this.)

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "PrompterMacLibraryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let locale = Locale(identifier: "en_US")

// MARK: - Pure helpers

struct ImportableFilesTests {
    @Test func acceptsTextRTFAndPDFByExtension() {
        for name in ["a.txt", "b.TXT", "c.rtf", "d.pdf", "e.md", "f.text"] {
            #expect(ImportableFiles.accepts(URL(filePath: "/tmp/\(name)")), "\(name)")
        }
    }

    @Test func rejectsOtherFilesAndNonFileURLs() {
        for name in ["a.png", "b.docx", "c", "d.zip", "e.mov"] {
            #expect(!ImportableFiles.accepts(URL(filePath: "/tmp/\(name)")), "\(name)")
        }
        #expect(!ImportableFiles.accepts(URL(string: "https://example.com/a.txt")!))
    }

    @Test func splitKeepsWhatItCanAndExplainsTheRest() {
        let urls = [URL(filePath: "/tmp/a.txt"), URL(filePath: "/tmp/photo.png"), URL(filePath: "/tmp/b.pdf")]
        let parts = ImportableFiles.split(urls)
        #expect(parts.accepted.map(\.lastPathComponent) == ["a.txt", "b.pdf"])
        #expect(parts.rejected.map(\.filename) == ["photo.png"])
        #expect(parts.rejected.first?.message == "Prompter can import .txt, .md, .rtf and .pdf files.")
    }
}

struct ScriptSearchTests {
    private let scripts = [
        Script(title: "Café intro", body: "Welcome to the show"),
        Script(title: "Testimonial", body: "Thank you for the kind words"),
        Script(title: "Untitled", body: "The rig tour, step one"),
    ]

    @Test func emptyQueryKeepsEverything() {
        #expect(ScriptSearch.filter(scripts, query: "").count == 3)
        #expect(ScriptSearch.filter(scripts, query: "   ").count == 3)
    }

    @Test func matchesTitleOrBodyIgnoringCaseAndAccents() {
        #expect(ScriptSearch.filter(scripts, query: "cafe").map(\.title) == ["Café intro"])
        #expect(ScriptSearch.filter(scripts, query: "KIND").map(\.title) == ["Testimonial"])
        #expect(ScriptSearch.filter(scripts, query: "tour").map(\.title) == ["Untitled"])
    }

    @Test func everyWordMustMatch() {
        #expect(ScriptSearch.filter(scripts, query: "the rig").count == 1)
        #expect(ScriptSearch.filter(scripts, query: "the zebra").isEmpty)
    }
}

struct MacRowTextTests {
    @Test func summaryUsesWordsAndReadTime() {
        let body = Array(repeating: "word", count: 140).joined(separator: " ")
        #expect(MacScriptStats.summary(ofBody: body, wordsPerMinute: 140) == "140 words · 1:00")
        #expect(MacScriptStats.summary(ofBody: "One", wordsPerMinute: 140) == "1 word · 0:00")
        #expect(MacScriptStats.summary(ofBody: "", wordsPerMinute: 140) == "0 words · 0:00")
    }

    @Test func rowDetailSaysWhenItWasEdited() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let body = Array(repeating: "word", count: 140).joined(separator: " ")
        let fiveMinutes = Script(title: "A", body: body, createdAt: now - 3600, updatedAt: now - 300)
        #expect(MacScriptStats.rowDetail(of: fiveMinutes, wordsPerMinute: 140, now: now, locale: locale)
            == "140 words · 1:00 · edited 5 minutes ago")
        let yesterday = Script(title: "A", body: body, createdAt: now - 200_000, updatedAt: now - 86_400)
        #expect(MacScriptStats.rowDetail(of: yesterday, wordsPerMinute: 140, now: now, locale: locale)
            .hasSuffix("edited yesterday"))
    }

    @Test func aScriptSavedJustAheadOfTheClockDoesNotReadAsTheFuture() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let script = Script(title: "A", body: "x", createdAt: now, updatedAt: now + 2)
        let text = MacScriptStats.rowDetail(of: script, wordsPerMinute: 140, now: now, locale: locale)
        #expect(!text.contains("in "))
    }

    @Test func footerShowsThePace() {
        #expect(MacScriptStats.footer(ofBody: "Hello there", wordsPerMinute: 140.4) == "2 words · 0:01 at 140 wpm")
    }

    @Test func tipShowsUntilTheScriptUsesMarkup() {
        #expect(MacEditorTip.isShown(for: "Plain words"))
        #expect(!MacEditorTip.isShown(for: "// note\nWords"))
        #expect(!MacEditorTip.isShown(for: "Words\n[pause 2]"))
    }
}

struct MacEditorLayoutTests {
    @Test func marginCentersTheColumn() {
        #expect(MacEditorLayout.horizontalMargin(forWidth: 1_000) == 140)
        #expect(MacEditorLayout.horizontalMargin(forWidth: 720) == MacEditorLayout.minimumMargin)
        #expect(MacEditorLayout.horizontalMargin(forWidth: 300) == MacEditorLayout.minimumMargin)
        #expect(MacEditorLayout.horizontalMargin(forWidth: .nan) == MacEditorLayout.minimumMargin)
    }

    @Test func highlightFindsNotesAndPauseCues() {
        let body = "Hello\n// a note\n[pause 2]\nBye"
        let spans = ScriptHighlight.spans(in: body)
        #expect(spans.map(\.kind) == [.note, .pause])
        let text = body as NSString
        #expect(text.substring(with: spans[0].range) == "// a note")
        #expect(text.substring(with: spans[1].range) == "[pause 2]")
        #expect(ScriptHighlight.spans(in: "just words").isEmpty)
    }
}

struct LibraryLaunchOptionsTests {
    @Test func parsesTheDebugArguments() {
        let options = LibraryLaunchOptions(arguments: ["Prompter", "-route", "settings", "-settingsTab", "Text", "-emptyLibrary"])
        #expect(options.route == .settings)
        #expect(options.settingsTab == .text)
        #expect(options.emptyLibrary)
    }

    @Test func unknownRoutesAreTheLibrary() {
        #expect(LibraryLaunchOptions(arguments: ["Prompter", "-route", "prompter"]).route == .library)
        #expect(LibraryLaunchOptions(arguments: ["Prompter"]) == LibraryLaunchOptions(arguments: []))
        #expect(LibraryLaunchOptions(arguments: ["Prompter", "-route", "deleted"]).route == .deleted)
    }
}

// MARK: - The model

@MainActor
struct MacLibraryModelTests {
    @MainActor private struct Rig {
        let directory: URL
        let store: ScriptStore
        let model: MacLibraryModel
        let undoManager = UndoManager()
        var presented: Box<[Script.ID]>
        var clipboard: Box<String?>

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    private final class Box<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private func makeRig(scripts: [Script] = []) throws -> Rig {
        let directory = try makeTempDirectory()
        let store = ScriptStore(directory: directory, initialScripts: { _ in scripts })
        let presented = Box<[Script.ID]>([])
        let clipboard = Box<String?>(nil)
        let model = MacLibraryModel(
            store: store,
            present: { presented.value.append($0) },
            pasteboardText: { clipboard.value }
        )
        let rig = Rig(directory: directory, store: store, model: model, presented: presented, clipboard: clipboard)
        model.undoManager = rig.undoManager
        return rig
    }

    private func script(_ title: String, _ body: String, age: TimeInterval = 0) -> Script {
        let date = Date(timeIntervalSince1970: 1_800_000_000 - age)
        return Script(title: title, body: body, createdAt: date, updatedAt: date)
    }

    // New scripts and blank cleanup

    @Test func newScriptOpensABlankOne() throws {
        let rig = try makeRig(scripts: [script("A", "Words")])
        defer { rig.cleanUp() }
        rig.model.newScript()
        let opened = try #require(rig.model.selectedScript)
        #expect(opened.isBlank)
        #expect(rig.store.scripts.count == 2)
    }

    @Test func aBlankScriptIsRemovedWhenSelectionMovesAway() throws {
        let existing = script("A", "Words")
        let rig = try makeRig(scripts: [existing])
        defer { rig.cleanUp() }
        rig.model.newScript()
        let blankID = try #require(rig.model.selection)
        rig.model.select(existing.id)
        #expect(rig.store.script(id: blankID) == nil)
        #expect(rig.store.scripts.map(\.id) == [existing.id])
    }

    @Test func aTypedScriptStaysWhenSelectionMovesAway() throws {
        let existing = script("A", "Words")
        let rig = try makeRig(scripts: [existing])
        defer { rig.cleanUp() }
        rig.model.newScript()
        let id = try #require(rig.model.selection)
        rig.store.update(id, body: "Typed")
        rig.model.select(existing.id)
        #expect(rig.store.script(id: id) != nil)
    }

    @Test func abandoningTheSelectionRemovesABlankScript() throws {
        let rig = try makeRig()
        defer { rig.cleanUp() }
        rig.model.newScript()
        rig.model.abandonSelection()
        #expect(rig.store.scripts.isEmpty)
        #expect(rig.model.selection == nil)
    }

    // Paste

    @Test func pasteMakesAScriptTitledFromTheFirstLine() throws {
        let rig = try makeRig()
        defer { rig.cleanUp() }
        rig.clipboard.value = "Opening lines\n\nFirst we say hello.\nThen we begin."
        rig.model.pasteAsNewScript()
        let pasted = try #require(rig.model.selectedScript)
        #expect(pasted.title == "Opening lines")
        #expect(pasted.body.hasPrefix("Opening lines"))
        #expect(rig.model.notice == nil)
    }

    @Test func pasteWithNothingOnTheClipboardSaysSo() throws {
        let rig = try makeRig()
        defer { rig.cleanUp() }
        rig.model.pasteAsNewScript()
        #expect(rig.store.scripts.isEmpty)
        #expect(rig.model.notice?.title == "Couldn't paste")
        rig.clipboard.value = "   \n  "
        rig.model.pasteAsNewScript()
        #expect(rig.store.scripts.isEmpty)
    }

    // Import and drop

    @Test func importOpensTheFirstScriptAndListsFailures() throws {
        let rig = try makeRig()
        let folder = try makeTempDirectory()
        defer { rig.cleanUp(); try? FileManager.default.removeItem(at: folder) }
        let good = folder.appending(path: "Intro.txt")
        try "Hello from a file.".write(to: good, atomically: true, encoding: .utf8)
        let empty = folder.appending(path: "Empty.txt")
        try "   ".write(to: empty, atomically: true, encoding: .utf8)
        let photo = folder.appending(path: "photo.png")
        try Data([0, 1, 2]).write(to: photo)

        rig.model.importFiles([good, empty, photo])

        #expect(rig.store.scripts.map(\.title) == ["Intro"])
        #expect(rig.model.selectedScript?.title == "Intro")
        let notice = try #require(rig.model.notice)
        #expect(notice.title == "Couldn't import some files")
        let lines = (notice.message ?? "").split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines.contains { $0.hasPrefix("photo.png: ") })
        #expect(lines.contains { $0.hasPrefix("Empty.txt: ") })
    }

    @Test func aSingleFailureUsesTheSingularTitle() throws {
        let rig = try makeRig()
        defer { rig.cleanUp() }
        rig.model.importFiles([URL(filePath: "/tmp/photo.png")])
        #expect(rig.model.notice?.title == "Couldn't import a file")
        #expect(rig.store.scripts.isEmpty)
    }

    @Test func dropTakesFilesAndIgnoresOtherURLs() throws {
        let rig = try makeRig()
        let folder = try makeTempDirectory()
        defer { rig.cleanUp(); try? FileManager.default.removeItem(at: folder) }
        #expect(!rig.model.handleDrop([URL(string: "https://example.com")!]))
        #expect(!rig.model.handleDrop([]))
        let file = folder.appending(path: "Dropped.txt")
        try "Dropped words here".write(to: file, atomically: true, encoding: .utf8)
        #expect(rig.model.handleDrop([file]))
        #expect(rig.store.scripts.map(\.title) == ["Dropped"])
    }

    @Test func cancellingTheFilePickerSaysNothing() throws {
        let rig = try makeRig()
        defer { rig.cleanUp() }
        rig.model.handleImporter(.failure(CocoaError(.userCancelled)))
        #expect(rig.model.notice == nil)
        rig.model.handleImporter(.failure(CocoaError(.fileReadUnknown)))
        #expect(rig.model.notice?.title == "Couldn't import")
    }

    // Duplicate, rename, prompt

    @Test func duplicateOpensTheCopy() throws {
        let original = script("Intro", "Some words")
        let rig = try makeRig(scripts: [original])
        defer { rig.cleanUp() }
        rig.model.duplicate(original.id)
        #expect(rig.store.scripts.count == 2)
        #expect(rig.model.selectedScript?.title == "Intro copy")
    }

    @Test func renameChangesTheTitle() throws {
        let original = script("Intro", "Some words")
        let rig = try makeRig(scripts: [original])
        defer { rig.cleanUp() }
        rig.model.beginRename(original.id)
        #expect(rig.model.renameText == "Intro")
        rig.model.renameText = "  New name  "
        rig.model.commitRename()
        #expect(rig.store.script(id: original.id)?.title == "New name")
        #expect(rig.model.renameTarget == nil)
    }

    @Test func promptNeedsWords() throws {
        let words = script("Words", "Read this out loud")
        let notes = script("Notes", "// only a note\n[pause 3]", age: 10)
        let rig = try makeRig(scripts: [words, notes])
        defer { rig.cleanUp() }

        #expect(!rig.model.canPrompt)   // nothing open
        rig.model.select(notes.id)
        #expect(!rig.model.canPrompt)
        rig.model.prompt(notes.id)
        #expect(rig.presented.value.isEmpty)

        rig.model.select(words.id)
        #expect(rig.model.canPrompt)
        rig.model.prompt(words.id)
        #expect(rig.presented.value == [words.id])
    }

    @Test func searchFiltersTheSidebarList() throws {
        let a = script("Alpha", "one")
        let b = script("Beta", "two", age: 10)
        let rig = try makeRig(scripts: [a, b])
        defer { rig.cleanUp() }
        rig.model.searchText = "bet"
        #expect(rig.model.filteredScripts().map(\.id) == [b.id])
        rig.model.searchText = ""
        #expect(rig.model.filteredScripts().count == 2)
    }

    // Delete and undo

    @Test func deletingTheOpenScriptClearsTheDetailAndShowsTheBanner() throws {
        let a = script("Alpha", "one")
        let b = script("Beta", "two", age: 10)
        let rig = try makeRig(scripts: [a, b])
        defer { rig.cleanUp() }
        rig.model.select(a.id)
        rig.model.delete(a.id)
        #expect(rig.model.selection == nil)
        #expect(rig.store.scripts.map(\.id) == [b.id])
        #expect(rig.model.deletedScript?.id == a.id)
    }

    @Test func deletingAnotherScriptKeepsTheSelection() throws {
        let a = script("Alpha", "one")
        let b = script("Beta", "two", age: 10)
        let rig = try makeRig(scripts: [a, b])
        defer { rig.cleanUp() }
        rig.model.select(a.id)
        rig.model.delete(b.id)
        #expect(rig.model.selection == a.id)
    }

    @Test func undoManagerBringsBackTheScriptAndReopensIt() throws {
        let a = script("Alpha", "one")
        let rig = try makeRig(scripts: [a])
        defer { rig.cleanUp() }
        rig.model.select(a.id)
        rig.model.delete(a.id)
        #expect(rig.undoManager.canUndo)
        #expect(rig.undoManager.undoActionName == "Delete Script")

        rig.undoManager.undo()
        #expect(rig.store.script(id: a.id) == a)    // same edit date, so it lands where it was
        #expect(rig.model.selection == a.id)
        #expect(rig.model.deletedScript == nil)
        #expect(rig.undoManager.canRedo)

        rig.undoManager.redo()
        #expect(rig.store.script(id: a.id) == nil)
        #expect(rig.model.selection == nil)
        #expect(rig.undoManager.canUndo)
    }

    @Test func theBannerButtonUndoesAndLeavesNothingToUndoTwice() throws {
        let a = script("Alpha", "one")
        let rig = try makeRig(scripts: [a])
        defer { rig.cleanUp() }
        // The app's undo groups close at the end of each event; here they close by hand.
        rig.undoManager.groupsByEvent = false
        rig.model.select(a.id)
        rig.undoManager.beginUndoGrouping()
        rig.model.delete(a.id)
        rig.undoManager.endUndoGrouping()
        #expect(rig.undoManager.canUndo)
        rig.model.undoDelete()
        #expect(rig.store.script(id: a.id) == a)
        #expect(rig.model.selection == a.id)
        #expect(rig.model.deletedScript == nil)
        #expect(!rig.undoManager.canUndo)
        #expect(!rig.undoManager.canRedo)
    }

    @Test func undoDoesNotStealTheSelection() throws {
        let a = script("Alpha", "one")
        let b = script("Beta", "two", age: 10)
        let rig = try makeRig(scripts: [a, b])
        defer { rig.cleanUp() }
        rig.model.select(a.id)
        rig.model.delete(a.id)
        rig.model.select(b.id)
        rig.undoManager.undo()
        #expect(rig.model.selection == b.id)
        #expect(rig.store.script(id: a.id) != nil)
    }

    @Test func dismissingTheBannerHidesIt() throws {
        let a = script("Alpha", "one")
        let rig = try makeRig(scripts: [a])
        defer { rig.cleanUp() }
        rig.model.delete(a.id)
        #expect(rig.model.deletedScript != nil)
        rig.model.dismissBanner()
        #expect(rig.model.deletedScript == nil)
    }

    // Errors

    @Test func aStoreErrorIsShownOnceAndClearedWhenDismissed() throws {
        let rig = try makeRig()
        defer { rig.cleanUp() }
        // A library directory that can't be written makes a store error: a file where the folder should be.
        let blocker = rig.directory.appending(path: "blocked")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)
        let brokenStore = ScriptStore(directory: blocker, initialScripts: { _ in [] })
        let model = MacLibraryModel(store: brokenStore)
        model.showStoreError()
        let notice = try #require(model.notice)
        #expect(notice.isStoreError)
        model.showStoreError()
        #expect(model.notice?.id == notice.id)   // not shown again
        model.noticeDismissed()
        #expect(model.notice == nil)
        #expect(brokenStore.lastError == nil)
    }
}

// MARK: - The editor and the app (M8 review)

/// The script editor's text view with a new version arriving from sync: undo keeps working, and a composition (an accent
/// or an input method) in progress doesn't lose it.
@MainActor
struct ScriptTextEditorSyncTests {
    private final class TextBox {
        var text: String
        init(_ text: String) { self.text = text }
    }

    private struct Editor {
        let box: TextBox
        let editor: ScriptTextEditor
        let coordinator: ScriptTextEditor.Coordinator
        let scrollView: NSScrollView
        let textView: ScriptNSTextView
        let window: NSWindow

        var undoManager: UndoManager { textView.undoManager! }

        /// One undo step, as a key press would make.
        func step(_ change: () -> Void) {
            undoManager.beginUndoGrouping()
            change()
            undoManager.endUndoGrouping()
        }

        /// A new text from outside, the way the editor view hands it over (its binding changes, SwiftUI updates the view).
        func receive(_ text: String) {
            box.text = text
            step { editor.update(scrollView, coordinator: coordinator) }
        }

        func undo() {
            undoManager.undo()
        }
    }

    private func makeEditor(_ text: String) -> Editor {
        let box = TextBox(text)
        let editor = ScriptTextEditor(text: Binding(get: { box.text }, set: { box.text = $0 }), margin: 20)
        let coordinator = editor.makeCoordinator()
        let scrollView = editor.makeScrollView(coordinator: coordinator)
        // An off-screen window that is never shown: it gives the text view its undo manager.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        let textView = scrollView.documentView as! ScriptNSTextView
        textView.undoManager?.groupsByEvent = false
        return Editor(box: box, editor: editor, coordinator: coordinator, scrollView: scrollView, textView: textView,
                      window: window)
    }

    private func type(_ text: String, in editor: Editor) {
        editor.step {
            let end = (editor.textView.string as NSString).length
            editor.textView.setSelectedRange(NSRange(location: end, length: 0))
            editor.textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    @Test func undoAfterANewVersionFromTheIPhoneTakesItBackThenTheTypingBeforeIt() {
        let editor = makeEditor("Hello world")
        type(" again", in: editor)
        #expect(editor.textView.string == "Hello world again")
        #expect(editor.box.text == "Hello world again")

        editor.receive("Short")
        #expect(editor.textView.string == "Short")
        #expect(editor.box.text == "Short")

        // The undo steps of the typing still fit the text they were made on.
        editor.undo()
        #expect(editor.textView.string == "Hello world again")
        #expect(editor.box.text == "Hello world again")
        editor.undo()
        #expect(editor.textView.string == "Hello world")
        #expect(editor.box.text == "Hello world")
    }

    @Test func aNewVersionArrivingMidCompositionGoesInWhenTheCompositionEndsUnchanged() {
        let editor = makeEditor("Cafe")
        let end = (editor.textView.string as NSString).length
        editor.textView.setSelectedRange(NSRange(location: end, length: 0))
        editor.step {
            editor.textView.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0),
                                          replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        #expect(editor.textView.hasMarkedText())
        let typed = editor.textView.string

        editor.receive("Remote version")
        #expect(editor.textView.string == typed, "left alone while composing")

        // The composition is committed as it stood: nothing new was typed since the new version came, so it goes in.
        editor.step { editor.textView.unmarkText() }
        #expect(editor.textView.string == "Remote version",
                "marked \(editor.textView.hasMarkedText()) string \(editor.textView.string.debugDescription) typed \(typed.debugDescription)")
        #expect(editor.box.text == "Remote version")
    }

    @Test func aCompositionThatTypesSomethingNewWinsOverTheVersionThatArrivedMeanwhile() {
        let editor = makeEditor("Cafe")
        let end = (editor.textView.string as NSString).length
        editor.textView.setSelectedRange(NSRange(location: end, length: 0))
        editor.step {
            editor.textView.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0),
                                          replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        editor.receive("Remote version")

        // The accent composes into "é": the person's edit, made after the new version arrived, wins.
        editor.step {
            editor.textView.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        #expect(!editor.textView.hasMarkedText())
        #expect(editor.textView.string == "Cafeé")
        #expect(editor.box.text == "Cafeé")
    }
}

@MainActor
struct MacAppLifecycleTests {
    @Test func closingTheLibraryKeepsPrompterRunningAndTheDockBringsItBack() {
        let delegate = MacAppDelegate()
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))

        let saved = LibraryWindow.open
        defer { LibraryWindow.open = saved }
        var opened = 0
        LibraryWindow.open = { opened += 1 }
        #expect(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false) == false)
        #expect(opened == 1)
        #expect(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        #expect(opened == 1)
    }
}
