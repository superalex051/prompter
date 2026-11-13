import WatchKit

/// Plays the remote's haptics on the watch.
@MainActor
enum Haptics {
    static func play(_ haptic: RemoteHaptic) {
        WKInterfaceDevice.current().play(haptic.watchHaptic)
    }

    /// A command didn't reach the phone.
    static func playFailure() {
        WKInterfaceDevice.current().play(.failure)
    }
}

extension RemoteHaptic {
    var watchHaptic: WKHapticType {
        switch self {
        case .countdownTick: .click
        case .go: .start
        case .finished: .success
        }
    }
}
