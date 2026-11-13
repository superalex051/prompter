import SwiftUI

/// Settings from the library (gear button): the same controls as the prompter's sheet, plus the sample script and a reset.
/// Reads and writes `SettingsStore` and `ScriptStore` from the environment.
struct AppSettingsView: View {
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(ScriptStore.self) private var scriptStore
    @Environment(SyncClient.self) private var syncClient
    @Environment(\.dismiss) private var dismiss

    @State private var isConfirmingReset = false
    @State private var didRestoreSample = false
    /// Pages pushed on the settings stack.
    enum Page: Hashable {
        case sync
    }

    @State private var path: [Page]

    /// `opensSync`: open straight on Sync with Mac (the `-route syncSettings` launch route).
    init(opensSync: Bool = false) {
        _path = State(initialValue: opensSync ? [.sync] : [])
    }

    var body: some View {
        @Bindable var settingsStore = settingsStore

        NavigationStack(path: $path) {
            Form {
                PrompterSettingsSections(settings: $settingsStore.settings)
                helpSection
                syncSection
                sampleScriptSection
                resetSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Page.self) { _ in SyncSettingsView() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .confirmationDialog(
                "Reset all settings?",
                isPresented: $isConfirmingReset,
                titleVisibility: .visible
            ) {
                Button("Reset all settings", role: .destructive) { self.settingsStore.reset() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Text, mirror, countdown and scrolling go back to their defaults. Your scripts are not changed.")
            }
        }
    }

    // MARK: How to use

    private var helpSection: some View {
        Section {
            NavigationLink {
                ControlsHelpView()
            } label: {
                Label("How to use", systemImage: "hand.tap")
            }
        } header: {
            Text("Controls")
        } footer: {
            Text("Touch, keyboard and Apple Watch controls, and how to write notes, pauses and Markdown.")
        }
    }

    // MARK: Sync with Mac

    private var syncSection: some View {
        Section {
            NavigationLink(value: Page.sync) {
                LabeledContent {
                    Text(SyncStatusText.settingsRowValue(macName: syncClient.pairedMac?.name))
                } label: {
                    Label("Sync with Mac", systemImage: "laptopcomputer.and.iphone")
                }
            }
        } header: {
            Text("Mac")
        } footer: {
            Text("Scripts you write or paste in Prompter on your Mac show up here, and the other way round.")
        }
    }

    // MARK: Sample script

    private var sampleExists: Bool {
        scriptStore.script(id: SampleScript.id) != nil
    }

    private var sampleScriptSection: some View {
        Section {
            Button(action: restoreSample) {
                Group {
                    if didRestoreSample {
                        Label("Sample script restored", systemImage: "checkmark.circle.fill")
                    } else {
                        Label("Restore sample script", systemImage: "arrow.counterclockwise")
                    }
                }
                .secondaryWhenDisabled()
            }
            .disabled(sampleExists)
        } header: {
            Text("Sample script")
        } footer: {
            Text(sampleFooter)
        }
    }

    private var sampleFooter: String {
        if didRestoreSample { return "“\(SampleScript.title)” is back in your library." }
        if sampleExists { return "Already in your library." }
        return "Adds “\(SampleScript.title)” back to your library."
    }

    private func restoreSample() {
        scriptStore.restoreSampleScript()
        guard sampleExists else { return }
        didRestoreSample = true
        AccessibilityNotification.Announcement("Sample script restored.").post()
    }

    // MARK: Reset

    private var resetSection: some View {
        Section {
            Button("Reset all settings", role: .destructive) {
                isConfirmingReset = true
            }
        }
    }
}

private extension View {
    /// Grey label while the button is disabled. A disabled Form button here kept its normal colours (white text, amber
    /// icon), so "Restore sample script" looked tappable when it was not.
    func secondaryWhenDisabled() -> some View {
        modifier(SecondaryWhenDisabled())
    }
}

private struct SecondaryWhenDisabled: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        if isEnabled {
            content
        } else {
            content.foregroundStyle(.secondary)
        }
    }
}

#Preview("App settings") {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "PrompterPreview-\(UUID().uuidString)", directoryHint: .isDirectory)
    let store = ScriptStore(directory: directory)
    AppSettingsView()
        .environment(SettingsStore(defaults: UserDefaults(suiteName: "PrompterPreview") ?? .standard, key: "preview"))
        .environment(store)
        .environment(SyncClient(library: store, pairing: PairingStore(directory: directory), name: "iPhone"))
        .preferredColorScheme(.dark)
}
