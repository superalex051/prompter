import Foundation

/// Debug-only automation for simulator end-to-end checks: a list of commands to send at set times after launch
/// (the watch app's `-remoteScript` launch argument).
struct RemoteScript: Equatable, Sendable {
    struct Step: Equatable, Sendable {
        /// Seconds after launch.
        var at: Double
        var command: RemoteCommand
    }

    /// Sorted by time; steps at the same time keep their written order.
    var steps: [Step]

    init(steps: [Step]) {
        self.steps = steps
    }

    /// Parses "start@2,pause@12,speedStep:5@14,resume@16,backToTop@30" (seconds after launch). Each part is
    /// `name@seconds`, or `name:value@seconds` for `speedStep:<whole number>` and `setSpeed:<number>`. Names match the
    /// `RemoteCommand` cases exactly; spaces around parts are allowed. Invalid parts are skipped.
    init(_ text: String) {
        let parsed = text.split(separator: ",").compactMap(Self.step(from:))
        // `sorted(by:)` isn't guaranteed stable, so break ties on the written position.
        steps = parsed.enumerated()
            .sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }
            .map(\.element)
    }

    // MARK: Private

    private static func step(from part: Substring) -> Step? {
        guard let at = part.lastIndex(of: "@") else { return nil }
        let call = part[..<at].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seconds = Double(part[part.index(after: at)...].trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds.isFinite, seconds >= 0,
              let command = command(from: call)
        else { return nil }
        return Step(at: seconds, command: command)
    }

    private static func command(from call: String) -> RemoteCommand? {
        let pieces = call.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(pieces[0])
        let argument = pieces.count > 1 ? String(pieces[1]) : nil

        switch (name, argument) {
        case ("speedStep", let value?):
            return Int(value).map(RemoteCommand.speedStep)
        case ("setSpeed", let value?):
            guard let speed = Double(value), speed.isFinite else { return nil }
            return .setSpeed(speed)
        case (_, nil):
            return plainCommands[name]
        default:
            return nil
        }
    }

    private static let plainCommands: [String: RemoteCommand] = [
        "start": .start,
        "pause": .pause,
        "resume": .resume,
        "togglePlay": .togglePlay,
        "backToTop": .backToTop,
        "jumpBack": .jumpBack,
        "requestStatus": .requestStatus,
    ]
}
