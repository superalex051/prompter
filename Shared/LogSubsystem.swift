import Foundation

/// The subsystem every logger uses, taken from the running app's own bundle ID instead of a name written into the code.
/// A build with another bundle ID prefix therefore logs under its own name, and a log filter can follow the built app
/// (`subsystem BEGINSWITH "<app bundle ID>"`).
enum LogSubsystem {
    /// What a process with no bundle ID (a command line tool, some test hosts) logs under.
    static let fallback = "prompter"

    /// `bundleID` is passed in so a test can check the fallback.
    static func name(bundleID: String?) -> String {
        guard let bundleID, !bundleID.isEmpty else { return fallback }
        return bundleID
    }

    /// The running app's bundle ID.
    static let current = name(bundleID: Bundle.main.bundleIdentifier)
}
