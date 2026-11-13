import SwiftUI

/// "Make a new script", published by the library while it is on screen at regular width (so a keyboard shortcut has
/// something to run, and does nothing over the prompter).
struct NewScriptActionKey: FocusedValueKey {
    typealias Value = @MainActor () -> Void
}

extension FocusedValues {
    var newScriptAction: (@MainActor () -> Void)? {
        get { self[NewScriptActionKey.self] }
        set { self[NewScriptActionKey.self] = newValue }
    }
}

/// The iPad menu bar and hardware-keyboard shortcuts. ⌘N is "New script" (it takes the place of "New Window": the app
/// is one window over one library).
struct LibraryCommands: Commands {
    @FocusedValue(\.newScriptAction) private var newScript

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New script") { newScript?() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(newScript == nil)
        }
    }
}
