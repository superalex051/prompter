import SwiftUI

/// The menu bar: File (New, Paste, Import), Script (Prompt, Duplicate, Rename, Delete). Edit's Undo is the system's: a
/// delete is registered with the window's undo manager (see `MacLibraryModel.delete`), so ⌘Z brings the script back.
///
/// No shortcut on Delete: ⌘⌫ means "delete to the start of the line" in the text editor, and a menu key equivalent
/// would win over it. In the sidebar, ⌫ deletes the selected script.
struct MacLibraryCommands: Commands {
    let model: MacLibraryModel
    let launcher: PresenterLauncher
    let settingsRouter: MacSettingsRouter

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New script") { model.newScript() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Paste as new script") { model.pasteAsNewScript() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Divider()
            Button("Import…") { model.isImporting = true }
                .keyboardShortcut("o", modifiers: .command)
            Divider()
            PairIPhoneMenuItem(router: settingsRouter)
        }

        CommandMenu("Script") {
            ScriptMenuItems(model: model)
        }

        // Called "Presenter" (like the Presenter view), not "Prompter": the app menu already has that name.
        CommandMenu("Presenter") {
            PresenterMenuItems(launcher: launcher)
        }
    }
}

/// File → Pair an iPhone…: Settings on the iPhone tab.
private struct PairIPhoneMenuItem: View {
    let router: MacSettingsRouter
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Pair an iPhone…", systemImage: "iphone.badge.plus") {
            router.show(.iphone, using: openSettings)
        }
    }
}

/// The Presenter menu: what the keys do, as menu items, so they can be found. Everything is disabled unless a take is
/// being presented. The keys themselves are the Presenter view's (a bare Space or Esc as a menu shortcut would also fire
/// while typing in the library), so they are named in the titles; only Stop presenting has a real shortcut, ⌘. (it
/// stops at once, where Esc pauses a running take first).
struct PresenterMenuItems: View {
    let launcher: PresenterLauncher

    var body: some View {
        let controller = launcher.controller
        let isPresenting = launcher.isPresenting && controller != nil
        let state = controller?.session.engine.state ?? .idle

        Button("\(PresenterStatus.primaryAction(for: state)) (Space)", systemImage: state == .playing ? "pause.fill" : "play.fill") {
            controller?.session.togglePlay()
        }
        .disabled(!isPresenting)

        Button("Back to top (0)", systemImage: "arrow.up.to.line") {
            controller?.session.backToTop()
        }
        .disabled(!isPresenting)

        Divider()

        Button("Swap screens", systemImage: "arrow.left.arrow.right") {
            controller?.swapScreens()
        }
        .disabled(!isPresenting || controller?.isSingleScreen != false)

        Divider()

        Button("Stop presenting", systemImage: "xmark") {
            launcher.stop()
        }
        .keyboardShortcut(".", modifiers: .command)
        .disabled(!isPresenting)
    }
}

/// What the Script menu needs to know about the open library window. A plain value published from the library view
/// as a focused scene value: it is rebuilt whenever the view's body is, so the menu follows the selection (a `Commands`
/// body can't observe the model itself).
struct LibraryMenuState: Equatable {
    var hasSelection = false
    var canPrompt = false
}

extension FocusedValues {
    @Entry var libraryMenuState: LibraryMenuState?
}

/// The Script menu's items. They are only disabled when the library window says they can't apply; with no library window
/// focused (`state` is nil) they stay enabled and do nothing without an open script.
private struct ScriptMenuItems: View {
    let model: MacLibraryModel
    @FocusedValue(\.libraryMenuState) private var state

    var body: some View {
        Button("Prompt", systemImage: "play.fill") {
            if let id = model.selection { model.prompt(id) }
        }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(state?.canPrompt == false)

        Divider()

        Button("Duplicate") {
            if let id = model.selection { model.duplicate(id) }
        }
        .keyboardShortcut("d", modifiers: .command)
        .disabled(state?.hasSelection == false)

        Button("Rename…") {
            if let id = model.selection { model.beginRename(id) }
        }
        .disabled(state?.hasSelection == false)

        Divider()

        Button("Delete") {
            if let id = model.selection { model.delete(id) }
        }
        .disabled(state?.hasSelection == false)
    }
}
