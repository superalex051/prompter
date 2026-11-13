import Foundation

/// Reads debug launch arguments (`-demoData`, `-route editor`, …) the same way on every platform.
///
/// Every option is read in two spellings, because the same launch can come from two places:
/// - `xcrun simctl launch … -route editor -demoData true`, `open --args`, and Xcode's scheme arguments use the dashed form.
/// - Maestro (`launchApp: arguments:`) writes `-` in front of each key itself, except when the value is a YAML boolean:
///   `demoData: true` reaches the app as a bare `demoData true` with no dash. Both are accepted so a flow cannot silently
///   launch without demo data.
enum LaunchArguments {
    /// The arguments every options type reads by default. A Release build reads none: a shipped app ignores every debug
    /// flag, so nothing a person (or a stray shortcut) passes can swap the library for demo data or open a debug pairing.
    /// Tests build their options from explicit argument lists, so they never depend on this.
    static var process: [String] {
        #if DEBUG
        ProcessInfo.processInfo.arguments
        #else
        []
        #endif
    }

    /// A bare flag means on; a following value turns it on only if it is YES, 1 or true.
    static func flag(_ name: String, in arguments: [String]) -> Bool {
        guard let index = flagIndex(name, in: arguments) else { return false }
        guard let value = value(at: index, in: arguments) else { return true }
        return ["yes", "1", "true"].contains(value.lowercased())
    }

    /// The argument following `name`, unless it is missing or is itself another option.
    static func value(after name: String, in arguments: [String]) -> String? {
        guard let index = flagIndex(name, in: arguments) else { return nil }
        return value(at: index, in: arguments)
    }

    /// Where `name` appears in the arguments, as `-name` (Xcode, simctl) or as a bare `name` (Maestro with a boolean value).
    static func flagIndex(_ name: String, in arguments: [String]) -> Int? {
        arguments.firstIndex { $0 == "-\(name)" || $0 == name }
    }

    /// The argument after the flag at `index`, unless it is missing or is itself another option.
    private static func value(at index: Int, in arguments: [String]) -> String? {
        guard index + 1 < arguments.endIndex else { return nil }
        let value = arguments[index + 1]
        return value.hasPrefix("-") ? nil : value
    }
}
