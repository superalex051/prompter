import Foundation

/// What the watch asks the phone's prompter to do. Sent watch → phone with `RemoteMessageCoder.message(for:)`.
enum RemoteCommand: Codable, Equatable, Hashable, Sendable {
    /// Idle or finished: count down, then play (finished starts from the top). Paused: resume.
    case start
    /// Playing: pause. Counting down: cancel the countdown.
    case pause
    case resume
    case togglePlay
    /// The Crown sends ±1 per detent, the − / + buttons ±5 (see `ScrollEngine.speedStep`).
    case speedStep(Int)
    /// Sets the active mode's value (speed level, words per minute or finish-in seconds).
    case setSpeed(Double)
    case backToTop
    /// Back to the start of the paragraph being read (or the one before, if it just began).
    case jumpBack
    /// Changes nothing; the reply carries the current status.
    case requestStatus
}

/// What the phone's prompter is doing, as the watch shows it. Sent phone → watch as replies, live messages and the
/// application context. Newer `sequence` wins (see `StatusGate`).
struct PrompterStatus: Codable, Equatable, Sendable {
    /// False when the phone isn't showing the prompter (it's on the library, or the app just launched).
    var hasPrompter: Bool
    var scriptTitle: String
    var state: PlaybackState
    /// 0…1, how much of the script has passed the reading line.
    var progress: Double
    /// Whole seconds left at the current speed.
    var remainingSeconds: Double
    /// "Speed 3.0", "140 wpm" or "Finish in 5:00".
    var speedLabel: String
    /// From the phone's `SequenceClock`: increases with every status, also across phone app launches.
    var sequence: UInt64
    /// false: a prompter is open but not on screen (the phone app is in the background or the phone is locked), so the
    /// phone refuses to start it from the watch. nil means on screen; it is left out of the JSON then, and a status
    /// from a phone app that doesn't send it decodes as nil.
    var isOnScreen: Bool? = nil
    /// The Mac's name when this status describes Prompter for Mac presenting (the iPhone relays it to the watch, which
    /// shows "On <name>"); nil for the iPhone's own prompter. Left out of the JSON when nil.
    var deviceName: String? = nil
    /// Without a prompter: why, when the iPhone knows more than "no prompter" (see `RemoteNote`). Left out when nil.
    var note: RemoteNote? = nil

    /// The prompter is open and on screen: the watch's controls work.
    var isLive: Bool { hasPrompter && isOnScreen != false }

    /// No prompter open: idle, zeros, sequence 0. The phone stamps a fresh sequence on it before sending.
    static let noPrompter = PrompterStatus(
        hasPrompter: false,
        scriptTitle: "",
        state: .idle,
        progress: 0,
        remainingSeconds: 0,
        speedLabel: "",
        sequence: 0
    )
}

extension PrompterStatus {
    /// One line for the remote logs (iPhone, watch, Mac).
    var logDescription: String {
        let offScreen = isOnScreen == false ? ", off screen" : ""
        let seconds = remainingSeconds.isFinite ? "\(Int(remainingSeconds))s" : "∞"
        var what = hasPrompter ? "\(state) \(speedLabel) \(seconds) left\(offScreen)" : "no prompter"
        if let deviceName { what += " on \(deviceName)" }
        if let note { what += " [\(note.rawValue)]" }
        return "\(what) seq \(sequence)"
    }
}

/// Why the watch has nothing to control, beyond "no prompter open on the iPhone". Travels as a string; one from a newer
/// app that this one doesn't know reads as `.unknown` (and the watch shows the plain "no prompter" line).
enum RemoteNote: String, Codable, Equatable, Sendable {
    /// No prompter on the iPhone, and the paired Mac is connected but not presenting.
    case macConnected
    /// No prompter on the iPhone, a Mac is paired, and the iPhone app is in the background: the bridge to the Mac is down.
    case phoneInBackground
    case unknown

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RemoteNote(rawValue: raw) ?? .unknown
    }
}
