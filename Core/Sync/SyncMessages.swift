import Foundation

/// Who is on the other end: sent first on every connection.
struct SyncHello: Codable, Equatable, Sendable {
    enum Platform: String, Codable, Sendable {
        case mac, iPhone, iPad
    }

    var deviceID: String
    var name: String
    var platform: Platform
    var protocolVersion: Int
    /// From the iPhone: proof that it holds the key it claims (its device key in `hello`, the pairing code's key in
    /// `pairRequest`), bound to this one TLS session; see `SyncPairing.proof`. The Mac checks it, so a connection made
    /// with one key can't speak as another device. nil from the Mac.
    var proof: Data?

    /// Bumped when the messages change in a way an older app can't follow.
    static let currentProtocolVersion = 1
}

/// The messages of the sync protocol, one per frame (see `SyncFrame`), JSON-encoded.
///
/// A session (after TLS, see `SyncTransport`):
/// 1. Both sides send `hello` and then their `manifest`.
/// 2. Each side, once it has the other's manifest, sends the scripts and deletions that win over what the other has
///    (`SyncMerge.outgoing`). The receiver merges them, answers `ack`, and remembers that the sender has those versions,
///    so nothing is ever echoed back.
/// 3. From then on every local change is pushed the same way as it happens.
///
/// Pairing is a separate, one-off connection made with the pairing code's key: the iPhone sends `pairRequest`, the Mac
/// answers `pairAccepted` with a fresh random key for that iPhone, and both close.
///
/// The Apple Watch remote for the Mac (M9) rides on a session too: the iPhone asks for the Mac's presenting status
/// (`remoteSubscribe`), relays the watch's commands (`remote`), and the Mac answers each command with a `presenterStatus`
/// and pushes one whenever what the watch shows changes while it presents. An app that doesn't know a message skips it
/// (`SyncConnection` ignores frames it can't decode), so these need no new protocol version.
enum SyncMessage: Codable, Equatable, Sendable {
    case hello(SyncHello)
    case manifest([SyncManifestEntry])
    case scripts([SyncedScript])
    case deletions([SyncTombstone])
    /// "I applied your last batch of `count` records."
    case ack(count: Int)
    case pairRequest(SyncHello)
    case pairAccepted(SyncHello, key: Data)
    /// The iPhone forgot this Mac: the Mac forgets it too.
    case unpair
    /// iPhone → Mac: send me `presenterStatus` updates (true) or stop (false). The Mac answers true with its status at once.
    case remoteSubscribe(Bool)
    /// iPhone → Mac: a command from the Apple Watch (or the iPhone's Remote for Mac screen) for the Mac's prompter. The
    /// Mac answers every one with a `presenterStatus` carrying the same `id` in `replyTo`.
    case remote(RemoteCommand, id: Int)
    /// Mac → iPhone: what the Mac's prompter is doing (`hasPrompter` false while it isn't presenting). `replyTo`: the
    /// `remote` command this answers; nil for a push. (A push already on its way can't pass for the answer.)
    case presenterStatus(PrompterStatus, replyTo: Int?)
}

/// JSON for `SyncMessage`, with the same date format as the library file.
enum SyncMessageCoder {
    static func encode(_ message: SyncMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        // A presenter status can carry an infinite time left; JSON can't, so it travels as a string (as to the watch).
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: infinity, negativeInfinity: negativeInfinity, nan: notANumber
        )
        return try encoder.encode(message)
    }

    static func decode(_ data: Data) throws -> SyncMessage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: infinity, negativeInfinity: negativeInfinity, nan: notANumber
        )
        return try decoder.decode(SyncMessage.self, from: data)
    }

    private static let infinity = "+inf", negativeInfinity = "-inf", notANumber = "nan"
}

/// Length-prefixed frames over the TLS byte stream: a 4-byte big-endian length, then that many bytes of message.
enum SyncFrame {
    /// A frame larger than this is refused (a whole library of long scripts is a few megabytes at most).
    static let maximumLength = 32 * 1024 * 1024
    static let headerLength = 4

    struct TooLarge: Error, Equatable {
        var length: Int
    }

    static func encode(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: headerLength)
        frame.append(payload)
        return frame
    }
}

/// Collects bytes as they arrive and hands back whole frames' payloads, however the stream was split.
struct SyncFrameDecoder {
    private var buffer = Data()

    /// Bytes received but not yet part of a whole frame.
    var pendingByteCount: Int { buffer.count }

    /// Adds `data` and returns every payload now complete, in order. Throws `SyncFrame.TooLarge` for an oversized frame
    /// (the connection should then be closed: the stream can't be trusted any more).
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var payloads: [Data] = []
        while buffer.count >= SyncFrame.headerLength {
            let start = buffer.startIndex
            let length = buffer[start..<start + SyncFrame.headerLength].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= SyncFrame.maximumLength else { throw SyncFrame.TooLarge(length: length) }
            let end = start + SyncFrame.headerLength + length
            guard buffer.count >= SyncFrame.headerLength + length else { break }
            payloads.append(Data(buffer[start + SyncFrame.headerLength..<end]))
            buffer = Data(buffer[end...])
        }
        return payloads
    }
}
