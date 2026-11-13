import Foundation
#if os(iOS)
import UIKit
#endif

/// Runs an action once the app's files can be read after a restart.
///
/// Until the first unlock after the phone restarts, files and `UserDefaults` are still encrypted, yet a message from
/// the watch can launch the app in the background then. The stores always try to load first; only when that fails (or
/// finds nothing) while `UIApplication.isProtectedDataAvailable` is false do they hold off (an empty library, default
/// settings, nothing saved) and load with this once `protectedDataDidBecomeAvailableNotification` arrives, or the app
/// becomes active (which needs an unlocked phone), whichever comes first. The action runs once.
///
/// On the Mac there is no such state (`isProtectedDataAvailable` is always true), so the stores never wait and this
/// listens for nothing; `fire()` still works.
@MainActor
final class ProtectedDataWait {
    /// What the stores assume by default: UIKit's flag on iOS, always true elsewhere.
    static var isProtectedDataAvailable: Bool {
        #if os(iOS)
        UIApplication.shared.isProtectedDataAvailable
        #else
        true
        #endif
    }

    /// The notifications that mean the files can be read now.
    private static var availabilityNotifications: [Notification.Name] {
        #if os(iOS)
        [UIApplication.protectedDataDidBecomeAvailableNotification, UIApplication.didBecomeActiveNotification]
        #else
        []
        #endif
    }

    private let center: NotificationCenter
    private var tokens: [any NSObjectProtocol] = []
    private var action: (@MainActor () -> Void)?

    init(center: NotificationCenter = .default, then action: @escaping @MainActor () -> Void) {
        self.center = center
        self.action = action
        for name in Self.availabilityNotifications {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fire() }
            })
        }
    }

    /// Runs the action now (if it hasn't run) and stops listening.
    func fire() {
        cancel()
        guard let action else { return }
        self.action = nil
        action()
    }

    /// Stops listening without running the action.
    func cancel() {
        for token in tokens { center.removeObserver(token) }
        tokens = []
    }

    isolated deinit {
        for token in tokens { center.removeObserver(token) }
    }
}
