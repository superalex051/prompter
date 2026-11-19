import SwiftUI
import UniformTypeIdentifiers

/// Home screen: the script list, add/paste/import actions, delete with undo.
struct LibraryView: View {
    @Environment(ScriptStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(SyncClient.self) private var syncClient
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// The open script, pushed on the stack or in the split view's detail; see `LibraryNavigation`.
    @State private var navigation = LibraryNavigation()
    /// The window's full width, for `LibraryLayout` (nil until the first layout pass).
    @State private var windowWidth: CGFloat?
    /// The editor's keyboard across a layout switch; see `EditorKeyboard`.
    @State private var keyboard = EditorKeyboard()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var prompterTarget: PrompterTarget?
    @State private var isImporting = false
    @State private var notice: Notice?
    @State private var isRenaming = false
    @State private var renameTarget: Script?
    @State private var renameText = ""
    @State private var deletedScript: Script?
    /// The last deleted script was the open one (split view), so Undo opens it again.
    @State private var deletedWasOpen = false
    @State private var bannerHideTask: Task<Void, Never>?
    /// Where to land on launch (screenshots and UI checks), applied once both stores have loaded.
    @State private var launchRoute: LaunchRoute
    /// The settings sheet; `.sync` opens it straight on Sync with Mac (launch route).
    @State private var settingsSheet: SettingsSheet?

    /// `launchRoute`: where to land on launch; the default stays in the library.
    init(launchRoute: LaunchRoute = LaunchRoute()) {
        _launchRoute = State(initialValue: launchRoute)
    }

    /// An iPad full screen or in a large split, or the iPhone Duo open and held wide, gets the split view; an iPhone, a
    /// slide-over and the Duo folded or open and held tall keep the navigation stack. See `LibraryLayout`.
    private var layoutKind: LibraryLayout {
        LibraryLayout.choose(
            isRegularWidth: horizontalSizeClass == .regular,
            windowWidth: windowWidth,
            isPad: UIDevice.current.userInterfaceIdiom == .pad
        )
    }

    private var splits: Bool { layoutKind == .split }

    /// A store is still waiting for the first unlock after a restart (see `ScriptStore`), so the library may be empty
    /// only because it hasn't been read yet.
    private var isLoading: Bool { store.isWaitingForProtectedData || settings.isWaitingForProtectedData }

    var body: some View {
        layout
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing
            } action: { width in
                windowWidth = width
            }
            .fullScreenCover(item: $prompterTarget) { target in
                PrompterScreen(scriptID: target.id, autoStart: target.autoStart, opensSettings: target.opensSettings)
            }
            .sheet(item: $settingsSheet) { sheet in
                if sheet == .macRemote {
                    NavigationStack { MacRemoteView(showsDone: true) }
                } else {
                    AppSettingsView(opensSync: sheet == .sync)
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: ScriptImporter.importableTypes,
                allowsMultipleSelection: true,
                onCompletion: handleImport
            )
            .alert(notice?.title ?? "", isPresented: noticeIsPresented, presenting: notice) { _ in
                Button("OK") {}
            } message: { notice in
                if let message = notice.message { Text(message) }
            }
            // Outside the two layouts, so a layout switch (the iPhone Duo folding) doesn't take the alert away mid-rename.
            .alert("Rename script", isPresented: $isRenaming, presenting: renameTarget) { target in
                TextField("Title", text: $renameText)
                Button("Save") { store.rename(target.id, to: renameText) }
                Button("Cancel", role: .cancel) {}
            }
            .onChange(of: store.lastError) { _, newValue in showStoreError(newValue) }
            .onChange(of: layoutKind) { _, kind in
                keyboard.layoutChanged(openScript: navigation.openScript)
                debugNote("library layout \(kind), open \(navigation.openScript.map { "\($0)" } ?? "none")")
            }
            #if DEBUG
            .onChange(of: keyboard) { _, keyboard in
                let current = String(describing: keyboard.current?.field)
                debugNote("editor keyboard \(current), pending \(String(describing: keyboard.pending?.field))")
            }
            #endif
            .focusedSceneValue(\.newScriptAction, splits && prompterTarget == nil ? newScript : nil)
            .task {
                // Runs again each time the library reappears (e.g. after the prompter closes), which also catches an
                // error that came in while it was covered. A shown error is cleared when its alert is dismissed.
                showStoreError(store.lastError)
                applyDemoPairing()
                applyLaunchRoute()
            }
            // A store that waited for the first unlock has loaded: the launch route can find its script now.
            .onChange(of: isLoading) { applyLaunchRoute() }
    }

    @ViewBuilder
    private var layout: some View {
        if splits {
            splitLayout
        } else {
            stackLayout
        }
    }

    // MARK: Stack: a navigation stack (as on iPhone)

    private var stackLayout: some View {
        NavigationStack(path: Binding(get: { navigation.path }, set: { navigation.setPath($0) })) {
            content
                .navigationTitle("Scripts")
                .modifier(SyncSubtitle(client: syncClient))
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { settingsButton }
                    if syncClient.pairedMac != nil {
                        ToolbarItem(placement: .topBarLeading) { macRemoteButton }
                    }
                    ToolbarItem(placement: .topBarTrailing) { addMenu }
                }
                .navigationDestination(for: Script.ID.self) { id in
                    editor(for: id)
                }
                .safeAreaInset(edge: .bottom) { deleteBanner }
        }
    }

    // MARK: Split: the list on the left, the open script's editor on the right

    private var splitLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detail
        }
        // Both columns stay side by side in iPad portrait too, so the list never hides behind a button. (A window too
        // narrow for that, like the iPhone Duo open and held tall, gets the stack instead: see `LibraryLayout`.)
        .navigationSplitViewStyle(.balanced)
    }

    private var sidebar: some View {
        Group {
            if store.scripts.isEmpty {
                ContentUnavailableView {
                    Label("Your scripts", systemImage: "text.page")
                } description: {
                    Text("Scripts you write or import show up here.")
                }
            } else {
                sidebarList
            }
        }
        .navigationTitle("Scripts")
        .modifier(SyncSubtitle(client: syncClient))
        .navigationSplitViewColumnWidth(min: 340, ideal: 380, max: 480)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { settingsButton }
            if syncClient.pairedMac != nil {
                ToolbarItem(placement: .topBarLeading) { macRemoteButton }
            }
            ToolbarItem(placement: .topBarTrailing) { addMenu }
        }
        .safeAreaInset(edge: .bottom) { deleteBanner }
    }

    private var sidebarList: some View {
        // No `List(selection:)`: the system's selected row is a solid amber block (or a square amber ring with a keyboard
        // attached), which swallows the amber Prompt button. The row's own button opens the script instead, and
        // `listRowBackground` in `rows` marks the open one.
        List {
            rows
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var detail: some View {
        if let id = navigation.selection, store.script(id: id) != nil {
            // `.id` gives every script its own editor: the editor keeps its drafts in @State, which must not carry
            // over from the previous script. Switching also drops a blank new script (the editor's onDisappear).
            editor(for: id)
                .id(id)
        } else if store.scripts.isEmpty {
            emptyState
        } else {
            ContentUnavailableView {
                Label("Pick a script or make a new one", systemImage: "text.page")
            } actions: {
                Button(action: newScript) {
                    Text("New script").onAccentForeground()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if store.scripts.isEmpty {
            emptyState
        } else {
            list
        }
    }

    private var list: some View {
        List {
            rows
        }
        .listStyle(.insetGrouped)
    }

    /// The open script's editor, pushed on the stack or in the split view's detail.
    private func editor(for id: Script.ID) -> some View {
        EditorView(
            scriptID: id,
            onPrompt: { prompterTarget = PrompterTarget(id: $0) },
            isOpen: { navigation.isOpen($0) },
            keyboard: $keyboard
        )
    }

    /// The script rows, shared by the compact list and the split view's sidebar.
    private var rows: some View {
        ForEach(store.scripts) { script in
            ScriptRow(
                script: script,
                wordsPerMinute: settings.settings.wordsPerMinute,
                markdown: settings.settings.markdown,
                onOpen: { navigation.open(script.id) },
                onPrompt: { prompterTarget = PrompterTarget(id: script.id) }
            )
            // The sidebar's own selection is a solid amber block, which swallows the amber Prompt button and the grey
            // text on it. A soft tint reads as "this one is open" and leaves the row legible. (Nothing is selected on a
            // phone, so this is the list's normal background there.)
            .listRowBackground(splits && navigation.selection == script.id ? selectionBackground : nil)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    delete(script)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            // VoiceOver focus stays in the list after a delete, so Undo is offered right here too.
            .accessibilityActions {
                if deletedScript != nil {
                    Button("Undo delete", action: undoDelete)
                }
            }
            .contextMenu {
                Button {
                    prompterTarget = PrompterTarget(id: script.id)
                } label: {
                    Label("Prompt", systemImage: "play.fill")
                }
                Button {
                    store.duplicate(script.id)
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                Button {
                    beginRename(script)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    delete(script)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private var selectionBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.accentColor.opacity(0.22))
            .padding(.horizontal, 4)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No scripts yet", systemImage: "text.page")
        } description: {
            Text("Write one, paste from the clipboard, or import a .txt, .md, .rtf or .pdf file.")
        } actions: {
            Button(action: newScript) {
                Text("New script").onAccentForeground()
            }
            .buttonStyle(.borderedProminent)
            Button("Paste as new script", action: pasteAsNewScript)
            Button("Import file…") { isImporting = true }
        }
    }

    private var settingsButton: some View {
        Button {
            settingsSheet = .settings
        } label: {
            Label("Settings", systemImage: "gearshape")
        }
    }

    /// Remote for Mac (only while a Mac is paired): the Apple Watch controls Prompter for Mac through this iPhone.
    private var macRemoteButton: some View {
        Button {
            settingsSheet = .macRemote
        } label: {
            Label(MacRemoteText.title, systemImage: "applewatch.radiowaves.left.and.right")
        }
    }

    private var addMenu: some View {
        Menu {
            Button(action: newScript) {
                Label("New script", systemImage: "square.and.pencil")
            }
            Button(action: pasteAsNewScript) {
                Label("Paste as new script", systemImage: "doc.on.clipboard")
            }
            Button {
                isImporting = true
            } label: {
                Label("Import file…", systemImage: "square.and.arrow.down")
            }
        } label: {
            Label("Add script", systemImage: "plus")
        }
    }

    @ViewBuilder
    private var deleteBanner: some View {
        if let deletedScript {
            DeleteBanner(title: deletedScript.displayTitle, onUndo: undoDelete)
                // Reduce Motion: fade in place instead of sliding up from the bottom edge.
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Actions

    private func newScript() {
        navigation.open(store.create().id)
    }

    private func pasteAsNewScript() {
        guard let text = UIPasteboard.general.string, let script = store.createFromText(text) else {
            // The clipboard is empty, or the person chose "Don't Allow Paste" for Prompter; either way this says what to do.
            notice = Notice(
                title: "Couldn't paste",
                message: "Nothing to paste. Copy your script first, or allow Prompter to paste in Settings."
            )
            return
        }
        // With the split view the new script opens next to the list. On a phone it just joins the list, as before.
        if splits { navigation.open(script.id) }
    }

    private func handleImport(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            let summary = store.importFiles(at: urls)
            if splits, let first = summary.imported.first { navigation.open(first.id) }
            guard !summary.failures.isEmpty else { return }
            notice = Notice(
                title: summary.failures.count == 1 ? "Couldn't import a file" : "Couldn't import some files",
                message: summary.failures.map { "\($0.filename): \($0.message)" }.joined(separator: "\n")
            )
        case .failure(let error):
            if (error as? CocoaError)?.code == .userCancelled { return }
            // Fixed copy: the system's error text is technical ("The operation couldn't be completed. (…)").
            notice = Notice(title: "Couldn't import", message: "The file picker couldn't open that. Try again.")
        }
    }

    private func beginRename(_ script: Script) {
        renameTarget = script
        renameText = script.title
        isRenaming = true
    }

    private func delete(_ script: Script) {
        guard let removed = store.delete(script.id) else { return }
        // Deleting the open script (split view) clears the detail; Undo brings it back.
        deletedWasOpen = navigation.removed(script.id)
        showDeleteBanner(for: removed)
    }

    private func showDeleteBanner(for script: Script) {
        bannerHideTask?.cancel()
        withAnimation(.snappy) { deletedScript = script }
        AccessibilityNotification.Announcement("Deleted \(script.displayTitle). Undo is available.").post()
        bannerHideTask = nil
        guard let delay = DeleteBannerTiming.autoHideDelay(voiceOverEnabled: voiceOverEnabled) else { return }
        bannerHideTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { deletedScript = nil }
        }
    }

    private func undoDelete() {
        guard let script = deletedScript else { return }
        bannerHideTask?.cancel()
        store.restore(script)
        navigation.restored(script.id, wasOpen: deletedWasOpen)
        deletedWasOpen = false
        withAnimation(.snappy) { deletedScript = nil }
    }

    private func showStoreError(_ message: String?) {
        guard let message, !(notice?.isStoreError == true && notice?.message == message) else { return }
        notice = Notice(title: "Problem with your scripts", message: message, isStoreError: true)
    }

    /// Opens what the launch route asks for (once), as soon as both stores have loaded; see `LaunchRoute`.
    private func applyLaunchRoute() {
        guard let action = launchRoute.next(isLoading: isLoading, scripts: store.scripts) else { return }
        switch action {
        case .openSettings: settingsSheet = .settings
        case .openSyncSettings: settingsSheet = .sync
        case .openMacRemote: settingsSheet = .macRemote
        case .openEditor(let id): navigation.open(id)
        case .openPrompter(let id, let autoStart): prompterTarget = PrompterTarget(id: id, autoStart: autoStart)
        case .openPrompterSettings(let id): prompterTarget = PrompterTarget(id: id, opensSettings: true)
        }
    }

    /// Debug builds with `-duoProbe`: a line in the probe's log (layout switches and the editor's keyboard during a fold).
    private func debugNote(_ text: @autoclosure () -> String) {
        #if DEBUG
        if Self.debugOptions.duoProbe { DuoProbe.log(text()) }
        #endif
    }

    /// Debug builds: `-demoData -demoPairedMac` pairs the throwaway library with a made-up Mac (see `LaunchOptions`).
    private func applyDemoPairing() {
        #if DEBUG
        guard Self.debugOptions.demoPairedMac, syncClient.isDemo, syncClient.pairedMac == nil else { return }
        syncClient.pairing.add(
            PairedDevice(
                deviceID: "demo-mac", name: DemoData.macName, platform: .mac, key: Data(count: 32),
                pairedAt: .now, lastSyncedAt: .now
            ),
            replacingAll: true
        )
        #endif
    }

    #if DEBUG
    private static let debugOptions = LaunchOptions()
    #endif

    /// Dismissing a store error clears it in the store, so it isn't shown again and the next failure is reported.
    private var noticeIsPresented: Binding<Bool> {
        Binding(
            get: { notice != nil },
            set: { isPresented in
                guard !isPresented else { return }
                if notice?.isStoreError == true { store.clearError() }
                notice = nil
            }
        )
    }
}

// MARK: - Supporting types

/// "Synced with Sam's MacBook" under the title while a Mac is paired (see `SyncStatusText.librarySubtitle`).
private struct SyncSubtitle: ViewModifier {
    let client: SyncClient

    func body(content: Content) -> some View {
        let subtitle = SyncStatusText.librarySubtitle(
            status: client.status, macName: client.pairedMac?.name, lastSyncedAt: client.pairedMac?.lastSyncedAt
        )
        if let subtitle {
            content.navigationSubtitle(subtitle)
        } else {
            content
        }
    }
}

/// The library's sheets: the settings (on Sync with Mac for `.sync`) and Remote for Mac.
private enum SettingsSheet: Identifiable {
    case settings, sync, macRemote
    var id: Self { self }
}

private struct PrompterTarget: Identifiable {
    let id: Script.ID
    var autoStart = false
    var opensSettings = false
}

private struct Notice: Identifiable {
    let id = UUID()
    var title: String
    var message: String?
    /// Shows `ScriptStore.lastError`; dismissing it clears that error.
    var isStoreError = false
}

enum DeleteBannerTiming {
    /// How long the Undo banner stays up. With VoiceOver on it stays until Undo or the next delete: reaching it
    /// by swiping through the list can take longer than any fixed delay.
    static func autoHideDelay(voiceOverEnabled: Bool) -> Duration? {
        voiceOverEnabled ? nil : .seconds(6)
    }
}

/// "Deleted “Title”" with an Undo button; the library hides it after 6 seconds (not while VoiceOver is on).
private struct DeleteBanner: View {
    let title: String
    var onUndo: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Deleted “\(title)”")
                .font(.subheadline)
                .lineLimit(1)
                .padding(.vertical, 12)
            Spacer(minLength: 8)
            Button("Undo", action: onUndo)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
    }
}
