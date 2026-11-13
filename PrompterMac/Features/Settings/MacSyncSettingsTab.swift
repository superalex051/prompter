import AppKit
import SwiftUI

/// The words the Mac uses for sync status, in Settings → iPhone and under the library.
enum MacSyncStatusText {
    /// "Connected" or "Last synced 5 minutes ago" / "Not synced yet".
    static func deviceStatus(isConnected: Bool, lastSyncedAt: Date?, now: Date = .now) -> String {
        if isConnected { return "Connected" }
        guard let lastSyncedAt else { return "Not synced yet" }
        return "Last synced \(relative(lastSyncedAt, now: now))"
    }

    /// The line under the library's script list; nil when no iPhone is paired.
    static func libraryLine(devices: [PairedDevice], connected: Set<String>, now: Date = .now) -> String? {
        guard !devices.isEmpty else { return nil }
        if let device = devices.first(where: { connected.contains($0.deviceID) }) {
            return "Synced with \(device.name)"
        }
        let latest = devices.compactMap(\.lastSyncedAt).max()
        guard let latest else { return devices.count == 1 ? "\(devices[0].name) not connected" : "No iPhone connected" }
        return "Last synced \(relative(latest, now: now))"
    }

    /// "Expires in 4:32".
    static func expiry(_ expiresAt: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(expiresAt.timeIntervalSince(now).rounded(.up)))
        return "Expires in \(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    /// Shown when the Mac can't advertise itself: almost always Local Network access is off for Prompter.
    static let localNetworkWarning = "Prompter can't be found on your network. Turn on Local Network for Prompter in System Settings → Privacy & Security → Local Network."

    /// Where the "Open Local Network settings" button goes.
    static let localNetworkSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!

    /// How long the listener may stay in `.starting` before the Local Network hint shows.
    static let startingPatience: Duration = .seconds(3)

    /// How long a pairing message stays on screen.
    static let pairingMessageLifetime: Duration = .seconds(10)

    /// Whether the listener state alone calls for the Local Network hint: it failed, or (`startedLongAgo`) it has been
    /// starting for longer than `startingPatience`.
    static func warnsAboutLocalNetwork(_ state: SyncHost.ListenerState, startedLongAgo: Bool) -> Bool {
        switch state {
        case .failed: true
        case .starting: startedLongAgo
        case .off, .advertising: false
        }
    }

    /// Under the pairing code: an iPhone or iPad from before 12-digit codes asks for 6 digits and can't pair with this Mac.
    static let olderDeviceHint = "If your iPhone or iPad asks for a 6-digit code, update Prompter on it first."

    /// "Paired with Sam's iPhone." is good news; everything else the host says about pairing went wrong.
    static func isPairingFailure(_ message: String) -> Bool {
        !message.hasPrefix("Paired with")
    }

    static func relative(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        return date.formatted(.relative(presentation: .named, unitsStyle: .wide).locale(Locale(identifier: "en_US")))
    }
}

/// Settings → iPhone: pair an iPhone with a 12-digit code, see the paired iPhones and their status, forget one.
struct MacSyncSettingsTab: View {
    @Environment(SyncHost.self) private var host
    @State private var deviceToForget: PairedDevice?
    /// The listener has failed, or has been starting for too long: the Local Network hint shows (until it advertises).
    @State private var showsLocalNetworkHint = false

    var body: some View {
        Form {
            pairingSection
            devicesSection
        }
        .formStyle(.grouped)
        .task(id: host.listenerState) { await watchListener() }
        .task(id: host.pairingMessage) { await expirePairingMessage() }
        .onDisappear { host.clearPairingMessage() }
        .confirmationDialog(
            "Forget \(deviceToForget?.name ?? "this iPhone")?",
            isPresented: Binding(get: { deviceToForget != nil }, set: { if !$0 { deviceToForget = nil } }),
            titleVisibility: .visible,
            presenting: deviceToForget
        ) { device in
            Button("Forget", role: .destructive) { host.forget(deviceID: device.deviceID) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Scripts stop syncing with it. The scripts already on both stay where they are. To sync again, pair it again.")
        }
    }

    // MARK: Status watching

    /// Raises the Local Network hint when the listener fails or stays `.starting`, and drops it once it advertises.
    private func watchListener() async {
        switch host.listenerState {
        case .off, .advertising:
            showsLocalNetworkHint = false
        case .failed:
            showsLocalNetworkHint = true
        case .starting:
            guard !showsLocalNetworkHint else { return }
            try? await Task.sleep(for: MacSyncStatusText.startingPatience)
            guard !Task.isCancelled else { return }
            showsLocalNetworkHint = MacSyncStatusText.warnsAboutLocalNetwork(host.listenerState, startedLongAgo: true)
        }
    }

    /// A pairing message goes away by itself after a while.
    private func expirePairingMessage() async {
        guard host.pairingMessage != nil else { return }
        try? await Task.sleep(for: MacSyncStatusText.pairingMessageLifetime)
        guard !Task.isCancelled else { return }
        host.clearPairingMessage()
    }

    // MARK: Pairing

    private var pairingSection: some View {
        Section {
            if showsLocalNetworkHint {
                localNetworkHint
            }
            if host.pairing.pairingDataWasReset {
                HStack(alignment: .firstTextBaseline) {
                    Label(PairingStore.pairingResetMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Dismiss") { host.pairing.acknowledgePairingReset() }
                        .controlSize(.small)
                }
            }
            if let window = host.pairingWindow {
                VStack(spacing: 10) {
                    Text("Enter this code on your iPhone")
                        .font(.headline)
                    Text(SyncPairing.displayCode(window.code))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .tracking(3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(Color.accentColor)
                        .textSelection(.enabled)
                        .accessibilityLabel("Pairing code \(window.code.map(String.init).joined(separator: " "))")
                    Text("On the iPhone: Prompter → Settings → Sync with Mac → \(host.name).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text(MacSyncStatusText.olderDeviceHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if let expiresAt = window.expiresAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(MacSyncStatusText.expiry(expiresAt, now: context.date))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                        Button("Cancel") { host.cancelPairing() }
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sync scripts with your iPhone")
                        if let message = host.pairingMessage {
                            if MacSyncStatusText.isPairingFailure(message) {
                                Label(message, systemImage: "exclamationmark.triangle.fill")
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                            } else {
                                Label(message, systemImage: "checkmark.circle.fill")
                                    .font(.callout)
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    Spacer()
                    Button {
                        host.beginPairing()
                    } label: {
                        Text("Pair an iPhone").onAccentForeground()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        } header: {
            Text("iPhone sync")
        } footer: {
            Text("Keep the iPhone on the same Wi-Fi as this Mac. Scripts you write or paste on one show up on the other while Prompter is open on both.")
        }
    }

    private var localNetworkHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(MacSyncStatusText.localNetworkWarning, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Local Network settings") {
                NSWorkspace.shared.open(MacSyncStatusText.localNetworkSettingsURL)
            }
            .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sync.localNetworkHint")
    }

    // MARK: Paired iPhones

    private var devicesSection: some View {
        Section("Paired iPhones") {
            if host.pairing.devices.isEmpty {
                Text("No iPhone paired yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(host.pairing.devices) { device in
                    HStack(spacing: 12) {
                        Image(systemName: device.platform == .iPad ? "ipad" : "iphone")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                statusLine(for: device, now: context.date)
                            }
                        }
                        Spacer()
                        Button("Forget…") { deviceToForget = device }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func statusLine(for device: PairedDevice, now: Date) -> some View {
        let connected = host.isConnected(device.deviceID)
        return HStack(spacing: 5) {
            Circle()
                .fill(connected ? Color.green : Color.secondary.opacity(0.6))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(MacSyncStatusText.deviceStatus(isConnected: connected, lastSyncedAt: device.lastSyncedAt, now: now))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// The small sync line at the bottom of the library's sidebar ("Synced with iPhone"); nothing when no iPhone is paired.
struct MacSyncIndicator: View {
    @Environment(SyncHost.self) private var host
    @Environment(MacSettingsRouter.self) private var settingsRouter
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let line = MacSyncStatusText.libraryLine(
                devices: host.pairing.devices, connected: host.connectedDeviceIDs, now: context.date
            ) {
                let connected = !host.connectedDeviceIDs.isEmpty
                Label {
                    Text(line)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: connected ? "arrow.triangle.2.circlepath" : "iphone.slash")
                        .foregroundStyle(connected ? Color.accentColor : .secondary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            } else {
                Button {
                    settingsRouter.show(.iphone, using: openSettings)
                } label: {
                    Label("Pair an iPhone…", systemImage: "iphone.badge.plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .help("Open Settings → iPhone to pair an iPhone")
                .accessibilityIdentifier("library.pairIPhone")
            }
        }
    }
}
