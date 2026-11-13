import Foundation

/// The library a sync session reads and merges into. `ScriptStore` is the real one; tests use their own.
@MainActor
protocol SyncLibrary: AnyObject {
    /// Every script (with its clock) and deletion that sync should share.
    var syncRecords: [Script.ID: SyncRecord] { get }
    /// Merges what came from the peer; returns what changed here. Must not report the change as a local one.
    @discardableResult
    func applyRemote(scripts: [SyncedScript], deletions: [SyncTombstone]) -> [SyncRecord]
}

extension ScriptStore: SyncLibrary {}

/// One sync conversation with one peer, independent of the network: what to send when, and what to do with what arrives.
/// `SyncHost` (Mac) and `SyncClient` (iPhone) run one per connection and hand it the messages; `send` puts messages on the
/// wire.
///
/// It remembers which version of each script the peer has (`peerHas`): from the peer's manifest, from everything the peer
/// sends, and from everything sent to it. A push sends only what wins over that, so a script that just arrived from the
/// peer is never sent back, and an unchanged library sends nothing.
@MainActor
final class SyncSession {
    enum Event: Equatable {
        /// The peer said who it is.
        case peerIdentified(SyncHello)
        /// The two libraries were compared (the peer's manifest arrived) or a batch was acknowledged.
        case synced
        /// Records from the peer changed the library here.
        case applied([SyncRecord])
        /// The peer speaks a newer protocol than this app.
        case incompatible(SyncHello)
    }

    let local: SyncHello
    private(set) var peer: SyncHello?
    /// The peer's version of each script, as far as this side knows.
    private(set) var peerHas: [Script.ID: SyncManifestEntry] = [:]
    /// The peer's manifest has arrived, so pushes can start.
    private(set) var isComparing = false
    /// Records sent and not yet acknowledged.
    private(set) var unacknowledged = 0

    private let library: any SyncLibrary
    private let send: (SyncMessage) -> Void
    private let onEvent: (Event) -> Void

    init(
        local: SyncHello,
        library: any SyncLibrary,
        send: @escaping (SyncMessage) -> Void,
        onEvent: @escaping (Event) -> Void = { _ in }
    ) {
        self.local = local
        self.library = library
        self.send = send
        self.onEvent = onEvent
    }

    /// Opens the conversation: hello, then this side's manifest.
    func start() {
        send(.hello(local))
        send(.manifest(library.syncRecords.values.map(\.entry).sorted { $0.id.uuidString < $1.id.uuidString }))
    }

    /// Handles one message from the peer. Pairing messages are not for a session and are ignored here.
    func receive(_ message: SyncMessage) {
        switch message {
        case .hello(let hello):
            peer = hello
            if hello.protocolVersion > SyncHello.currentProtocolVersion {
                onEvent(.incompatible(hello))
            } else {
                onEvent(.peerIdentified(hello))
            }
        case .manifest(let entries):
            peerHas = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, b in SyncMerge.wins(a, over: b) ? a : b })
            isComparing = true
            pushChanges()
            onEvent(.synced)
        case .scripts(let scripts):
            receiveRecords(scripts.map(SyncRecord.live))
        case .deletions(let deletions):
            receiveRecords(deletions.map(SyncRecord.deleted))
        case .ack(let count):
            unacknowledged = max(0, unacknowledged - count)
            onEvent(.synced)
        case .pairRequest, .pairAccepted, .unpair:
            break
        case .remoteSubscribe, .remote, .presenterStatus:
            break   // the remote for the Mac: `SyncHost` and `SyncClient` handle these, not the library sync
        }
    }

    /// Sends the peer everything that is newer here than what it has (after a local change, or once its manifest arrives).
    /// Does nothing before the manifest has arrived. Big libraries go out in several messages, each at most
    /// `maximumBatchBytes`, so no frame comes near what the receiver accepts (`SyncFrame.maximumLength`).
    func pushChanges() {
        guard isComparing else { return }
        let outgoing = SyncMerge.outgoing(local: library.syncRecords, peer: peerHas)
        guard !outgoing.isEmpty else { return }
        var scripts: [(script: SyncedScript, bytes: Int)] = []
        var deletions: [SyncTombstone] = []
        var count = 0
        for record in outgoing {
            switch record {
            case .live(let synced):
                let bytes = Self.encodedSize(of: synced)
                guard bytes <= Self.maximumScriptBytes else {
                    // Can't be sent in one frame the peer would accept: it stays on this device (never seen in practice:
                    // that is millions of words).
                    syncLog.error("a script is too large to sync (\(bytes) bytes): \(synced.script.id.uuidString, privacy: .public)")
                    continue
                }
                scripts.append((synced, bytes))
            case .deleted(let tombstone):
                deletions.append(tombstone)
            }
            peerHas[record.id] = record.entry
            count += 1
        }
        for batch in Self.batches(scripts, limit: Self.maximumBatchBytes) { send(.scripts(batch)) }
        for start in stride(from: 0, to: deletions.count, by: Self.maximumDeletionsPerMessage) {
            send(.deletions(Array(deletions[start..<min(start + Self.maximumDeletionsPerMessage, deletions.count)])))
        }
        unacknowledged += count
    }

    /// The most script bytes (encoded) one `.scripts` message carries, unless a single script is bigger on its own.
    static let maximumBatchBytes = 4 * 1024 * 1024
    /// A script larger than this (encoded) is never sent: its frame would come too close to `SyncFrame.maximumLength`.
    static let maximumScriptBytes = SyncFrame.maximumLength - 64 * 1024
    /// Deletions per `.deletions` message (each is well under 100 bytes).
    static let maximumDeletionsPerMessage = 5_000

    /// Groups scripts, in order, into batches of at most `limit` encoded bytes; a script larger than `limit` goes alone.
    nonisolated static func batches(_ scripts: [(script: SyncedScript, bytes: Int)], limit: Int) -> [[SyncedScript]] {
        var batches: [[SyncedScript]] = []
        var current: [SyncedScript] = []
        var currentBytes = 0
        for (script, bytes) in scripts {
            if !current.isEmpty, currentBytes + bytes > limit {
                batches.append(current)
                current = []
                currentBytes = 0
            }
            current.append(script)
            currentBytes += bytes
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    /// The script's size as it goes on the wire (JSON), plus a little for the separators around it.
    nonisolated static func encodedSize(of script: SyncedScript) -> Int {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return ((try? encoder.encode(script).count) ?? Int.max - 16) + 16
    }

    /// "live 1C2…, deleted 9F0…" for logs.
    nonisolated static func describe(_ records: [SyncRecord]) -> String {
        records.map { record in
            switch record {
            case .live(let synced): "live \(synced.script.id.uuidString)"
            case .deleted(let tombstone): "deleted \(tombstone.id.uuidString)"
            }
        }.joined(separator: ", ")
    }

    private func receiveRecords(_ records: [SyncRecord]) {
        for record in records where SyncMerge.wins(record.entry, over: peerHas[record.id]) {
            peerHas[record.id] = record.entry
        }
        var scripts: [SyncedScript] = []
        var deletions: [SyncTombstone] = []
        for record in records {
            switch record {
            case .live(let synced): scripts.append(synced)
            case .deleted(let tombstone): deletions.append(tombstone)
            }
        }
        let applied = library.applyRemote(scripts: scripts, deletions: deletions)
        send(.ack(count: records.count))
        if !applied.isEmpty { onEvent(.applied(applied)) }
        // A version here that beat the one that arrived (a same-instant tie) goes back, so both sides end up equal.
        pushChanges()
    }
}
