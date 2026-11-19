import Foundation

/// Where the library is pointing, the same for both of its layouts (see `LibraryLayout`).
///
/// - Stack (iPhone, an iPad in slide-over, the iPhone Duo folded or open and tall): the open script's editor is pushed over
///   the list, so the stack reads `path`.
/// - Split (iPad full screen, the iPhone Duo open and wide): the list on the left and the open script's editor on the
///   right, so the split view reads `selection`.
///
/// Both read the one `openScript`, so a window that switches layout keeps the script open: an iPad resized in Split View
/// or Stage Manager, and the iPhone Duo folding or unfolding. The finding: the open script used to be handed from one
/// layout's state to the other's only after the switch, so the new layout first showed the list (and pushed the editor in
/// again) or an empty detail, and the old editor's cleanup deleted a blank new script on the way out.
struct LibraryNavigation: Equatable, Sendable {
    /// The script whose editor is open, in either layout.
    private(set) var openScript: Script.ID?

    /// The stack's path: the open script's editor pushed over the list, or nothing.
    var path: [Script.ID] { openScript.map { [$0] } ?? [] }

    /// The split view's detail: the open script.
    var selection: Script.ID? { openScript }

    /// Opens a script's editor: pushed on the stack, or shown in the split view's detail.
    mutating func open(_ id: Script.ID) {
        openScript = id
    }

    /// The stack changed its path: the back button or a swipe back popped the editor.
    mutating func setPath(_ path: [Script.ID]) {
        openScript = path.last
    }

    /// Whether `id`'s editor is still open, in either layout. An editor that goes away while its script is still open was
    /// only moved to the other layout (a fold), so it must not drop the script as an abandoned blank one.
    func isOpen(_ id: Script.ID) -> Bool {
        openScript == id
    }

    /// A script was deleted. Returns whether it was the open one, which clears the detail.
    @discardableResult
    mutating func removed(_ id: Script.ID) -> Bool {
        guard openScript == id else { return false }
        openScript = nil
        return true
    }

    /// Undo of a delete: the script comes back into the detail if it was open and nothing else has been opened since.
    mutating func restored(_ id: Script.ID, wasOpen: Bool) {
        guard wasOpen, openScript == nil else { return }
        openScript = id
    }
}

/// Which scripts have an editor on screen, so a blank new script the person left is dropped whichever comes first: the
/// library closing it, or its editor going away.
///
/// A back button tap closes the script first and the editor goes away at the end of the slide, while a swipe back may
/// end the other way round, and a layout switch (the iPhone Duo folding or unfolding) takes an editor away while its
/// script stays open. Dropping the script only once both have happened covers every order, and never while an editor
/// still shows it, so a sliding editor never flashes "Script deleted".
struct EditorPresence: Equatable, Sendable {
    /// Editors on screen per script: a layout switch can briefly show two of the same script.
    private var onScreen: [Script.ID: Int] = [:]

    mutating func editorAppeared(_ id: Script.ID) {
        onScreen[id, default: 0] += 1
    }

    /// An editor of `id` went away. Returns whether the script was left: no editor of it is on screen any more and the
    /// library no longer has it open (`isOpen`).
    mutating func editorDisappeared(_ id: Script.ID, isOpen: Bool) -> Bool {
        let left = max((onScreen[id] ?? 0) - 1, 0)
        onScreen[id] = left == 0 ? nil : left
        return left == 0 && !isOpen
    }

    /// The library closed `id` (back to the list, or another script opened). Returns whether the script was left: its
    /// editor already went away. Otherwise that editor's own exit decides.
    func scriptClosed(_ id: Script.ID) -> Bool {
        onScreen[id] == nil
    }
}

/// Holds `EditorPresence` for the library and its editors: a plain reference SwiftUI doesn't observe, so editors coming
/// and going never redraw the library.
@MainActor
final class EditorPresenceTracker {
    var state = EditorPresence()
}
