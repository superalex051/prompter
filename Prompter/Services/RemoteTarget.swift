import Foundation

/// Which prompter the Apple Watch controls right now. Pure: `PrompterRemoteHub` asks it on every command and status.
///
/// 1. A prompter open on the iPhone wins, exactly as before the Mac bridge (also while it is off screen: the watch then
///    asks for the iPhone to be opened).
/// 2. Otherwise, while the iPhone app is in the background with a Mac paired, the bridge is down (sync only runs in the
///    foreground): nothing to control, and the watch says so.
/// 3. Otherwise, the paired Mac, connected and presenting: commands are forwarded to it and its status is relayed.
/// 4. Otherwise nothing; with the Mac connected but not presenting the watch suggests either device.
enum RemoteTarget: Equatable, Sendable {
    case phone
    /// The Mac's latest status, as it sent it.
    case mac(PrompterStatus)
    /// Nothing to control; the note says why, when there is more to say than "no prompter".
    case none(RemoteNote?)

    /// `macStatus`: the paired Mac's presenter status while connected to it (nil when not connected or not said yet).
    static func choose(
        hasPhonePrompter: Bool,
        macStatus: PrompterStatus?,
        isMacPaired: Bool,
        isAppActive: Bool
    ) -> RemoteTarget {
        if hasPhonePrompter { return .phone }
        if isMacPaired, !isAppActive { return .none(.phoneInBackground) }
        if let macStatus {
            return macStatus.hasPrompter ? .mac(macStatus) : .none(.macConnected)
        }
        return .none(nil)
    }
}

/// The paired Mac as the remote hub sees it: its presenting status and a way to send it commands. `SyncClient` is the
/// real one (over the paired, encrypted sync connection); tests use their own.
@MainActor
protocol MacRemoteRelay: AnyObject {
    /// The Mac's presenter status while connected to it; nil otherwise.
    var macPresenterStatus: PrompterStatus? { get }
    var isMacPaired: Bool { get }
    /// Sends a command to the Mac's prompter. `reply` runs once on the main actor: the Mac's status after it, or nil
    /// (not connected, or no answer in time).
    func forward(_ command: RemoteCommand, reply: @escaping (PrompterStatus?) -> Void)
    /// Called whenever `macPresenterStatus` may have changed.
    var onMacStatusChange: () -> Void { get set }
}

extension SyncClient: MacRemoteRelay {
    var macPresenterStatus: PrompterStatus? { status == .connected ? presenterStatus : nil }
    var isMacPaired: Bool { pairedMac != nil }

    func forward(_ command: RemoteCommand, reply: @escaping (PrompterStatus?) -> Void) {
        sendRemote(command, reply: reply)
    }

    var onMacStatusChange: () -> Void {
        get { onPresenterStatusChange }
        set { onPresenterStatusChange = newValue }
    }
}
