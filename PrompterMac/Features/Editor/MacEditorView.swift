import SwiftUI

/// The writing screen: a title field, a full-height script editor, and a footer with the live word count and read time.
/// Every change is saved straight away through `ScriptStore`.
struct MacEditorView: View {
    let scriptID: Script.ID

    @Environment(ScriptStore.self) private var store

    var body: some View {
        if let script = store.script(id: scriptID) {
            MacEditorContent(script: script)
        } else {
            ContentUnavailableView("Script deleted", systemImage: "doc")
        }
    }
}

/// The editing surface. The drafts start from the script as it was when the editor opened and are never overwritten from
/// the store while typing, so the cursor never jumps. The exceptions: when the title changes in the store (a rename from
/// the sidebar) and the title field isn't being edited, the draft follows it; and a new version from the iPhone (sync)
/// replaces both drafts.
private struct MacEditorContent: View {
    private enum Field: Hashable {
        case title
    }

    private let scriptID: Script.ID
    private let storedTitle: String
    private let opensBlank: Bool

    @Environment(ScriptStore.self) private var store
    @Environment(SettingsStore.self) private var settingsStore

    @State private var title: String
    @State private var bodyText: String
    @FocusState private var focus: Field?

    init(script: Script) {
        scriptID = script.id
        storedTitle = script.title
        opensBlank = script.isBlank
        _title = State(initialValue: script.title)
        _bodyText = State(initialValue: script.body)
    }

    var body: some View {
        GeometryReader { proxy in
            let margin = MacEditorLayout.horizontalMargin(forWidth: proxy.size.width)
            VStack(spacing: 0) {
                TextField("", text: $title, prompt: Text("Title").foregroundStyle(.secondary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 28, weight: .bold))
                    .focused($focus, equals: .title)
                    .onSubmit { focusBody() }
                    .accessibilityLabel("Title")
                    .padding(.horizontal, margin)
                    .padding(.top, 22)
                    .padding(.bottom, 14)

                Divider()
                    .padding(.horizontal, margin)

                ScriptTextEditor(
                    text: $bodyText, focusRequest: bodyFocusRequest, margin: margin,
                    markdown: settingsStore.settings.markdown
                )
                    .overlay(alignment: .topLeading) {
                        if bodyText.isEmpty {
                            Text("Start typing your script…")
                                .font(.system(size: 17))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, margin)
                                .padding(.top, 14)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }

                footer(margin: margin)
            }
        }
        .onChange(of: title) { _, newValue in store.update(scriptID, title: newValue) }
        .onChange(of: bodyText) { _, newValue in store.update(scriptID, body: newValue) }
        // A new version from the iPhone (sync) replaces the drafts, so the next keystroke doesn't save over it.
        .onChange(of: store.remoteChange) { _, change in adoptRemoteChange(change) }
        // A rename from the sidebar must not be overwritten by this editor's older draft of the title.
        .onChange(of: storedTitle) { adoptStoredTitle() }
        .onChange(of: focus) { old, _ in
            if old == .title { adoptStoredTitle() }
        }
        .task {
            // A brand-new script opens ready to name. The pause lets the window finish laying out first.
            guard opensBlank else { return }
            try? await Task.sleep(for: .milliseconds(150))
            focus = .title
        }
    }

    /// The title field's Return moves into the text.
    @State private var bodyFocusRequest = 0

    private func focusBody() {
        bodyFocusRequest += 1
    }

    private func adoptRemoteChange(_ change: RemoteChange?) {
        guard let change, change.ids.contains(scriptID), let stored = store.script(id: scriptID) else { return }
        if stored.title != title { title = stored.title }
        if stored.body != bodyText { bodyText = stored.body }
    }

    /// Takes the store's title into the draft, unless the person is typing in the title field.
    private func adoptStoredTitle() {
        guard focus != .title, let stored = store.script(id: scriptID)?.title, stored != title else { return }
        title = stored
    }

    private func footer(margin: Double) -> some View {
        let markdown = settingsStore.settings.markdown
        let summary = MacScriptStats.footer(
            ofBody: bodyText, wordsPerMinute: settingsStore.settings.wordsPerMinute, markdown: markdown
        )
        return VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: summary)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                // A hint for scripts that use no notes or pauses yet; it goes away as soon as one does.
                if MacEditorTip.isShown(for: bodyText) {
                    Text(verbatim: MacEditorTip.text(markdown: markdown))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, margin)
            .padding(.vertical, 10)
        }
    }
}
