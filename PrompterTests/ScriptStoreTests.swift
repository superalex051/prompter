import Foundation
import Observation
import Synchronization
import Testing
import UIKit
@testable import Prompter

@MainActor
final class ScriptStoreTests {
    let directory: URL
    let clock = TestClock()

    init() throws {
        directory = try makeTemporaryDirectory()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appending(path: "scripts.json") }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func makeStore(
        initialScripts: @escaping @Sendable (Date) -> [Script] = { [SampleScript.make(now: $0)] }
    ) -> ScriptStore {
        let clock = clock
        return ScriptStore(
            directory: directory,
            now: { clock.now },
            initialScripts: initialScripts,
            isProtectedDataAvailable: true
        )
    }

    /// A store made while `UIApplication.isProtectedDataAvailable` reads false: before the first unlock after a
    /// restart, but also (seen on the simulator) during `App.init` on a perfectly normal launch.
    private func makeLockedStore(
        center: NotificationCenter,
        initialScripts: @escaping @Sendable (Date) -> [Script] = { [SampleScript.make(now: $0)] }
    ) -> ScriptStore {
        let clock = clock
        return ScriptStore(
            directory: directory,
            now: { clock.now },
            initialScripts: initialScripts,
            isProtectedDataAvailable: false,
            notificationCenter: center
        )
    }

    /// A store whose first launch starts with no scripts.
    private func makeEmptyStore() -> ScriptStore {
        makeStore(initialScripts: { _ in [] })
    }

    // MARK: Loading and seeding

    @Test func sampleIsSeededOnlyWhenNoFileExists() throws {
        let first = makeStore()
        #expect(first.scripts.map(\.id) == [SampleScript.id])
        #expect(first.lastError == nil)
        #expect(fileExists(fileURL))
        #expect(first.fileURL.standardizedFileURL == fileURL.standardizedFileURL)

        #expect(first.delete(SampleScript.id) != nil)

        let second = makeStore()
        #expect(second.scripts.isEmpty)
        #expect(second.lastError == nil)
    }

    @Test func fileFormatIsVersionedJSON() throws {
        let store = makeEmptyStore()
        store.create(title: "Intro", body: "Hello")
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        #expect(json["version"] as? Int == 2, "version 2 since M7 (sync clocks and tombstones)")
        let scripts = try #require(json["scripts"] as? [[String: Any]])
        #expect(scripts.count == 1)
        #expect(scripts.first?["updatedAt"] as? String == "2027-01-15T08:00:00Z")
    }

    @Test func corruptFileIsMovedAsideAndNotOverwritten() throws {
        let original = Data("not json".utf8)
        try original.write(to: fileURL)

        let store = makeStore()
        #expect(store.scripts.isEmpty)
        let error = try #require(store.lastError)

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        let corruptName = try #require(names.first { $0.hasPrefix("scripts-corrupt-") && $0.hasSuffix(".json") })
        let corruptURL = directory.appending(path: corruptName)
        #expect(try Data(contentsOf: corruptURL) == original)
        #expect(error == ScriptStore.corruptFileMessage)
        #expect(error == """
            Couldn't read your saved scripts, so your library starts empty. The damaged file was kept on this iPhone.
            """)

        // An empty library replaces it, so the next launch shows what's really there instead of re-seeding the sample.
        let relaunched = makeStore()
        #expect(relaunched.scripts.isEmpty)
        #expect(relaunched.lastError == nil)

        store.create(title: "Fresh start", body: "")
        #expect(fileExists(fileURL))
        #expect(try Data(contentsOf: corruptURL) == original)
        #expect(store.lastError == error, "a successful save doesn't hide the load error before it is shown")
        #expect(makeStore().scripts.map(\.title) == ["Fresh start"])
    }

    @Test func unreadableFileIsLeftInPlaceAndNeverOverwritten() throws {
        let seeded = makeStore()
        let original = try Data(contentsOf: fileURL)
        #expect(seeded.scripts.map(\.id) == [SampleScript.id])

        // A read error (e.g. the file is locked before first unlock) is not corruption.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path(percentEncoded: false))
        }

        let store = makeStore()
        #expect(store.scripts.isEmpty)
        #expect(store.lastError == ScriptStore.openFailedMessage)
        store.create(title: "Typed while locked", body: "Words")

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path(percentEncoded: false))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        #expect(!names.contains { $0.hasPrefix("scripts-corrupt-") }, "the file must not be moved aside")
        #expect(try Data(contentsOf: fileURL) == original, "saving stays blocked so the library is never overwritten")

        let reopened = makeStore()
        #expect(reopened.scripts.map(\.id) == [SampleScript.id])
        #expect(reopened.lastError == nil)
    }

    // MARK: Before the first unlock

    /// Data protection before the first unlock, simulated: the file can't be opened (`unlock()` undoes it).
    private func lockFile() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path(percentEncoded: false))
    }

    /// No new file can be created in the directory (a first launch before the first unlock); `unlock()` undoes it.
    private func lockDirectory() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path(percentEncoded: false))
    }

    private func unlock() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path(percentEncoded: false))
        if fileExists(fileURL) {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path(percentEncoded: false))
        }
    }

    /// The regression: `isProtectedDataAvailable` read false in `App.init` on a normal launch, so the store waited with an
    /// empty library and `-route prompter` found nothing to open. A file that can be read is loaded there and then.
    @Test func aReadableLibraryLoadsAtOnceEvenIfTheFlagSaysLocked() throws {
        makeEmptyStore().create(title: "Real script", body: "Words")

        let center = NotificationCenter()
        let store = makeLockedStore(center: center)
        #expect(!store.isWaitingForProtectedData)
        #expect(store.scripts.map(\.title) == ["Real script"])
        #expect(store.lastError == nil)

        // It saves as usual, and a later notice reloads nothing.
        store.create(title: "Second", body: "Words")
        center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(store.scripts.map(\.title).sorted() == ["Real script", "Second"])
        #expect(makeStore().scripts.map(\.title).sorted() == ["Real script", "Second"])
    }

    /// A first launch whose sample can be written seeds it at once, whatever the flag says.
    @Test func aFirstLaunchSeedsTheSampleAtOnceEvenIfTheFlagSaysLocked() {
        let store = makeLockedStore(center: NotificationCenter())
        #expect(!store.isWaitingForProtectedData)
        #expect(store.scripts.map(\.id) == [SampleScript.id])
        #expect(store.lastError == nil)
        #expect(fileExists(fileURL))
    }

    /// A watch message launched the app before the first unlock after a restart: the file exists but can't be read (it
    /// is still encrypted). The store waits: nothing is saved over it and no error is shown; once protected data becomes
    /// available it loads.
    @Test func beforeTheFirstUnlockTheLibraryWaitsAndIsNeverOverwritten() throws {
        let seeded = makeEmptyStore()
        seeded.create(title: "Real script", body: "Words")
        let original = try Data(contentsOf: fileURL)
        try lockFile()
        defer { try? unlock() }

        let center = NotificationCenter()
        let store = makeLockedStore(center: center)
        #expect(store.isWaitingForProtectedData)
        #expect(store.scripts.isEmpty)
        #expect(store.lastError == nil)
        store.create(title: "Made while locked", body: "Words")

        try unlock()
        #expect(try Data(contentsOf: fileURL) == original, "nothing is saved before the library was read")
        #expect(store.isWaitingForProtectedData, "only the notice ends the wait")

        center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        #expect(!store.isWaitingForProtectedData)
        #expect(store.scripts.map(\.title) == ["Real script"])
        #expect(store.lastError == nil)

        // From here on it saves as usual.
        store.create(title: "After unlock", body: "Words")
        #expect(makeStore().scripts.map(\.title).sorted() == ["After unlock", "Real script"])
    }

    /// A first launch before the first unlock: the sample can't be written yet, so the store waits and seeds it then.
    @Test func aFirstLaunchBeforeTheFirstUnlockSeedsTheSampleOnceUnlocked() throws {
        try lockDirectory()
        defer { try? unlock() }
        let center = NotificationCenter()
        let store = makeLockedStore(center: center)
        #expect(store.isWaitingForProtectedData)
        #expect(store.scripts.isEmpty)
        #expect(store.lastError == nil)
        #expect(!fileExists(fileURL))

        try unlock()
        store.protectedDataBecameAvailable()
        #expect(!store.isWaitingForProtectedData)
        #expect(store.scripts.map(\.id) == [SampleScript.id])
        #expect(fileExists(fileURL))
        // A second notice changes nothing.
        center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        #expect(store.scripts.map(\.id) == [SampleScript.id])
    }

    @Test func becomingActiveAlsoLoadsAWaitingLibrary() throws {
        makeEmptyStore().create(title: "Real script", body: "Words")
        try lockFile()
        defer { try? unlock() }
        let center = NotificationCenter()
        let store = makeLockedStore(center: center)
        #expect(store.isWaitingForProtectedData)

        try unlock()
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(store.scripts.map(\.title) == ["Real script"])
    }

    /// The launch route watches `isWaitingForProtectedData`, so the end of the wait must reach observers.
    @Test func theEndOfTheWaitIsObservable() throws {
        makeEmptyStore().create(title: "Real script", body: "Words")
        try lockFile()
        defer { try? unlock() }
        let store = makeLockedStore(center: NotificationCenter())
        let changed = ObservedChange()
        withObservationTracking {
            _ = store.isWaitingForProtectedData
        } onChange: {
            changed.fire()
        }

        try unlock()
        store.protectedDataBecameAvailable()
        #expect(changed.didFire)
        #expect(!store.isWaitingForProtectedData)
    }

    /// Still unreadable once the phone is unlocked: a real read error, reported as before, and the file is left alone.
    @Test func aFileStillUnreadableAfterTheUnlockIsReportedAndNeverOverwritten() throws {
        makeEmptyStore().create(title: "Real script", body: "Words")
        let original = try Data(contentsOf: fileURL)
        try lockFile()
        defer { try? unlock() }
        let store = makeLockedStore(center: NotificationCenter())
        #expect(store.isWaitingForProtectedData)

        store.protectedDataBecameAvailable()
        #expect(!store.isWaitingForProtectedData)
        #expect(store.scripts.isEmpty)
        #expect(store.lastError == ScriptStore.openFailedMessage)
        store.create(title: "Typed afterwards", body: "Words")

        try unlock()
        #expect(try Data(contentsOf: fileURL) == original, "saving stays blocked")
    }

    // MARK: Errors

    @Test func saveErrorsAreReportedEachTimeAndClearedBySuccess() throws {
        let store = makeEmptyStore()
        #expect(store.lastError == nil)

        let path = directory.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }

        store.create(title: "One", body: "Words")
        #expect(store.lastError == ScriptStore.saveFailedMessage)
        #expect(store.lastError == "Couldn't save your latest changes. Check that your iPhone has free storage, then try again.")

        // The UI clears the error once it has shown it, so the next failure is a new change it can report.
        store.clearError()
        #expect(store.lastError == nil)
        store.create(title: "Two", body: "Words")
        #expect(store.lastError == ScriptStore.saveFailedMessage)

        // A save that works again clears a save error by itself.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        store.create(title: "Three", body: "Words")
        #expect(store.lastError == nil)
        #expect(makeEmptyStore().scripts.map(\.title).sorted() == ["One", "Three", "Two"])
    }

    @Test func clearErrorClearsALoadError() throws {
        try Data("not json".utf8).write(to: fileURL)
        let store = makeStore()
        #expect(store.lastError != nil)
        store.clearError()
        #expect(store.lastError == nil)
    }

    @Test func secondCorruptFileInTheSameSecondKeepsBothCopies() throws {
        try Data("first bad file".utf8).write(to: fileURL)
        _ = makeStore()
        try Data("second bad file".utf8).write(to: fileURL)
        _ = makeStore()

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        let copies = names.filter { $0.hasPrefix("scripts-corrupt-") }
        #expect(copies.count == 2)
        let contents = try Set(copies.map { try String(contentsOf: directory.appending(path: $0), encoding: .utf8) })
        #expect(contents == ["first bad file", "second bad file"])
    }

    // MARK: Mutations persist

    @Test func createPersists() {
        let store = makeEmptyStore()
        let script = store.create(title: "Intro", body: "Hello there")
        #expect(script.createdAt == clock.now)
        #expect(script.updatedAt == clock.now)
        #expect(store.scripts == [script])
        #expect(makeEmptyStore().scripts == [script])
    }

    @Test func createDefaultsToBlank() {
        let script = makeEmptyStore().create()
        #expect(script.title.isEmpty)
        #expect(script.body.isEmpty)
    }

    @Test func updatePersistsAndBumpsUpdatedAt() throws {
        let store = makeEmptyStore()
        let script = store.create(title: "Old", body: "Body")
        clock.advance(by: 60)

        store.update(script.id, title: "New")
        let updated = try #require(store.script(id: script.id))
        #expect(updated.title == "New")
        #expect(updated.body == "Body")
        #expect(updated.createdAt == script.createdAt)
        #expect(updated.updatedAt == clock.now)

        clock.advance(by: 60)
        store.update(script.id, body: "Changed")
        #expect(store.script(id: script.id)?.body == "Changed")
        #expect(makeEmptyStore().script(id: script.id) == store.script(id: script.id))
    }

    @Test func updateWithSameValuesDoesNotBumpUpdatedAt() throws {
        let store = makeEmptyStore()
        let script = store.create(title: "Title", body: "Body")
        clock.advance(by: 60)
        try FileManager.default.removeItem(at: fileURL)

        store.update(script.id, title: "Title", body: "Body")
        store.update(script.id)
        store.update(UUID(), title: "Nobody")

        #expect(store.script(id: script.id) == script)
        #expect(!fileExists(fileURL), "a no-op update must not save")
    }

    @Test func renameTrimsAndPersists() {
        let store = makeEmptyStore()
        let script = store.create(title: "Draft", body: "Words")
        clock.advance(by: 60)
        store.rename(script.id, to: "  Final cut \n")
        #expect(store.script(id: script.id)?.title == "Final cut")
        #expect(store.script(id: script.id)?.updatedAt == clock.now)
        #expect(makeEmptyStore().script(id: script.id)?.title == "Final cut")
    }

    @Test func duplicatePersists() throws {
        let store = makeEmptyStore()
        let original = store.create(title: "Talk", body: "Words to say")
        clock.advance(by: 60)

        let copy = try #require(store.duplicate(original.id))
        #expect(copy.id != original.id)
        #expect(copy.title == "Talk copy")
        #expect(copy.body == original.body)
        #expect(copy.createdAt == clock.now)
        #expect(copy.updatedAt == clock.now)
        #expect(store.scripts == [copy, original])
        #expect(makeEmptyStore().scripts == [copy, original])

        let untitled = store.create()
        #expect(store.duplicate(untitled.id)?.title == "Untitled copy")
        #expect(store.duplicate(UUID()) == nil)
    }

    @Test func deleteAndRestorePersist() throws {
        let store = makeEmptyStore()
        let first = store.create(title: "First", body: "One")
        clock.advance(by: 60)
        let second = store.create(title: "Second", body: "Two")
        clock.advance(by: 60)

        let removed = try #require(store.delete(first.id))
        #expect(removed == first)
        #expect(store.scripts == [second])
        #expect(makeEmptyStore().scripts == [second])
        #expect(store.delete(first.id) == nil)

        store.restore(removed)
        #expect(store.scripts == [second, first], "restore keeps the original id and timestamps")
        #expect(makeEmptyStore().scripts == [second, first])
    }

    @Test func restoreIsANoOpWhenTheIDExists() {
        let store = makeEmptyStore()
        let script = store.create(title: "Keep me", body: "")
        var impostor = script
        impostor.title = "Replaced"
        store.restore(impostor)
        #expect(store.scripts == [script])
    }

    // MARK: Ordering

    @Test func orderedByUpdatedAtNewestFirst() {
        let store = makeEmptyStore()
        let a = store.create(title: "A")
        clock.advance(by: 60)
        let b = store.create(title: "B")
        clock.advance(by: 60)
        let c = store.create(title: "C")
        #expect(store.scripts.map(\.id) == [c.id, b.id, a.id])

        clock.advance(by: 60)
        store.update(a.id, body: "Edited")
        #expect(store.scripts.map(\.id) == [a.id, c.id, b.id])
        #expect(makeEmptyStore().scripts.map(\.id) == [a.id, c.id, b.id])
    }

    @Test func tiesAreBrokenByCreatedAtThenID() {
        let time = clock.now
        let older = Script(title: "Older", body: "", createdAt: time - 100, updatedAt: time)
        let newer = Script(title: "Newer", body: "", createdAt: time - 50, updatedAt: time)
        let twinA = Script(id: UUID(uuidString: "00000000-0000-4000-8000-00000000000A")!, title: "Twin A", body: "", createdAt: time - 200, updatedAt: time)
        let twinB = Script(id: UUID(uuidString: "00000000-0000-4000-8000-00000000000B")!, title: "Twin B", body: "", createdAt: time - 200, updatedAt: time)
        let store = makeStore(initialScripts: { _ in [twinB, older, twinA, newer] })
        #expect(store.scripts.map(\.title) == ["Newer", "Older", "Twin A", "Twin B"])
    }

    // MARK: Paste, import and cleanup

    @Test func createFromBlankTextReturnsNil() {
        let store = makeEmptyStore()
        #expect(store.createFromText("") == nil)
        #expect(store.createFromText("   \n\t  ") == nil)
        #expect(store.createFromText("— - •") == nil)
        #expect(store.scripts.isEmpty)
    }

    @Test func createFromTextUsesTheFirstLineAsTitle() throws {
        let store = makeEmptyStore()
        let script = try #require(store.createFromText("\r\nBig news\r\nWe launched today.\r\n"))
        #expect(script.title == "Big news")
        #expect(script.body == "Big news\nWe launched today.")
        #expect(makeEmptyStore().scripts == [script])
    }

    @Test func deleteIfBlankRemovesOnlyBlankScripts() {
        let store = makeEmptyStore()
        let blank = store.create(title: "  ", body: "\n\t")
        let titled = store.create(title: "Title only")
        let bodied = store.create(body: "Body only")

        #expect(store.deleteIfBlank(blank.id))
        #expect(!store.deleteIfBlank(titled.id))
        #expect(!store.deleteIfBlank(bodied.id))
        #expect(!store.deleteIfBlank(UUID()))
        #expect(Set(store.scripts.map(\.id)) == [titled.id, bodied.id])
        #expect(Set(makeEmptyStore().scripts.map(\.id)) == [titled.id, bodied.id])
    }

    @Test func blankScriptsLeftBehindAreDroppedOnLoad() throws {
        let store = makeEmptyStore()
        let kept = store.create(title: "Keep", body: "Words")
        // The app quits (Xcode stop, crash, killed in the background) while a new script's editor is still open,
        // so the editor's deleteIfBlank never runs.
        _ = store.create()
        _ = store.create(title: " ", body: "\n")
        #expect(store.scripts.count == 3)

        let relaunched = makeEmptyStore()
        #expect(relaunched.scripts == [kept])
        #expect(relaunched.lastError == nil)

        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        #expect((json["scripts"] as? [[String: Any]])?.count == 1, "the cleanup is saved")
    }

    @Test func restoreSampleScriptIsIdempotent() {
        let store = makeEmptyStore()
        store.restoreSampleScript()
        store.restoreSampleScript()
        #expect(store.scripts.map(\.id) == [SampleScript.id])
        #expect(store.script(id: SampleScript.id)?.createdAt == clock.now)
        #expect(makeEmptyStore().scripts.map(\.id) == [SampleScript.id])

        let seeded = makeStore()
        seeded.restoreSampleScript()
        #expect(seeded.scripts.filter { $0.id == SampleScript.id }.count == 1)
    }

    @Test func importFilesReportsFailuresByName() throws {
        let inbox = directory.appending(path: "Inbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let good = inbox.appending(path: "Good talk.txt")
        try Data("Hello world".utf8).write(to: good)
        let bad = inbox.appending(path: "x.docx")
        try Data("PK".utf8).write(to: bad)

        let store = makeEmptyStore()
        let summary = store.importFiles(at: [good, bad])

        #expect(summary.imported.map(\.title) == ["Good talk"])
        #expect(summary.imported.map(\.body) == ["Hello world"])
        #expect(summary.failures == [ImportFailure(filename: "x.docx", message: "Prompter can import .txt, .md, .rtf and .pdf files.")])
        #expect(store.scripts == summary.imported)
        #expect(makeEmptyStore().scripts == summary.imported)
    }

    @Test func importFilesImportsPDFsAndReportsPDFFailuresByName() throws {
        let inbox = directory.appending(path: "Inbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let good = inbox.appending(path: "Keynote.pdf")
        try makePDFData(pages: [["Opening line."], ["Closing line."]]).write(to: good)
        let scan = inbox.appending(path: "Scan.pdf")
        try makePDFData(pages: [["Only pixels."]], scanned: true).write(to: scan)
        let broken = inbox.appending(path: "Broken.pdf")
        try Data([0x00, 0x13, 0x37]).write(to: broken)

        let store = makeEmptyStore()
        let summary = store.importFiles(at: [scan, good, broken])

        #expect(summary.imported.map(\.title) == ["Keynote"])
        #expect(summary.imported.map(\.body) == ["Opening line.\n\nClosing line."])
        #expect(summary.failures == [
            ImportFailure(filename: "Scan.pdf", message: "This PDF has no text to import (it may be a scan)."),
            ImportFailure(filename: "Broken.pdf", message: "The file couldn't be read."),
        ])
        #expect(store.scripts == summary.imported)
    }
}

/// Records that an observation's `onChange` ran (it may run on any thread).
private final class ObservedChange: Sendable {
    private let fired = Mutex(false)
    var didFire: Bool { fired.withLock { $0 } }
    func fire() { fired.withLock { $0 = true } }
}
