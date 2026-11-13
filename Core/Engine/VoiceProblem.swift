import Foundation

/// Why voice-follow can't listen. The prompter then scrolls at the WPM pace and says so.
enum VoiceProblem: Equatable, Sendable {
    case microphoneDenied
    case speechDenied
    /// No on-device recogniser for the script's language on this device.
    case unsupported
    /// The on-device speech model isn't on the device and couldn't be downloaded.
    case modelUnavailable
    /// The microphone or the recogniser failed while listening.
    case failed

    /// One plain sentence for the HUD and the settings footer, ending with what happens instead.
    var message: String {
        switch self {
        case .microphoneDenied: "Voice needs microphone access. Scrolling at your set pace instead."
        case .speechDenied: "Voice needs speech recognition access. Scrolling at your set pace instead."
        case .unsupported: "Voice can't listen in this language on this device. Scrolling at your set pace instead."
        case .modelUnavailable: "Voice needs a one-time download of the speech model. Connect to the internet and try again. Scrolling at your set pace instead."
        case .failed: "Voice stopped listening. Scrolling at your set pace instead."
        }
    }

    /// What to do about it, for the settings footer; nil when there is nothing to do.
    var remedy: String? {
        switch self {
        case .microphoneDenied: "Turn on Microphone for Prompter in the Settings app."
        case .speechDenied: "Turn on Speech Recognition for Prompter in the Settings app."
        case .unsupported, .modelUnavailable, .failed: nil
        }
    }

    /// The Settings app can fix it (the footer then offers a button to open it).
    var opensSettings: Bool {
        remedy != nil
    }
}
