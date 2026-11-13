import Foundation

/// Where the library is pointing, for both of its layouts.
///
/// - Compact width (iPhone, an iPad in slide-over): the scripts are pushed on a navigation stack, so the state is a `path`.
/// - Regular width (iPad full screen, a large split): a split view with the list on the left and the editor on the right,
///   so the state is the `selection`.
///
/// Only one of the two is ever set. A window that changes width class (iPad Split View, Stage Manager) hands the open
/// script from one to the other, so the editor doesn't vanish when the window is resized.
struct LibraryNavigation: Equatable, Sendable {
    /// Compact: the pushed scripts (at most one, the editor).
    var path: [Script.ID] = []
    /// Regular: the script open in the detail column.
    var selection: Script.ID?

    /// Opens a script's editor: pushed on a compact screen, shown in the detail on a regular one.
    mutating func open(_ id: Script.ID, isRegular: Bool) {
        if isRegular {
            selection = id
        } else {
            path.append(id)
        }
    }

    /// The window turned regular or compact: the open script moves to the other layout's state.
    mutating func widthClassChanged(isRegular: Bool) {
        if isRegular {
            selection = path.last ?? selection
            path = []
        } else {
            if let selection { path = [selection] }
            selection = nil
        }
    }

    /// A script was deleted. Returns whether it was the open one, which clears the detail.
    @discardableResult
    mutating func removed(_ id: Script.ID) -> Bool {
        guard selection == id else { return false }
        selection = nil
        return true
    }

    /// Undo of a delete: the script comes back into the detail if it was open and nothing else has been opened since.
    mutating func restored(_ id: Script.ID, wasOpen: Bool) {
        guard wasOpen, selection == nil else { return }
        selection = id
    }
}
