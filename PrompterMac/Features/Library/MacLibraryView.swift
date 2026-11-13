import SwiftUI

/// The Mac library: scripts in a sidebar (with search) and the open script's editor in the detail.
/// All behaviour is in `MacLibraryModel`; the menu commands (`MacLibraryCommands`) drive the same model.
struct MacLibraryView: View {
    @Bindable var model: MacLibraryModel
    var launch = LibraryLaunchOptions()

    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDropTargeted = false
    @State private var didApplyLaunchRoute = false

    private var store: ScriptStore { model.store }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 270, ideal: 320, max: 460)
        } detail: {
            detail
        }
        .navigationTitle(model.selectedScript?.displayTitle ?? "Prompter")
        .overlay { dropOverlay }
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDrop(urls)
        } isTargeted: { isDropTargeted = $0 }
        .fileImporter(
            isPresented: $model.isImporting,
            allowedContentTypes: ImportableFiles.contentTypes,
            allowsMultipleSelection: true,
            onCompletion: model.handleImporter
        )
        .alert(model.notice?.title ?? "", isPresented: noticeIsPresented, presenting: model.notice) { _ in
            Button("OK") {}
        } message: { notice in
            if let message = notice.message { Text(message) }
        }
        .alert("Rename script", isPresented: renameIsPresented) {
            TextField("Title", text: $model.renameText)
            Button("Save") { model.commitRename() }
            Button("Cancel", role: .cancel) { model.renameTarget = nil }
        }
        .focusedSceneValue(
            \.libraryMenuState,
            LibraryMenuState(hasSelection: model.selectedScript != nil, canPrompt: model.canPrompt)
        )
        .onChange(of: store.lastError) { model.showStoreError() }
        .onChange(of: undoManager, initial: true) { model.undoManager = undoManager }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.abandonSelection()
        }
        .task {
            model.showStoreError()
            await applyLaunchRoute()
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: selectionBinding) {
            ForEach(model.filteredScripts()) { script in
                MacScriptRow(
                    script: script, wordsPerMinute: settingsStore.settings.wordsPerMinute,
                    markdown: settingsStore.settings.markdown
                )
                    .tag(script.id)
                    .contextMenu { rowMenu(for: script) }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search scripts")
        .onDeleteCommand {
            if let id = model.selection { model.delete(id) }
        }
        .overlay { sidebarEmptyState }
        .safeAreaInset(edge: .bottom, spacing: 0) { MacSyncIndicator() }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button("Paste as new script", systemImage: "doc.on.clipboard", action: model.pasteAsNewScript)
                    Button("Import…", systemImage: "square.and.arrow.down") { model.isImporting = true }
                } label: {
                    Label("New script", systemImage: "square.and.pencil")
                } primaryAction: {
                    model.newScript()
                }
                .help("New script (⌘N)")
            }
        }
        .navigationTitle("Scripts")
    }

    private var selectionBinding: Binding<Script.ID?> {
        Binding(get: { model.selection }, set: { model.select($0) })
    }

    @ViewBuilder
    private var sidebarEmptyState: some View {
        // (An empty library says its piece once, in the detail: "Write your first script".)
        if !store.scripts.isEmpty, model.filteredScripts().isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        }
    }

    @ViewBuilder
    private func rowMenu(for script: Script) -> some View {
        Button("Prompt", systemImage: "play.fill") { model.prompt(script.id) }
            .disabled(ReadingStats(text: script.body).wordCount == 0)
        Divider()
        Button("Duplicate", systemImage: "plus.square.on.square") { model.duplicate(script.id) }
        Button("Rename…", systemImage: "pencil") { model.beginRename(script.id) }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { model.delete(script.id) }
    }

    @ViewBuilder
    private var deleteBanner: some View {
        if let script = model.deletedScript {
            MacDeleteBanner(title: script.displayTitle, onUndo: model.undoDelete)
                .frame(maxWidth: 400)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .animation(.snappy, value: script.id)
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        Group {
            if let id = model.selection, store.script(id: id) != nil {
                // `.id` gives every script its own editor, so drafts and the cursor never carry over from another script.
                MacEditorView(scriptID: id)
                    .id(id)
            } else if store.scripts.isEmpty {
                emptyLibraryState
            } else {
                noSelectionState
            }
        }
        .overlay(alignment: .bottomTrailing) { deleteBanner }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if let id = model.selection { model.prompt(id) }
                } label: {
                    MacPromptButtonLabel()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canPrompt)
                .help(model.canPrompt ? "Prompt this script (⌘↩)" : "Add some text first")
            }
        }
    }

    private var emptyLibraryState: some View {
        ContentUnavailableView {
            Label("Write your first script", systemImage: "text.page")
        } description: {
            Text("Write one, paste from the clipboard, or import a .txt, .md, .rtf or .pdf file. You can also drop files here.")
        } actions: {
            HStack(spacing: 10) {
                Button { model.newScript() } label: {
                    Text("New script").onAccentForeground()
                }
                .buttonStyle(.borderedProminent)
                Button("Paste as new script") { model.pasteAsNewScript() }
                Button("Import…") { model.isImporting = true }
            }
            .controlSize(.large)
            .fixedSize()
        }
    }

    private var noSelectionState: some View {
        ContentUnavailableView {
            Label("Pick a script or make a new one", systemImage: "text.page")
        } actions: {
            Button { model.newScript() } label: {
                Text("New script").onAccentForeground()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: Drop

    @ViewBuilder
    private var dropOverlay: some View {
        if isDropTargeted {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 14))
                .overlay {
                    Label("Drop to import", systemImage: "square.and.arrow.down")
                        .font(.title3.weight(.semibold))
                }
                .padding(8)
                .allowsHitTesting(false)
        }
    }

    // MARK: Alerts and launch route

    private var noticeIsPresented: Binding<Bool> {
        Binding(get: { model.notice != nil }, set: { if !$0 { model.noticeDismissed() } })
    }

    private var renameIsPresented: Binding<Bool> {
        Binding(get: { model.renameTarget != nil }, set: { if !$0 { model.renameTarget = nil } })
    }

    /// Opens what a debug launch asks for, once (screenshots and checks).
    private func applyLaunchRoute() async {
        guard !didApplyLaunchRoute else { return }
        didApplyLaunchRoute = true
        if model.selection == nil, let first = store.scripts.first { model.select(first.id) }
        switch launch.route {
        case .library:
            break
        case .settings:
            openSettings()
        case .deleted:
            if store.scripts.count > 1 { model.delete(store.scripts[1].id) }
        }
    }
}

// MARK: - Pieces

/// Title, first line and stats on the left, like the iPhone library row.
struct MacScriptRow: View {
    let script: Script
    let wordsPerMinute: Double
    var markdown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(script.displayTitle)
                .font(.headline)
                .lineLimit(1)
            if !script.firstLine.isEmpty {
                Text(script.firstLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(MacScriptStats.rowDetail(of: script, wordsPerMinute: wordsPerMinute, markdown: markdown))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 1)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// "Prompt" with a play icon, in black on the amber accent. An HStack, not a Label: in a toolbar the system draws a Label
/// itself (white icon only, ignoring the foreground style).
struct MacPromptButtonLabel: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "play.fill")
                .accessibilityHidden(true)
            Text("Prompt")
        }
        .fontWeight(.semibold)
        .onAccentForeground()
    }
}

extension View {
    /// Label colour for a `.borderedProminent` button on the amber accent. Black, because white on #FFB020 is only about
    /// 1.8:1. A disabled button gets a grey fill, so its label falls back to `.secondary`.
    func onAccentForeground() -> some View {
        modifier(OnAccentForeground())
    }
}

private struct OnAccentForeground: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.foregroundStyle(isEnabled ? AnyShapeStyle(Color.black) : AnyShapeStyle(.secondary))
    }
}

/// "Deleted “Title”   Undo delete", floating at the bottom right of the window for a few seconds.
private struct MacDeleteBanner: View {
    let title: String
    var onUndo: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Deleted “\(title)”")
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Undo delete", action: onUndo)
                .buttonStyle(.borderless)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(white: 0.2), in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
        .padding(10)
        .accessibilityElement(children: .contain)
    }
}
