import SwiftUI

/// The writing screen: a title field, a full-height script editor, a live word count and read time,
/// and a Prompt button. Every change is saved straight away through `ScriptStore`.
struct EditorView: View {
    let scriptID: Script.ID
    var onPrompt: (Script.ID) -> Void
    /// Whether the library still has this script open. An editor that goes away while it is still open was only rebuilt
    /// for the other layout (the iPhone Duo folding or unfolding), not left by the person.
    var isOpen: (Script.ID) -> Bool = { _ in false }
    /// The keyboard across a layout switch (see `EditorKeyboard`); nil where the layout never switches (previews).
    var keyboard: EditorKeyboardHandoff?

    @Environment(ScriptStore.self) private var store

    var body: some View {
        Group {
            if let script = store.script(id: scriptID) {
                EditorContent(script: script, onPrompt: onPrompt, keyboard: keyboard)
            } else {
                ContentUnavailableView("Script deleted", systemImage: "doc")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        // A new script that was never typed into shouldn't be left behind in the library. Not when the editor was only
        // rebuilt for the other layout: the script is still open there, blank or not.
        .onDisappear {
            if !isOpen(scriptID) { store.deleteIfBlank(scriptID) }
        }
    }
}

/// Holds `EditorKeyboard` for the library and its editors. A plain reference that SwiftUI doesn't observe, on purpose:
/// the editor reports every focus change here, and the library has no reason to redraw for them. Only a layout switch
/// reads it.
@MainActor
final class EditorKeyboardHandoff {
    var state = EditorKeyboard()
}

/// The editor's keyboard across a layout switch. Each library layout builds its own editor, so when the iPhone Duo folds
/// or unfolds between the split view and the stack, a new editor takes over and the keyboard went down mid-sentence.
/// The open editor reports the field it types in; at a layout switch the library keeps that, and the new editor for the
/// same script puts the cursor back in that field.
struct EditorKeyboard: Equatable, Sendable {
    enum Field: Hashable, Sendable {
        case title
        case body
    }

    /// What a layout switch leaves for the next editor of `scriptID`: the field to type in, or nil to keep the keyboard
    /// down.
    struct Handoff: Equatable, Sendable {
        var scriptID: Script.ID
        var field: Field?
    }

    /// The open editor's script and the field it types in (nil while the keyboard is down).
    private(set) var current: Handoff?
    /// Left by the last layout switch, until the new editor takes it.
    private(set) var pending: Handoff?

    /// The editor of `scriptID` moved its focus (nil: the keyboard went down).
    mutating func focusChanged(to field: Field?, in scriptID: Script.ID) {
        current = Handoff(scriptID: scriptID, field: field)
    }

    /// The library opened another script, or closed the open one. What an earlier editor reported no longer applies: an
    /// editor that goes away while typing never reports the keyboard going down, so a later fold would have raised the
    /// keyboard for a script that was opened again with it down.
    mutating func openScriptChanged() {
        current = nil
        pending = nil
    }

    /// The library switched layout with `openScript` open: its new editor should type where the old one did.
    mutating func layoutChanged(openScript: Script.ID?) {
        guard let openScript else {
            pending = nil
            return
        }
        pending = Handoff(scriptID: openScript, field: current?.scriptID == openScript ? current?.field : nil)
    }

    /// The new editor of `scriptID` takes what the layout switch left for it (nil when the editor was not rebuilt by a
    /// switch, or was rebuilt for another script).
    mutating func take(for scriptID: Script.ID) -> Handoff? {
        guard let pending, pending.scriptID == scriptID else { return nil }
        self.pending = nil
        return pending
    }
}

/// The editing surface. The drafts start from the script as it was when the editor opened and are
/// never overwritten from the store while typing, so the cursor never jumps. The one exception is the title: when it
/// changes in the store (a rename from the iPad sidebar) and the title field isn't being edited, the draft follows it.
private struct EditorContent: View {
    private typealias Field = EditorKeyboard.Field

    private let scriptID: Script.ID
    /// The title as the store has it right now (the drafts below are only where typing happens).
    private let storedTitle: String
    private let opensBlank: Bool
    private let onPrompt: (Script.ID) -> Void
    private let keyboard: EditorKeyboardHandoff?

    @Environment(ScriptStore.self) private var store
    @Environment(SettingsStore.self) private var settingsStore

    @State private var title: String
    @State private var bodyText: String
    @State private var didAutofocus = false
    @FocusState private var focus: Field?

    /// Text on screen lines up with the title field: `TextEditor` already insets its text by about 5 pt.
    private let margin: CGFloat = 20
    /// The widest the writing column gets (the footer follows it, so its text lines up with the script's).
    private let columnWidth: CGFloat = 720
    private let editorTextInset: CGFloat = 5
    private let editorTopInset: CGFloat = 8

    init(script: Script, onPrompt: @escaping (Script.ID) -> Void, keyboard: EditorKeyboardHandoff?) {
        scriptID = script.id
        storedTitle = script.title
        opensBlank = script.isBlank
        self.onPrompt = onPrompt
        self.keyboard = keyboard
        _title = State(initialValue: script.title)
        _bodyText = State(initialValue: script.body)
    }

    var body: some View {
        let stats = ReadingStats(text: bodyText, markdown: settingsStore.settings.markdown)

        VStack(spacing: 0) {
            // The default placeholder is too faint on black. An explicit colour: the hierarchical `.secondary` style
            // resolves against the already dimmed placeholder colour and came out darker still.
            TextField("Title", text: $title, prompt: Text("Title").foregroundStyle(Color(.secondaryLabel)))
                .font(.title2.bold())
                .focused($focus, equals: .title)
                .accessibilityIdentifier("editor.title")
                .submitLabel(.next)
                .onSubmit { focus = .body }
                .padding(.horizontal, margin)
                .padding(.top, 8)
                .padding(.bottom, 12)

            Divider()
                .padding(.horizontal, margin)

            TextEditor(text: $bodyText)
                .font(.title3)
                .lineSpacing(6)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .focused($focus, equals: .body)
                .accessibilityLabel("Script text")
                .padding(.horizontal, margin - editorTextInset)
                .overlay(alignment: .topLeading) {
                    if bodyText.isEmpty {
                        Text("Start typing your script…")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, margin)
                            .padding(.top, editorTopInset)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
        }
        // Keeps lines a comfortable length on iPad.
        .frame(maxWidth: columnWidth)
        .frame(maxWidth: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer(for: stats)
        }
        .onChange(of: title) { _, newValue in
            store.update(scriptID, title: newValue)
        }
        // A rename from the sidebar must not be overwritten by this editor's older draft of the title.
        .onChange(of: storedTitle) { adoptStoredTitle() }
        .onChange(of: focus) { old, new in
            if old == .title { adoptStoredTitle() }
            keyboard?.state.focusChanged(to: new, in: scriptID)
        }
        .onChange(of: bodyText) { _, newValue in
            store.update(scriptID, body: newValue)
        }
        // A new version from the Mac (sync) replaces the drafts, so the next keystroke doesn't save over it.
        .onChange(of: store.remoteChange) { _, change in adoptRemoteChange(change) }
        .toolbar {
            // Done lives in the navigation bar while the keyboard is up. A keyboard-toolbar Done floats above the keys
            // and ran into the word-count footer sitting on top of the keyboard.
            if focus != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { focus = nil }
                        .fontWeight(.semibold)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    focus = nil
                    onPrompt(scriptID)
                } label: {
                    PromptButtonLabel()
                }
                .buttonStyle(.borderedProminent)
                .disabled(stats.wordCount == 0)
                .accessibilityHint(stats.wordCount == 0 ? "Add some text first" : "")
            }
        }
        .task {
            // A brand-new script opens ready to type, and an editor rebuilt by a layout switch (the iPhone Duo folding or
            // unfolding) types where the old one did. The short pause lets the push animation settle, because focus set
            // during the transition is often dropped; it also gives the library time to leave the handoff.
            if opensBlank, !didAutofocus {
                didAutofocus = true
                try? await Task.sleep(for: .milliseconds(450))
                focus = keyboard?.state.take(for: scriptID).map(\.field) ?? .body
            } else if let keyboard {
                // An existing script changes nothing here unless a layout switch left it the keyboard.
                try? await Task.sleep(for: .milliseconds(450))
                if let handoff = keyboard.state.take(for: scriptID) { focus = handoff.field }
            }
        }
    }

    private func adoptRemoteChange(_ change: RemoteChange?) {
        guard let change, change.ids.contains(scriptID), let stored = store.script(id: scriptID) else { return }
        if stored.title != title { title = stored.title }
        if stored.body != bodyText { bodyText = stored.body }
    }

    /// Takes the store's title into the draft, unless the person is typing in the title field. It reads the store, not
    /// the `storedTitle` this view was built with, because that one can be a keystroke behind.
    private func adoptStoredTitle() {
        guard focus != .title, let stored = store.script(id: scriptID)?.title, stored != title else { return }
        title = stored
    }

    private func footer(for stats: ReadingStats) -> some View {
        let wpm = settingsStore.settings.wordsPerMinute
        let words = stats.wordCount
        let readTime = TimeFormatting.clock(stats.readingSeconds(atWPM: wpm))
        let summary = "\(words.formatted()) \(words == 1 ? "word" : "words") · \(readTime) at \(Int(wpm.rounded())) wpm"

        return VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: summary)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summary)

            // A hint for scripts that use no notes or pauses yet; it goes away as soon as one does. With Markdown
            // formatting on it mentions that too.
            if EditorTip.isShown(for: bodyText) {
                Text(verbatim: EditorTip.text(markdown: settingsStore.settings.markdown))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, margin)
        .frame(maxWidth: columnWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// The one-line hint under the word count: how to write a note or a pause (and, with Markdown formatting on, bold and
/// headings). Shown only while the script has no notes or pauses. The editor itself stays plain text.
enum EditorTip {
    static let text = "Tip: start a line with // for a note, or write [pause 2] to hold."
    static let markdownText = "Tip: start a line with // for a note, or write [pause 2] to hold. Markdown works too: "
        + "**bold** shows in amber, # starts a heading."

    static func text(markdown: Bool) -> String {
        markdown ? markdownText : text
    }

    /// True when no line of `body` is a note or a pause cue.
    static func isShown(for body: String) -> Bool {
        ScriptMarkup.lines(of: body).allSatisfy { $0.kind == .text }
    }
}

#Preview("Sample script") {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "PrompterPreview-\(UUID().uuidString)", directoryHint: .isDirectory)
    let store = ScriptStore(directory: directory)
    let settings = SettingsStore(defaults: UserDefaults(suiteName: "preview-\(UUID().uuidString)") ?? .standard)

    return NavigationStack {
        EditorView(scriptID: SampleScript.id, onPrompt: { _ in })
    }
    .environment(store)
    .environment(settings)
    .preferredColorScheme(.dark)
}
