import Foundation

/// Debug launch arguments for Prompter for Mac, e.g. `open Prompter.app --args -demoData`.
/// Parsed like the iPhone's (`LaunchArguments`); M6 adds `-route`, `-outputScreen` and `-autoStart`.
struct MacLaunchOptions: Equatable, Sendable {
    /// "-demoData": a throwaway library in a temp dir seeded with `DemoData`, and throwaway settings.
    var demoData = false
    /// Running as the host of the unit tests: same throwaway storage as `demoData`, so tests never touch the real library.
    var isRunningTests = false
    /// "-snapshot <dir>": once the windows have settled, the app writes a PNG of each of its windows there (its own
    /// pixels, so no screen-recording permission and nothing else on screen is captured).
    var snapshotDirectory: URL?
    /// "-quitAfter <seconds>": quit that long after launch (after any snapshot).
    var quitAfter: Double?
    /// "-snapshotDelay <seconds>": how long the windows settle before the snapshot (default 1.5 s), e.g. to let an iPhone
    /// pair first.
    var snapshotDelay: Double?

    init(
        arguments: [String] = LaunchArguments.process,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        demoData = LaunchArguments.flag("demoData", in: arguments)
        isRunningTests = environment["XCTestConfigurationFilePath"] != nil
        if let path = LaunchArguments.value(after: "snapshot", in: arguments), !path.isEmpty {
            snapshotDirectory = URL(filePath: path, directoryHint: .isDirectory)
        }
        if let value = LaunchArguments.value(after: "quitAfter", in: arguments), let seconds = Double(value),
           seconds.isFinite, seconds >= 0 {
            quitAfter = seconds
        }
        if let value = LaunchArguments.value(after: "snapshotDelay", in: arguments), let seconds = Double(value),
           seconds.isFinite, seconds >= 0 {
            snapshotDelay = seconds
        }
    }

    /// Use throwaway storage instead of ~/Library/Application Support/Prompter and the real settings.
    var usesThrowawayStorage: Bool { demoData || isRunningTests }
}
