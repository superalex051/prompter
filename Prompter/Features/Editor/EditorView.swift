import SwiftUI
import UIKit

/// The writing screen: a title field, a full-height script editor, a live word count and read time,
/// and a Prompt button. Every change is saved straight away through `ScriptStore`.
struct EditorView: View {
    let scriptID: Script.ID
    var onPrompt: (Script.ID) -> Void
    /// Whether the library still has this script open. An editor that goes away while it is still open was only rebuilt
    /// for the other layout (the iPhone Duo folding or unfolding), not left by the person.
    var isOpen: (Script.ID) -> Bool = { _ in false }
    /// The library's editors on screen (see `EditorPresence`); nil where only this editor can leave the script (previews).
    var presence: EditorPresenceTracker?
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
        .onAppear { presence?.state.editorAppeared(scriptID) }
        // A new script that was never typed into shouldn't be left behind in the library. Not when the editor was only
        // rebuilt for the other layout: the script is still open there, blank or not. When the library closed the script
        // before this editor went away (a back button tap), this is where it goes; the other way round, the library drops it.
        .onDisappear {
            let left = presence?.state.editorDisappeared(scriptID, isOpen: isOpen(scriptID)) ?? !isOpen(scriptID)
            LibraryDebugLog.note("editor gone, open \(isOpen(scriptID)), left \(left)")
            if left { store.deleteIfBlank(scriptID) }
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
    /// down, and where the cursor was in the script text.
    struct Handoff: Equatable, Sendable {
        var scriptID: Script.ID
        var field: Field?
        /// The cursor or selection in the script text, in UTF-16 offsets (see `EditorSelection`); nil when not known.
        var selection: Range<Int>? = nil
    }

    /// The open editor's script, the field it types in (nil while the keyboard is down) and its cursor in the script text.
    private(set) var current: Handoff?
    /// Left by the last layout switch, until the new editor takes it.
    private(set) var pending: Handoff?

    /// The editor of `scriptID` moved its focus (nil: the keyboard went down). The cursor stays as last reported.
    mutating func focusChanged(to field: Field?, in scriptID: Script.ID) {
        let selection = current?.scriptID == scriptID ? current?.selection : nil
        current = Handoff(scriptID: scriptID, field: field, selection: selection)
    }

    /// The cursor moved in the script text of `scriptID`'s editor. The editor reports it only while typing there, so an
    /// editor that goes away, or one that has not taken the keyboard yet, never overwrites it.
    mutating func selectionChanged(to offsets: Range<Int>, in scriptID: Script.ID) {
        if current?.scriptID == scriptID {
            current?.selection = offsets
        } else {
            current = Handoff(scriptID: scriptID, field: nil, selection: offsets)
        }
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
        let sameScript = current?.scriptID == openScript
        pending = Handoff(
            scriptID: openScript,
            field: sameScript ? current?.field : nil,
            selection: sameScript ? current?.selection : nil
        )
    }

    /// The new editor of `scriptID` takes what the layout switch left for it (nil when the editor was not rebuilt by a
    /// switch, or was rebuilt for another script).
    mutating func take(for scriptID: Script.ID) -> Handoff? {
        guard let pending, pending.scriptID == scriptID else { return nil }
        self.pending = nil
        return pending
    }
}

/// The cursor in the script text as plain numbers, so it can outlive the editor it came from: a `TextSelection` points
/// into one particular string. UTF-16 offsets, the unit the text view itself counts in.
enum EditorSelection {
    /// `selection` in `text` as UTF-16 offsets, or nil when there is none, it is several ranges, or it doesn't fit `text`
    /// (the text view can report a cursor a moment before the text that goes with it).
    static func offsets(of selection: TextSelection?, in text: String) -> Range<Int>? {
        guard let selection, case .selection(let range) = selection.indices,
              range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex,
              let lower = range.lowerBound.samePosition(in: text.utf16),
              let upper = range.upperBound.samePosition(in: text.utf16)
        else { return nil }
        let start = text.utf16.distance(from: text.utf16.startIndex, to: lower)
        return start..<(start + text.utf16.distance(from: lower, to: upper))
    }

    /// A cursor (or selection) at `offsets` in `text`, kept inside the text and on whole characters, because the text may
    /// have changed since the offsets were taken.
    static func selection(at offsets: Range<Int>, in text: String) -> TextSelection {
        let lower = index(atUTF16: offsets.lowerBound, in: text)
        let upper = max(lower, index(atUTF16: offsets.upperBound, in: text))
        return lower == upper ? TextSelection(insertionPoint: lower) : TextSelection(range: lower..<upper)
    }

    /// The start of the character at UTF-16 offset `offset`, clamped to the text.
    private static func index(atUTF16 offset: Int, in text: String) -> String.Index {
        let utf16 = text.utf16
        var index = utf16.index(utf16.startIndex, offsetBy: min(max(offset, 0), utf16.count))
        while index > text.startIndex, index.samePosition(in: text) == nil {
            index = utf16.index(before: index)
        }
        return index
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
    /// The cursor in the script text, kept for a layout switch (see `EditorKeyboard`).
    @State private var bodySelection: TextSelection?
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
        let isTyping = focus != nil

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

            TextEditor(text: $bodyText, selection: $bodySelection)
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
            LibraryDebugLog.note("editor focus \(String(describing: new))")
        }
        .onChange(of: bodyText) { _, newValue in
            store.update(scriptID, body: newValue)
        }
        .onChange(of: bodySelection) { _, selection in reportSelection(selection) }
        // A new version from the Mac (sync) replaces the drafts, so the next keystroke doesn't save over it.
        .onChange(of: store.remoteChange) { _, change in adoptRemoteChange(change) }
        // Where iOS draws the bar down the side of the screen (the iPhone Duo folded, or open and held wide), Prompt and
        // Done go into it as round buttons. Everywhere else the bar is the one at the top, as it always was.
        .toolbar(readingVerticalEdge: { verticalEdge in
            if verticalEdge != nil {
                if #available(iOS 27.1, *) {
                    sideBarItems(wordCount: stats.wordCount, isTyping: isTyping)
                }
            } else {
                // Done lives in the navigation bar while the keyboard is up. A keyboard-toolbar Done floats above the keys
                // and ran into the word-count footer sitting on top of the keyboard.
                if isTyping {
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
        })
        .task {
            // A brand-new script opens ready to type, and an editor rebuilt by a layout switch (the iPhone Duo folding or
            // unfolding) types where the old one did. The short pause lets the push animation settle, because focus set
            // during the transition is often dropped; it also gives the library time to leave the handoff.
            // An editor that is already gone (rebuilt again during the switch) leaves the handoff to its replacement.
            if opensBlank, !didAutofocus {
                didAutofocus = true
                try? await Task.sleep(for: .milliseconds(450))
                let handoff = Task.isCancelled ? nil : keyboard?.state.take(for: scriptID)
                LibraryDebugLog.note("editor opened blank, handoff \(String(describing: handoff?.field))")
                if let handoff {
                    takeKeyboard(handoff)
                } else {
                    focus = .body
                }
            } else if let keyboard {
                // An existing script changes nothing here unless a layout switch left it the keyboard.
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, let handoff = keyboard.state.take(for: scriptID) else { return }
                LibraryDebugLog.note(
                    "editor takes the keyboard handoff: \(String(describing: handoff.field)), "
                        + "cursor \(handoff.selection.map { "\($0)" } ?? "none")"
                )
                takeKeyboard(handoff)
            }
        }
    }

    /// Prompt and Done in the bar down the side of the screen: Prompt right under Back, an amber circle with a black play
    /// symbol, and Done (a tick) below it while typing, so Prompt never moves. Only items with both a symbol and a title
    /// (a `Label`) go into that bar, and it draws a prominent button's symbol white whatever the style says; a symbol
    /// image in its own colour stays black. The titles are what VoiceOver reads.
    @available(iOS 27.1, *)
    @ToolbarContentBuilder
    private func sideBarItems(wordCount: Int, isTyping: Bool) -> some ToolbarContent {
        ToolbarItem(placement: .topBarPinnedTrailing) {
            Button {
                focus = nil
                onPrompt(scriptID)
            } label: {
                Label {
                    Text("Prompt")
                } icon: {
                    let play = UIImage(systemName: "play.fill") ?? UIImage()
                    Image(uiImage: play.withTintColor(.black, renderingMode: .alwaysOriginal))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(wordCount == 0)
            .accessibilityHint(wordCount == 0 ? "Add some text first" : "")
        }
        if isTyping {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    focus = nil
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
            }
        }
    }

    /// Types where the editor before the layout switch did: the cursor goes back to its place in the script text first,
    /// so the keyboard comes up there and the text scrolls to it, not to the end of the script.
    private func takeKeyboard(_ handoff: EditorKeyboard.Handoff) {
        if handoff.field == .body, let offsets = handoff.selection {
            bodySelection = EditorSelection.selection(at: offsets, in: bodyText)
        }
        focus = handoff.field
    }

    /// Tells the library where the cursor is, for a layout switch. Only while typing in the script text: an editor that is
    /// going away, or has not taken the keyboard yet, must not overwrite the place.
    private func reportSelection(_ selection: TextSelection?) {
        guard let keyboard, focus == .body, let offsets = EditorSelection.offsets(of: selection, in: bodyText) else { return }
        keyboard.state.selectionChanged(to: offsets, in: scriptID)
    }

    private func adoptRemoteChange(_ change: RemoteChange?) {
        guard let change, change.ids.contains(scriptID), let stored = store.script(id: scriptID) else { return }
        if stored.title != title { title = stored.title }
        if stored.body != bodyText {
            // The cursor stays at the same place in the new text, never past its end.
            let offsets = EditorSelection.offsets(of: bodySelection, in: bodyText)
            bodyText = stored.body
            bodySelection = offsets.map { EditorSelection.selection(at: $0, in: stored.body) }
        }
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

private extension View {
    /// `toolbar(content:)`, with `items` told where iOS draws the bar: `toolbarVerticalEdge`, the side of the screen when
    /// the bar runs down it (iOS 27.1 and later: the iPhone Duo folded, or open and held wide), nil when it runs along the
    /// top, and always nil before iOS 27.1. It is read in the same pass that builds the items, so the first frame already
    /// has the right ones.
    func toolbar<Items: ToolbarContent>(
        @ToolbarContentBuilder readingVerticalEdge items: @escaping (HorizontalEdge?) -> Items
    ) -> some View {
        modifier(VerticalEdgeToolbar(items: items))
    }
}

private struct VerticalEdgeToolbar<Items: ToolbarContent>: ViewModifier {
    let items: (HorizontalEdge?) -> Items

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.modifier(VerticalEdgeReader(items: items))
        } else {
            content.toolbar { items(nil) }
        }
    }
}

/// Reads `toolbarVerticalEdge`, which exists from iOS 27.1 (a stored environment property can't be marked available in
/// a type that runs on iOS 26).
@available(iOS 27.1, *)
private struct VerticalEdgeReader<Items: ToolbarContent>: ViewModifier {
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    let items: (HorizontalEdge?) -> Items

    func body(content: Content) -> some View {
        content.toolbar { items(verticalEdge) }
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
