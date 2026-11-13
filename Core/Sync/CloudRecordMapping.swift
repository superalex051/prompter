import CloudKit
import Foundation

// How one script, or the record of its deletion, is stored in the private CloudKit database.
//
// Logic only: nothing here talks to CloudKit, so none of it needs the iCloud entitlement. Building a `CKRecord` in memory
// is allowed without one. The sync engine that sends and receives these records comes later.
//
// One record per script, in one custom zone. The record name is the script's UUID, so a script is the same record on
// every device. The title, the body and the digest go in `encryptedValues`, which Apple encrypts end to end (the digest
// would let a reader of the server test guesses against the text). The clock, the dates and the deleted flag stay plain.
//
// A deletion keeps its record (`deleted` = 1, the clock of the deletion) so another device that was away hears about it.
// Its text is stripped: no title, no body, no digest.

enum CloudScriptRecord {
    /// The record type, as named in `Config/CloudKit/schema.md`.
    static let recordType = "Script"
    /// The custom zone every script record lives in. Custom zones are what `CKSyncEngine` needs.
    static let zoneName = "Scripts"

    /// A script whose title and body together are at most this many UTF-8 bytes is stored inline. A bigger one has its body
    /// in a `CKAsset`, because a record is limited to about 1 MB in total (unverified).
    static let inlineBodyLimit = 500_000

    enum Field {
        static let title = "title"          // encrypted string
        static let body = "body"            // encrypted string, absent when the body is an asset
        static let bodyAsset = "bodyAsset"  // asset, present only above `inlineBodyLimit`
        static let createdAt = "createdAt"  // double, seconds since 1970, exactly `Script.createdAt`
        static let updatedAt = "updatedAt"  // double, seconds since 1970, exactly `Script.updatedAt`
        static let clock = "clock"          // double, the sync clock of this version
        static let deleted = "deleted"      // int64, 1 for a deletion, else 0
        static let digest = "digest"        // encrypted string, `SyncDigest.of(script)`, live scripts only
    }

    static func zoneID(owner: String = CKCurrentUserDefaultName) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: owner)
    }

    static func recordID(for id: UUID, zoneID: CKRecordZone.ID = zoneID()) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    }

    // MARK: Writing

    /// A new CloudKit record for `record`. Use `apply(_:to:)` instead when a record for this script already exists on the
    /// server, so the update is built on the record the server last sent.
    static func makeRecord(
        from record: SyncRecord,
        zoneID: CKRecordZone.ID = zoneID(),
        assetDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> CKRecord {
        let ckRecord = CKRecord(recordType: recordType, recordID: recordID(for: record.id, zoneID: zoneID))
        try apply(record, to: ckRecord, assetDirectory: assetDirectory)
        return ckRecord
    }

    /// Writes `record` into `ckRecord`, which may be a fresh record or the last one the server sent (with its change tag).
    ///
    /// Every field this mapping owns is written, with nil for the ones that don't apply. That matters: CloudKit keeps the
    /// server's value for any key that is not changed, so a script that shrank below the limit would keep its old asset,
    /// and a deletion would keep its old text. Keys this mapping doesn't know are left alone.
    ///
    /// The title and the body together count against `inlineBodyLimit`. When they are over it, the body is written to a file
    /// in `assetDirectory` and attached as an asset. The caller keeps that file until the upload has finished and then
    /// deletes it, also after a failed try. Dates are stored as exact doubles because the digest is made from whole
    /// seconds, and a date that the server rounded to a millisecond could change them.
    ///
    /// For the engine: `changedKeys()` and `allKeys()` list the encrypted keys too. Don't copy them with the plain
    /// subscript, CloudKit throws when one key is set both ways. Call this method on the record instead.
    static func apply(
        _ record: SyncRecord,
        to ckRecord: CKRecord,
        assetDirectory: URL = FileManager.default.temporaryDirectory
    ) throws {
        switch record {
        case .deleted(let tombstone):
            ckRecord.encryptedValues[Field.title] = nil
            ckRecord.encryptedValues[Field.body] = nil
            ckRecord.encryptedValues[Field.digest] = nil
            ckRecord[Field.bodyAsset] = nil
            ckRecord[Field.createdAt] = nil
            ckRecord[Field.updatedAt] = nil
            ckRecord[Field.clock] = tombstone.deletedAt
            ckRecord[Field.deleted] = Int64(1)
        case .live(let synced):
            let script = synced.script
            let bodyBytes = Data(script.body.utf8)
            // Write the file first, so a failure leaves the record untouched.
            var assetURL: URL?
            if script.title.utf8.count + bodyBytes.count > inlineBodyLimit {
                let url = assetDirectory.appendingPathComponent("\(script.id.uuidString)-\(UUID().uuidString).body")
                try bodyBytes.write(to: url, options: .atomic)
                assetURL = url
            }
            ckRecord.encryptedValues[Field.title] = script.title
            if let assetURL {
                ckRecord.encryptedValues[Field.body] = nil
                ckRecord[Field.bodyAsset] = CKAsset(fileURL: assetURL)
            } else {
                ckRecord.encryptedValues[Field.body] = script.body
                ckRecord[Field.bodyAsset] = nil
            }
            ckRecord[Field.createdAt] = script.createdAt.timeIntervalSince1970
            ckRecord[Field.updatedAt] = script.updatedAt.timeIntervalSince1970
            ckRecord[Field.clock] = synced.clock
            ckRecord[Field.deleted] = Int64(0)
            ckRecord.encryptedValues[Field.digest] = SyncDigest.of(script)
        }
    }

    // MARK: Reading

    /// The script or deletion `ckRecord` holds, or nil when it can't be trusted: another record type, a record name that
    /// is not a UUID, a missing or wrongly typed field, an unreadable asset, or a digest that doesn't match the content
    /// (the text was damaged or edited by something that doesn't know the digest). The caller skips a nil record.
    /// Fields this version doesn't know are ignored.
    static func decode(_ ckRecord: CKRecord) -> SyncRecord? {
        guard ckRecord.recordType == recordType, let id = UUID(uuidString: ckRecord.recordID.recordName) else { return nil }
        guard let clock = ckRecord[Field.clock] as? Double, clock.isFinite, let deleted = ckRecord[Field.deleted] as? Int64 else {
            return nil
        }
        switch deleted {
        case 1:
            // Whatever else the record carries is dropped on purpose.
            return .deleted(SyncTombstone(id: id, deletedAt: clock))
        case 0:
            guard let title = ckRecord.encryptedValues[Field.title] as? String,
                  let body = body(of: ckRecord),
                  let createdAt = ckRecord[Field.createdAt] as? Double, validDate(createdAt),
                  let updatedAt = ckRecord[Field.updatedAt] as? Double, validDate(updatedAt),
                  let digest = ckRecord.encryptedValues[Field.digest] as? String
            else { return nil }
            let script = Script(
                id: id, title: title, body: body,
                createdAt: Date(timeIntervalSince1970: createdAt),
                updatedAt: Date(timeIntervalSince1970: updatedAt)
            )
            guard SyncDigest.of(script) == digest else { return nil }
            return .live(SyncedScript(script: script, clock: clock))
        default:
            return nil
        }
    }

    /// Dates beyond about 31,000 years either way are damage. `SyncDigest` turns them into an `Int` and traps on a huge one.
    private static func validDate(_ seconds: Double) -> Bool {
        seconds.isFinite && abs(seconds) < 1e12
    }

    /// The body, from the asset when there is one, else from the inline field.
    private static func body(of ckRecord: CKRecord) -> String? {
        if let asset = ckRecord[Field.bodyAsset] as? CKAsset {
            guard let url = asset.fileURL, let data = try? Data(contentsOf: url) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        return ckRecord.encryptedValues[Field.body] as? String
    }
}
