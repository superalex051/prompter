import AppKit
import Observation

/// A message for the library's alert.
struct LibraryNotice: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String?
    /// Shows `ScriptStore.lastError`; dismissing it clears that error.
    var isStoreError = false
}

/// Everything the library window and the menu commands do: selection, search, new / paste / import / duplicate / rename /
/// delete with undo, and starting the prompter. Views only draw this and forward clicks, so the behaviour is testable.
@MainActor @Observable
final class MacLibraryModel {
    let store: ScriptStore

    /// The open script (the editor in the detail column). Change it with `select(_:)`.
    private(set) var selection: Script.ID?
    var searchText = ""
    var notice: LibraryNotice?
    var isImporting = false
    /// The script shown in the "Undo delete" banner.
    private(set) var deletedScript: Script?
    var renameTarget: Script?
    var renameText = ""

    /// Starts presenting a script (set to the launcher by the app).
    @ObservationIgnored var present: (Script.ID) -> Void
    /// The clipboard's text; the app reads `NSPasteboard`.
    @ObservationIgnored var pasteboardText: () -> String?
    /// The window's undo manager, so ⌘Z in the Edit menu undoes a delete (and text edits share the same stack).
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var bannerHideTask: Task<Void, Never>?
    @ObservationIgnored private var deletedWasSelected = false

    /// How long the Undo banner stays up.
    static let bannerDuration: Duration = .seconds(8)

    init(
        store: ScriptStore,
        present: @escaping (Script.ID) -> Void = { _ in },
        pasteboardText: @escaping () -> String? = { NSPasteboard.general.string(forType: .string) }
    ) {
        self.store = store
        self.present = present
        self.pasteboardText = pasteboardText
    }

    // MARK: Reading state

    var selectedScript: Script? {
        selection.flatMap { store.script(id: $0) }
    }

    /// Prompt needs a script with at least one word to read.
    var canPrompt: Bool {
        guard let script = selectedScript else { return false }
        return ReadingStats(text: script.body).wordCount > 0
    }

    func filteredScripts() -> [Script] {
        ScriptSearch.filter(store.scripts, query: searchText)
    }

    // MARK: Selection

    /// Opens a script (or none). A new script that was never typed into is removed when the editor moves away from it.
    func select(_ id: Script.ID?) {
        guard id != selection else { return }
        let previous = selection
        selection = id
        if let previous { store.deleteIfBlank(previous) }
    }

    /// The app is quitting or the window is closing: don't leave an empty new script behind.
    func abandonSelection() {
        select(nil)
    }

    // MARK: Creating

    func newScript() {
        let script = store.create()
        select(script.id)
    }

    func pasteAsNewScript() {
        guard let text = pasteboardText(), let script = store.createFromText(text) else {
            notice = LibraryNotice(
                title: "Couldn't paste",
                message: "Nothing to paste. Copy your script first, then choose Paste as new script."
            )
            return
        }
        select(script.id)
    }

    /// Picked in the file importer.
    func handleImporter(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            importFiles(urls)
        case .failure(let error):
            if (error as? CocoaError)?.code == .userCancelled { return }
            notice = LibraryNotice(title: "Couldn't import", message: "The file picker couldn't open that. Try again.")
        }
    }

    /// Dropped on the window. Returns whether anything was taken.
    @discardableResult
    func handleDrop(_ urls: [URL]) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return false }
        importFiles(files)
        return true
    }

    /// Imports what it can, opens the first new script, and lists the files that failed.
    func importFiles(_ urls: [URL]) {
        let parts = ImportableFiles.split(urls)
        var failures = parts.rejected
        if !parts.accepted.isEmpty {
            let summary = store.importFiles(at: parts.accepted)
            failures += summary.failures
            if let first = summary.imported.first { select(first.id) }
        }
        guard !failures.isEmpty else { return }
        notice = LibraryNotice(
            title: failures.count == 1 ? "Couldn't import a file" : "Couldn't import some files",
            message: failures.map { "\($0.filename): \($0.message)" }.joined(separator: "\n")
        )
    }

    // MARK: Changing

    func duplicate(_ id: Script.ID) {
        guard let copy = store.duplicate(id) else { return }
        select(copy.id)
    }

    func beginRename(_ id: Script.ID) {
        guard let script = store.script(id: id) else { return }
        renameTarget = script
        renameText = script.title
    }

    func commitRename() {
        if let target = renameTarget { store.rename(target.id, to: renameText) }
        renameTarget = nil
    }

    func prompt(_ id: Script.ID) {
        guard let script = store.script(id: id), ReadingStats(text: script.body).wordCount > 0 else { return }
        present(id)
    }

    // MARK: Deleting, with undo

    /// Removes a script, shows the Undo banner and registers the delete with the undo manager (⌘Z in the Edit menu).
    func delete(_ id: Script.ID) {
        guard let removed = store.delete(id) else { return }
        let wasSelected = selection == id
        if wasSelected { selection = nil }   // the script is gone, so there is no blank one to clean up
        deletedWasSelected = wasSelected
        showBanner(for: removed)
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restore(removed, selecting: wasSelected) }
        }
        undoManager?.setActionName("Delete Script")
    }

    /// Brings a deleted script back (undo, or the banner's button). Keeps its edit date, so it lands where it was.
    func restore(_ script: Script, selecting: Bool) {
        let wasMissing = store.script(id: script.id) == nil
        store.restore(script)
        if selecting, selection == nil { selection = script.id }
        hideBanner()
        // Undoing registers the redo (delete again). Called from the banner there is nothing to redo.
        guard wasMissing, let undoManager, undoManager.isUndoing else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.delete(script.id) }
        }
        undoManager.setActionName("Delete Script")
    }

    /// The banner's Undo button.
    func undoDelete() {
        guard let script = deletedScript else { return }
        let selecting = deletedWasSelected
        // The banner and the undo stack are the same delete; drop the stack's copy so ⌘Z doesn't repeat it.
        undoManager?.removeAllActions(withTarget: self)
        restore(script, selecting: selecting)
    }

    func dismissBanner() {
        hideBanner()
    }

    // MARK: Alerts

    func showStoreError() {
        guard let message = store.lastError,
              !(notice?.isStoreError == true && notice?.message == message) else { return }
        notice = LibraryNotice(title: "Problem with your scripts", message: message, isStoreError: true)
    }

    /// The alert was dismissed: a store error is cleared in the store, so it isn't shown again.
    func noticeDismissed() {
        if notice?.isStoreError == true { store.clearError() }
        notice = nil
    }

    // MARK: Private

    private func showBanner(for script: Script) {
        bannerHideTask?.cancel()
        deletedScript = script
        bannerHideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.bannerDuration)
            guard !Task.isCancelled else { return }
            self?.hideBanner()
        }
    }

    private func hideBanner() {
        bannerHideTask?.cancel()
        bannerHideTask = nil
        deletedScript = nil
    }
}
