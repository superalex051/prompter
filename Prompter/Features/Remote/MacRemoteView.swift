import SwiftUI
import UIKit

/// The words of the Remote for Mac screen. Pure, so tests can check them.
enum MacRemoteText {
    static let title = "Remote for Mac"
    static let keepOpen = "Keep this open; your Apple Watch controls the Mac through this iPhone."
    static let notPresenting = "Not presenting"
    static let notPresentingHint = "On your Mac, pick a script and click Prompt. It shows up here."
    static let notConnected = "Not connected"

    /// The line about the connection: "Connected to Sam's MacBook Pro", or what sync says while it isn't.
    static func connection(status: SyncClient.Status, macName: String) -> String {
        status == .connected
            ? "Connected to \(macName)"
            : SyncStatusText.detail(status: status, macName: macName, lastSyncedAt: nil)
    }

    /// The line about the watch.
    static func watch(isReachable: Bool, isPaired: Bool) -> String {
        if !isPaired { return "No Apple Watch paired with this iPhone." }
        return isReachable ? "Apple Watch connected." : "Open Prompter on your Apple Watch."
    }
}

/// Remote for Mac: shows what Prompter for Mac is presenting, big and simple, with the same controls as the watch. While
/// it is open the screen stays awake, so the iPhone app stays in the foreground and keeps the sync connection (the
/// bridge between the Apple Watch and the Mac) alive.
struct MacRemoteView: View {
    @Environment(SyncClient.self) private var client
    @Environment(PrompterRemoteHub.self) private var hub: PrompterRemoteHub?
    @Environment(\.dismiss) private var dismiss
    /// Presented as a sheet (from the library): a Done button closes it.
    var showsDone = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                connectionCard
                presenterCard
                Text(MacRemoteText.keepOpen)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("macRemote.keepOpen")
            }
            .padding(16)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(MacRemoteText.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDone {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        // The screen stays on while this is open: a locked iPhone (or one in the background) can't relay the watch.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    // MARK: Connection

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(client.status == .connected ? Color.green : Color.secondary.opacity(0.6))
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text(MacRemoteText.connection(status: client.status, macName: client.pairedMac?.name ?? "your Mac"))
                    .font(.subheadline.weight(.semibold))
            }
            if let hub {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "applewatch")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(MacRemoteText.watch(isReachable: hub.isReachable, isPaired: hub.isPaired))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(white: 0.11), in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }

    // MARK: The Mac's prompter

    @ViewBuilder
    private var presenterCard: some View {
        if let status = client.macPresenterStatus, status.hasPrompter {
            presenting(status)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(client.status == .connected ? MacRemoteText.notPresenting : MacRemoteText.notConnected)
                    .font(.title2.weight(.bold))
                if client.status == .connected {
                    Text(MacRemoteText.notPresentingHint)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(Color(white: 0.11), in: .rect(cornerRadius: 20))
            .accessibilityElement(children: .combine)
        }
    }

    private func presenting(_ status: PrompterStatus) -> some View {
        // The watch's own wording, so both say the same.
        let model = RemoteDisplayModel(status: status, isReachable: true)
        return VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text(model.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(model.stateText)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(model.countdownDigit != nil ? Color.accentColor : .primary)
                    .accessibilityIdentifier("macRemote.state")
            }
            Text(model.countdownDigit.map(String.init) ?? model.timeText)
                .font(.system(size: 76, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityLabel("Time left")
                .accessibilityValue(model.timeAccessibilityValue)
            ProgressView(value: model.progress)
                .tint(Color.accentColor)
                .accessibilityLabel("Progress")
            Text(model.speedLabel)
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
            controls(model)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Color(white: 0.11), in: .rect(cornerRadius: 24))
    }

    private func controls(_ model: RemoteDisplayModel) -> some View {
        HStack(spacing: 10) {
            RemoteTile(symbol: "arrow.up.to.line", label: "Back to top") { send(.backToTop) }
            RemoteTile(symbol: "gobackward", label: "Jump back") { send(.jumpBack) }
            Button { send(model.primaryCommand) } label: {
                Label(model.primaryButtonTitle, systemImage: model.primarySymbol)
                    .labelStyle(.iconOnly)
                    .font(.system(size: 28, weight: .heavy))
                    .frame(width: 76, height: 76)
                    .onAccentForeground()
                    .background(Color.accentColor, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.primaryButtonTitle)
            RemoteTile(symbol: "minus", label: "Slower") { send(.speedStep(-5)) }
                .disabled(!model.speedControlsEnabled)
            RemoteTile(symbol: "plus", label: "Faster") { send(.speedStep(5)) }
                .disabled(!model.speedControlsEnabled)
        }
    }

    private func send(_ command: RemoteCommand) {
        client.sendRemote(command) { _ in }
    }
}

/// A square control on a dark tile, like the watch's.
private struct RemoteTile: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .bold))
                .frame(width: 48, height: 48)
                .foregroundStyle(isEnabled ? Color.white : Color(white: 0.4))
                .background(Color(white: 0.2), in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

#Preview("Remote for Mac") {
    let directory = FileManager.default.temporaryDirectory.appending(path: "PrompterPreview-\(UUID().uuidString)")
    let store = ScriptStore(directory: directory)
    NavigationStack {
        MacRemoteView()
    }
    .environment(SyncClient(library: store, pairing: PairingStore(directory: directory), name: "iPhone"))
    .preferredColorScheme(.dark)
}
