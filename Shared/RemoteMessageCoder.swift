import Foundation

/// Turns commands and statuses into WCSession dictionaries and back. Each dictionary carries one value: JSON `Data`
/// under `commandKey` (watch → phone) or `statusKey` (phone → watch: replies, live messages, application context).
/// The watch answers each live message with `ack`, which the phone waits for before sending the next one.
///
/// Decoding never throws or traps: anything unexpected (missing key, wrong type, bad JSON, a case from a newer app)
/// comes back as nil, and the receiver ignores it.
enum RemoteMessageCoder {
    static let commandKey = "cmd"
    static let statusKey = "status"
    static let ackKey = "ack"

    /// The watch's reply to a live message. The phone only needs to know it arrived; it doesn't read the contents.
    static var ack: [String: Any] { [ackKey: true] }

    static func message(for command: RemoteCommand) -> [String: Any] {
        message(key: commandKey, value: command)
    }

    static func command(from message: [String: Any]) -> RemoteCommand? {
        decode(RemoteCommand.self, from: message[commandKey])
    }

    /// Also the reply to a command and the application context.
    static func message(for status: PrompterStatus) -> [String: Any] {
        message(key: statusKey, value: status)
    }

    static func status(from message: [String: Any]) -> PrompterStatus? {
        decode(PrompterStatus.self, from: message[statusKey])
    }

    // MARK: Private

    /// JSON can't hold infinity or NaN, so they travel as strings instead of failing the whole message.
    private static let infinity = "+inf", negativeInfinity = "-inf", notANumber = "nan"

    private static func message(key: String, value: some Encodable) -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: infinity, negativeInfinity: negativeInfinity, nan: notANumber
        )
        // Commands and statuses always encode; an empty dictionary would just be ignored by the receiver.
        guard let data = try? encoder.encode(value) else { return [:] }
        return [key: data]
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from object: Any?) -> Value? {
        guard let data = object as? Data else { return nil }
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: infinity, negativeInfinity: negativeInfinity, nan: notANumber
        )
        return try? decoder.decode(type, from: data)
    }
}
