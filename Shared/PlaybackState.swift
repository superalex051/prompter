import Foundation

/// Where the prompter is in a take. Shared with the watch (M3), which shows it and sends commands based on it.
enum PlaybackState: Codable, Equatable, Hashable, Sendable {
    /// Not started, or back at the top ("Ready").
    case idle
    /// Counting down; the digit currently shown.
    case countdown(Int)
    case playing
    case paused
    /// All text has passed the reading line ("End").
    case finished
}
