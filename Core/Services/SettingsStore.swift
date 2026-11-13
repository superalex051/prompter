import Foundation
import Observation

/// Persists `PrompterSettings` as a JSON blob in `UserDefaults`.
///
/// Before the first unlock after the phone restarts (a watch message can launch the app in the background then), the
/// saved settings can't be read yet: `UserDefaults` simply has nothing under the key. So when nothing is there AND
/// `isProtectedDataAvailable` is false, the store holds the defaults, saves nothing (the first change would otherwise
/// overwrite the real settings with defaults), and reads again once protected data becomes available. Settings that can
/// be read are used at once whatever the flag says: it can read false while `App.init` runs on a normal launch.
@MainActor @Observable
final class SettingsStore {
    /// Every assignment is clamped; a real change is saved immediately (once the saved settings could be read).
    var settings: PrompterSettings {
        get { current }
        set {
            let clamped = newValue.clamped()
            guard clamped != current else { return }
            current = clamped
            save()
        }
    }

    private var current: PrompterSettings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String
    /// Waiting for the first unlock: nothing is saved until the saved settings have been read. The launch route waits
    /// for this.
    private(set) var isWaitingForProtectedData = false
    @ObservationIgnored private var protectedDataWait: ProtectedDataWait?

    /// Nothing saved and `isProtectedDataAvailable` false: the saved settings are read later, see the type's notes
    /// (`ProtectedDataWait`, listening on `notificationCenter`, or `protectedDataBecameAvailable()`).
    init(
        defaults: UserDefaults = .standard,
        key: String = "prompterSettings",
        isProtectedDataAvailable: Bool = ProtectedDataWait.isProtectedDataAvailable,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.key = key
        current = Self.saved(in: defaults, key: key) ?? PrompterSettings()
        // Anything under the key (even something undecodable) means the settings could be read.
        guard defaults.object(forKey: key) == nil, !isProtectedDataAvailable else { return }
        isWaitingForProtectedData = true
        protectedDataWait = ProtectedDataWait(center: notificationCenter) { [weak self] in
            self?.protectedDataBecameAvailable()
        }
    }

    func reset() {
        settings = PrompterSettings()
    }

    /// The phone was unlocked: saved settings that turn up now replace whatever the store held while it waited. If there
    /// are still none, there was nothing to protect, so changes made meanwhile (e.g. `-scrollMode` at a demo launch) are
    /// kept and saved. Does nothing if the store wasn't waiting.
    func protectedDataBecameAvailable() {
        guard isWaitingForProtectedData else { return }
        isWaitingForProtectedData = false
        protectedDataWait?.cancel()
        protectedDataWait = nil
        if let saved = Self.saved(in: defaults, key: key) {
            if saved != current { current = saved }
        } else if current != PrompterSettings() {
            save()
        }
    }

    private static func saved(in defaults: UserDefaults, key: String) -> PrompterSettings? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(PrompterSettings.self, from: $0) }
    }

    private func save() {
        guard !isWaitingForProtectedData, let data = try? JSONEncoder().encode(current) else { return }
        defaults.set(data, forKey: key)
    }
}
