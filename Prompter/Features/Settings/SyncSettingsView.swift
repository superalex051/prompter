import SwiftUI

/// The words the iPhone uses for sync status, in Settings → Sync with Mac and under the library's title.
enum SyncStatusText {
    /// Under "Scripts" in the library; nil when no Mac is paired.
    static func librarySubtitle(status: SyncClient.Status, macName: String?, lastSyncedAt: Date?, now: Date = .now) -> String? {
        guard let macName else { return nil }
        switch status {
        case .notPaired: return nil
        case .connected: return "Synced with \(macName)"
        case .connecting, .searching: return "Looking for \(macName)…"
        case .notFound: return "Mac not found"
        case .refused: return "Your Mac no longer recognizes this iPhone"
        case .incompatible: return "Update Prompter on your Mac"
        case .noPermission: return "Local Network is off for Prompter"
        case .paused: return lastSyncedAt.map { "Last synced \(relative($0, now: now))" }
        }
    }

    /// The status line in Settings → Sync with Mac.
    static func detail(status: SyncClient.Status, macName: String, lastSyncedAt: Date?, now: Date = .now) -> String {
        switch status {
        case .notPaired: return "Not paired."
        case .connected: return "Connected. Scripts sync as you write them."
        case .connecting: return "Connecting to \(macName)…"
        case .searching: return "Looking for \(macName)…"
        case .notFound:
            let last = lastSyncedAt.map { " Last synced \(relative($0, now: now))." } ?? ""
            return "\(macName) isn't on this network. Open Prompter on your Mac, on the same Wi-Fi.\(last)"
        case .refused: return "Your Mac no longer recognizes this iPhone. Pair again."
        case .incompatible: return "\(macName) has a newer Prompter. Update Prompter on this iPhone to sync."
        case .noPermission: return "Prompter can't look for your Mac. Turn on Local Network for Prompter in the Settings app."
        case .paused: return lastSyncedAt.map { "Last synced \(relative($0, now: now))." } ?? "Not synced yet."
        }
    }

    /// Shown under "Looking for Macs…" once it has been looking for a while.
    static let notSeeingMacHint = "Not seeing your Mac? On the Mac, open Prompter → Settings → iPhone and click Pair an iPhone. Check both are on the same Wi-Fi and Local Network is on for Prompter."

    /// How long "Looking for Macs…" shows before the hint joins it.
    static let notSeeingMacPatience: Duration = .seconds(8)

    /// The trailing text of the "Sync with Mac" row in Settings: the Mac's name, or "Not paired".
    static func settingsRowValue(macName: String?) -> String {
        macName ?? "Not paired"
    }

    /// A pairing failure as shown: a wrong code also says how long codes last.
    static func pairingFailure(_ message: String) -> String {
        guard message.hasPrefix("That code didn't work"), !message.contains("expire") else { return message }
        return "\(message) Codes expire after 5 minutes."
    }

    static func relative(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        return date.formatted(.relative(presentation: .named, unitsStyle: .wide).locale(Locale(identifier: "en_US")))
    }
}

/// Settings → Sync with Mac: the Macs found nearby to pair with (tap one, enter its code), or the paired Mac with its
/// status, Sync now and Forget.
struct SyncSettingsView: View {
    @Environment(SyncClient.self) private var client
    @Environment(\.openURL) private var openURL

    @State private var macForCode: SyncClient.FoundMac?
    @State private var code = ""
    @State private var isConfirmingForget = false
    /// "Looking for Macs…" has gone on for a while: the hint shows.
    @State private var showsNotSeeingHint = false

    var body: some View {
        Form {
            if client.pairing.pairingDataWasReset {
                Section {
                    Label(PairingStore.pairingResetMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Dismiss") { client.pairing.acknowledgePairingReset() }
                }
            }
            if let mac = client.pairedMac {
                pairedSections(mac)
            } else {
                pairingSections
            }
        }
        .navigationTitle("Sync with Mac")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "Enter the code",
            isPresented: Binding(get: { macForCode != nil }, set: { if !$0 { macForCode = nil } }),
            presenting: macForCode
        ) { mac in
            TextField(SyncPairing.displayCode("123456789012"), text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
            Button("Pair") { client.pair(with: mac, code: code) }
            Button("Cancel", role: .cancel) {}
        } message: { mac in
            Text("Type the \(SyncPairing.codeLength)-digit code shown on \(mac.name), in Prompter → Settings → iPhone.")
        }
        .confirmationDialog("Forget this Mac?", isPresented: $isConfirmingForget, titleVisibility: .visible) {
            Button("Forget Mac", role: .destructive) { client.forget() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scripts stop syncing. The scripts already on this iPhone stay here. To sync again, pair again.")
        }
        .task(id: client.pairableMacs.isEmpty) {
            showsNotSeeingHint = false
            guard client.pairableMacs.isEmpty else { return }
            try? await Task.sleep(for: SyncStatusText.notSeeingMacPatience)
            guard !Task.isCancelled else { return }
            showsNotSeeingHint = true
        }
        .onAppear { client.setDiscovering(true) }
        .onDisappear {
            client.setDiscovering(false)
            client.clearPairingState()
        }
    }

    // MARK: Not paired

    @ViewBuilder
    private var pairingSections: some View {
        Section {
            if client.status == .noPermission {
                Text(SyncStatusText.detail(status: .noPermission, macName: "your Mac", lastSyncedAt: nil))
                    .foregroundStyle(.secondary)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            } else if client.pairableMacs.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Looking for Macs…")
                        .foregroundStyle(.secondary)
                }

            } else {
                ForEach(client.pairableMacs) { mac in
                    Button {
                        code = ""
                        client.clearPairingState()
                        if client.checkCanPair(with: mac) { macForCode = mac }
                    } label: {
                        HStack {
                            Label(mac.name, systemImage: "laptopcomputer")
                                .foregroundStyle(.primary)
                            Spacer()
                            if client.pairingState == .pairing(macName: mac.name) {
                                ProgressView()
                            } else if client.pairingProblem(with: mac) != nil {
                                Text("Needs an update")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Pair")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .disabled(isPairing)
                }
            }
        } header: {
            Text("Macs showing a code")
        } footer: {
            // After a while of looking, the footer's steps give way to what to check.
            if showsNotSeeingHint, client.pairableMacs.isEmpty {
                Text(SyncStatusText.notSeeingMacHint)
                    .accessibilityIdentifier("sync.notSeeingMac")
            } else {
                Text("On your Mac, open Prompter, choose Prompter → Settings → iPhone, and click Pair an iPhone. Then tap your Mac here and enter the code. Both need to be on the same Wi-Fi.")
            }
        }

        if case .failed(let message) = client.pairingState {
            Section {
                Label(SyncStatusText.pairingFailure(message), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var isPairing: Bool {
        if case .pairing = client.pairingState { return true }
        return false
    }

    // MARK: Paired

    @ViewBuilder
    private func pairedSections(_ mac: PairedDevice) -> some View {
        Section {
            LabeledContent("Mac", value: mac.name)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(client.status == .connected ? Color.green : Color.secondary.opacity(0.6))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(SyncStatusText.detail(
                        status: client.status, macName: mac.name, lastSyncedAt: mac.lastSyncedAt, now: context.date
                    ))
                    .foregroundStyle(.secondary)
                }
            }
            if client.status == .refused {
                Button("Pair again") { pairAgain(with: mac) }
                    .accessibilityIdentifier("sync.pairAgain")
                if case .failed(let message) = client.pairingState {
                    Label(SyncStatusText.pairingFailure(message), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } else {
                Button("Sync now") { client.syncNow() }
                    .disabled(client.status == .connecting)
            }
        } header: {
            Text("Paired Mac")
        } footer: {
            Text("Scripts you write, paste or delete on one show up on the other while Prompter is open on both. When you open Prompter later, it catches up.")
        }

        Section {
            NavigationLink {
                MacRemoteView()
            } label: {
                Label(MacRemoteText.title, systemImage: "applewatch.radiowaves.left.and.right")
            }
            .accessibilityIdentifier("sync.macRemote")
        } footer: {
            Text("While Prompter for Mac presents, your Apple Watch controls it through this iPhone.")
        }

        if client.status == .noPermission {
            Section {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        }

        Section {
            Button(client.status == .refused ? "Forget" : "Forget this Mac", role: .destructive) { isConfirmingForget = true }
        }
    }

    /// The Mac forgot this iPhone: pairing again starts with its code. If that Mac is in sight, its code prompt opens at
    /// once; if not, forgetting it here brings back the list of Macs to pick from once it appears.
    private func pairAgain(with mac: PairedDevice) {
        if let found = client.pairableMacs.first(where: { $0.name == mac.name }) ?? client.pairableMacs.first {
            code = ""
            client.clearPairingState()
            if client.checkCanPair(with: found) { macForCode = found }
        } else {
            client.forget()
        }
    }
}

#Preview("Sync with Mac") {
    let directory = FileManager.default.temporaryDirectory.appending(path: "PrompterPreview-\(UUID().uuidString)")
    let store = ScriptStore(directory: directory)
    NavigationStack {
        SyncSettingsView()
    }
    .environment(SyncClient(library: store, pairing: PairingStore(directory: directory), name: "iPhone"))
    .preferredColorScheme(.dark)
}
