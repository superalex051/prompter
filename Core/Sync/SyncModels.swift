import CryptoKit
import Foundation

// The data Mac ⇄ iPhone sync exchanges, and the one rule that decides between two versions of a script.
//
// Every script and every deletion carries a *clock*: seconds since 1970, kept to the millisecond, of the moment that
// version came to be on some device. The newest clock wins (last writer wins). Clocks are separate from `Script.updatedAt`
// (whole seconds, what the library shows and sorts by) because a person types many changes into one second.

/// Sync clocks: milliseconds-precise wall-clock times, as `Double` seconds since 1970.
enum SyncClock {
    /// One millisecond, the smallest step between two versions.
    static let step = 0.001

    /// `date` rounded to the millisecond.
    static func clock(_ date: Date) -> Double {
        rounded(date.timeIntervalSince1970)
    }

    /// The clock for a local change made at `now` to a version whose clock is `previous`: now, or one millisecond after
    /// `previous` when that is later (another device's clock runs ahead of this one). A change made here therefore always
    /// wins over the version it was made on, whatever the clock skew between the devices.
    static func next(now: Date, after previous: Double?) -> Double {
        let current = clock(now)
        guard let previous else { return current }
        return max(current, rounded(previous + step))
    }

    static func rounded(_ seconds: Double) -> Double {
        (seconds * 1000).rounded() / 1000
    }
}

/// A script as it travels: its content plus its clock.
struct SyncedScript: Codable, Equatable, Sendable {
    var script: Script
    var clock: Double

    var entry: SyncManifestEntry {
        SyncManifestEntry(id: script.id, clock: clock, deleted: false, digest: SyncDigest.of(script))
    }
}

/// A deletion, kept for `SyncTombstone.lifetime` so a device that was away hears about it and can't bring the script
/// back with an older copy.
struct SyncTombstone: Codable, Equatable, Sendable {
    var id: UUID
    /// The deletion's clock.
    var deletedAt: Double

    /// 30 days.
    static let lifetime: TimeInterval = 30 * 24 * 3600

    func isExpired(now: Date) -> Bool {
        deletedAt < now.timeIntervalSince1970 - Self.lifetime
    }

    var entry: SyncManifestEntry {
        SyncManifestEntry(id: id, clock: deletedAt, deleted: true, digest: nil)
    }
}

/// One line of a library's table of contents: which version of a script a device has, without its text.
struct SyncManifestEntry: Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var clock: Double
    var deleted: Bool
    /// A short hash of a live script's content (nil for a deletion). Two versions with the same clock are told apart by
    /// it, and it breaks such a tie the same way on both devices.
    var digest: String?
}

/// What one device holds for one script id: the script, or the record of its deletion.
enum SyncRecord: Equatable, Sendable {
    case live(SyncedScript)
    case deleted(SyncTombstone)

    var id: UUID {
        switch self {
        case .live(let synced): synced.script.id
        case .deleted(let tombstone): tombstone.id
        }
    }

    var entry: SyncManifestEntry {
        switch self {
        case .live(let synced): synced.entry
        case .deleted(let tombstone): tombstone.entry
        }
    }
}

/// A short, stable fingerprint of a script's content (title, body, and its whole-second dates). The same on every device.
enum SyncDigest {
    static func of(_ script: Script) -> String {
        var text = script.title
        text += "\u{1F}" + script.body
        text += "\u{1F}" + String(Int(script.createdAt.timeIntervalSince1970.rounded(.down)))
        text += "\u{1F}" + String(Int(script.updatedAt.timeIntervalSince1970.rounded(.down)))
        let hash = SHA256.hash(data: Data(text.utf8))
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Last writer wins.
enum SyncMerge {
    /// Whether the version described by `candidate` replaces `current` (nil: this device has nothing for that id).
    ///
    /// - The newer clock wins.
    /// - Same clock: a deletion beats an edit, so a script is never brought back by a version as old as its deletion.
    /// - Same clock, both live: the higher content digest wins. Arbitrary but the same on both devices, so they agree.
    ///   (The plan said "ties broken by device id"; the digest gives the same guarantee without recording which device made
    ///   each edit.)
    /// - Identical versions never replace each other, so applying something twice changes nothing.
    static func wins(_ candidate: SyncManifestEntry, over current: SyncManifestEntry?) -> Bool {
        guard let current else { return true }
        if candidate.clock != current.clock { return candidate.clock > current.clock }
        if candidate.deleted != current.deleted { return candidate.deleted }
        if candidate.deleted { return false }
        return (candidate.digest ?? "") > (current.digest ?? "")
    }

    /// What a peer whose library is described by `peer` should be sent from `local`: every record that would win over the
    /// peer's version (or that the peer doesn't have at all).
    static func outgoing(local: [UUID: SyncRecord], peer: [UUID: SyncManifestEntry]) -> [SyncRecord] {
        local.values
            .filter { wins($0.entry, over: peer[$0.id]) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// The result of merging `incoming` into `local`: the merged library, and the records that changed it.
    static func merge(local: [UUID: SyncRecord], incoming: [SyncRecord]) -> (merged: [UUID: SyncRecord], applied: [SyncRecord]) {
        var merged = local
        var applied: [SyncRecord] = []
        for record in incoming where wins(record.entry, over: merged[record.id]?.entry) {
            merged[record.id] = record
            applied.append(record)
        }
        return (merged, applied)
    }
}
