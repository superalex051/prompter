import CloudKit
import Foundation
import Testing
#if os(macOS)
@testable import PrompterMac
#else
@testable import Prompter
#endif

/// Scripts and deletions as CloudKit records and back. Pure logic: no container, no entitlement.
struct CloudRecordMappingTests {
    let id = UUID()
    let t: Double = 1_800_000_000

    private func script(body: String = "Hello", title: String = "Intro") -> Script {
        Script(id: id, title: title, body: body,
               createdAt: Date(timeIntervalSince1970: t), updatedAt: Date(timeIntervalSince1970: t + 5))
    }

    private func liveRecord(_ script: Script, clock: Double = 1_800_000_010.123) -> SyncRecord {
        .live(SyncedScript(script: script, clock: clock))
    }

    private func makeDirectory() throws -> URL { try makeSyncTestDirectory() }

    // MARK: Round trips

    @Test func aLiveScriptRoundTrips() throws {
        let record = liveRecord(script())
        let ck = try CloudScriptRecord.makeRecord(from: record)
        #expect(ck.recordType == "Script")
        #expect(ck.recordID.recordName == id.uuidString)
        #expect(ck.recordID.zoneID.zoneName == "Scripts")
        #expect(CloudScriptRecord.decode(ck) == record)
    }

    @Test func fractionalDatesAndAnEmptyScriptSurvive() throws {
        let odd = Script(id: id, title: "", body: "", createdAt: Date(timeIntervalSince1970: t + 0.9999996),
                         updatedAt: Date(timeIntervalSince1970: t + 7.4567891))
        let record = liveRecord(odd)
        #expect(CloudScriptRecord.decode(try CloudScriptRecord.makeRecord(from: record)) == record)
    }

    @Test func textInOtherScriptsSurvives() throws {
        let text = "Zażółć gęślą jaźń 日本語 🎬\r\nline two\n\n\u{1F}tabs\tand more"
        let record = liveRecord(script(body: text, title: "Ünïcode ✍️"))
        #expect(CloudScriptRecord.decode(try CloudScriptRecord.makeRecord(from: record)) == record)
    }

    @Test func titleAndBodyAreEncryptedNotPlainFields() throws {
        let ck = try CloudScriptRecord.makeRecord(from: liveRecord(script(body: "secret body", title: "secret title")))
        #expect(ck["title"] == nil)
        #expect(ck["body"] == nil)
        #expect(ck.encryptedValues["title"] as? String == "secret title")
        #expect(ck.encryptedValues["body"] as? String == "secret body")
    }

    @Test func theRecordCarriesTheMergeFields() throws {
        let ck = try CloudScriptRecord.makeRecord(from: liveRecord(script(), clock: 1_800_000_010.123))
        #expect(ck["clock"] as? Double == 1_800_000_010.123)
        #expect(ck["deleted"] as? Int64 == 0)
        #expect(ck.encryptedValues["digest"] as? String == SyncDigest.of(script()))
        #expect(ck["digest"] == nil)
        #expect(ck["createdAt"] as? Double == t)
        #expect(ck["updatedAt"] as? Double == t + 5)
    }

    // MARK: Tombstones

    @Test func aDeletionRoundTripsAndCarriesNoContent() throws {
        let record = SyncRecord.deleted(SyncTombstone(id: id, deletedAt: t + 3.5))
        let ck = try CloudScriptRecord.makeRecord(from: record)
        #expect(ck["deleted"] as? Int64 == 1)
        #expect(ck["clock"] as? Double == t + 3.5)
        #expect(ck.encryptedValues["title"] == nil)
        #expect(ck.encryptedValues["body"] == nil)
        #expect(ck["bodyAsset"] == nil)
        #expect(ck.encryptedValues["digest"] == nil)
        #expect(ck["createdAt"] == nil)
        #expect(ck["updatedAt"] == nil)
        #expect(CloudScriptRecord.decode(ck) == record)
    }

    @Test func aDeletionRecordThatStillHasTextIsReadWithoutIt() throws {
        let ck = try CloudScriptRecord.makeRecord(from: liveRecord(script(body: "leftover")))
        ck["deleted"] = Int64(1)
        #expect(CloudScriptRecord.decode(ck) == .deleted(SyncTombstone(id: id, deletedAt: 1_800_000_010.123)))
    }

    // MARK: The inline versus asset edge

    @Test func aBodyAtTheLimitStaysInline() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The title counts too: "Intro" is 5 bytes.
        let body = String(repeating: "a", count: CloudScriptRecord.inlineBodyLimit - 5)
        let record = liveRecord(script(body: body))
        let ck = try CloudScriptRecord.makeRecord(from: record, assetDirectory: dir)
        #expect(ck["bodyAsset"] == nil)
        #expect(ck.encryptedValues["body"] as? String == body)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        #expect(CloudScriptRecord.decode(ck) == record)
    }

    @Test func aBodyOneByteOverGoesToAnAsset() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = String(repeating: "a", count: CloudScriptRecord.inlineBodyLimit - 5 + 1)
        let record = liveRecord(script(body: body))
        let ck = try CloudScriptRecord.makeRecord(from: record, assetDirectory: dir)
        #expect(ck["bodyAsset"] is CKAsset)
        #expect(ck.encryptedValues["body"] == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 1)
        #expect(CloudScriptRecord.decode(ck) == record)
    }

    @Test func theLimitCountsBytesNotCharacters() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 3 bytes per character: 166,667 characters is 500,001 bytes, well under the limit counted in characters.
        let body = String(repeating: "日", count: 166_667)
        #expect(body.utf8.count == CloudScriptRecord.inlineBodyLimit + 1)
        let record = liveRecord(script(body: body, title: ""))
        let ck = try CloudScriptRecord.makeRecord(from: record, assetDirectory: dir)
        #expect(ck["bodyAsset"] is CKAsset)
        #expect(CloudScriptRecord.decode(ck) == record)
    }

    @Test func aLongTitleCountsTowardTheLimit() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let title = String(repeating: "t", count: 1_000)
        let body = String(repeating: "a", count: CloudScriptRecord.inlineBodyLimit - 999)
        let record = liveRecord(script(body: body, title: title))
        let ck = try CloudScriptRecord.makeRecord(from: record, assetDirectory: dir)
        #expect(ck["bodyAsset"] is CKAsset)
        #expect(ck.encryptedValues["title"] as? String == title)
        #expect(CloudScriptRecord.decode(ck) == record)
    }

    @Test func aMissingAssetFileGivesNil() throws {
        let dir = try makeDirectory()
        let body = String(repeating: "a", count: CloudScriptRecord.inlineBodyLimit + 1)
        let ck = try CloudScriptRecord.makeRecord(from: liveRecord(script(body: body)), assetDirectory: dir)
        try FileManager.default.removeItem(at: dir)
        #expect(CloudScriptRecord.decode(ck) == nil)
    }

    // MARK: Records that can't be trusted

    private func good() throws -> CKRecord { try CloudScriptRecord.makeRecord(from: liveRecord(script())) }

    @Test func anotherRecordTypeGivesNil() throws {
        let other = CKRecord(recordType: "Settings", recordID: try good().recordID)
        #expect(CloudScriptRecord.decode(other) == nil)
    }

    @Test func aRecordNameThatIsNotAUUIDGivesNil() throws {
        let ck = CKRecord(recordType: "Script", recordID: CKRecord.ID(recordName: "not-a-uuid", zoneID: CloudScriptRecord.zoneID()))
        ck["clock"] = t
        ck["deleted"] = Int64(1)
        #expect(CloudScriptRecord.decode(ck) == nil)
    }

    @Test(arguments: ["clock", "deleted", "createdAt", "updatedAt"])
    func aMissingPlainFieldGivesNil(field: String) throws {
        let ck = try good()
        ck[field] = nil
        #expect(CloudScriptRecord.decode(ck) == nil)
    }

    @Test(arguments: ["title", "body", "digest"])
    func aMissingEncryptedFieldGivesNil(field: String) throws {
        let ck = try good()
        ck.encryptedValues[field] = nil
        #expect(CloudScriptRecord.decode(ck) == nil)
    }

    @Test func aWronglyTypedFieldGivesNil() throws {
        let ck = try good()
        ck["clock"] = "yesterday"
        #expect(CloudScriptRecord.decode(ck) == nil)
        let ck2 = try good()
        ck2.encryptedValues["title"] = Int64(4)
        #expect(CloudScriptRecord.decode(ck2) == nil)
    }

    @Test(arguments: [1e300, -1e300, 1e13, Double.infinity])
    func aHugeDateGivesNilInsteadOfCrashing(value: Double) throws {
        let a = try good()
        a["createdAt"] = value
        #expect(CloudScriptRecord.decode(a) == nil)
        let b = try good()
        b["updatedAt"] = value
        #expect(CloudScriptRecord.decode(b) == nil)
    }

    @Test func aNonFiniteClockGivesNil() throws {
        let ck = try good()
        ck["clock"] = Double.nan
        #expect(CloudScriptRecord.decode(ck) == nil)
    }

    @Test func anUnknownDeletedValueGivesNil() throws {
        let ck = try good()
        ck["deleted"] = Int64(2)
        #expect(CloudScriptRecord.decode(ck) == nil)
    }

    // MARK: The digest

    @Test func aChangedBodyFailsTheDigest() throws {
        let ck = try good()
        ck.encryptedValues["body"] = "Hello, tampered"
        #expect(CloudScriptRecord.decode(ck) == nil)
    }

    @Test func aChangedTitleOrDateFailsTheDigest() throws {
        let a = try good()
        a.encryptedValues["title"] = "Other"
        #expect(CloudScriptRecord.decode(a) == nil)
        let b = try good()
        b["updatedAt"] = t + 60
        #expect(CloudScriptRecord.decode(b) == nil)
    }

    @Test func aWrongDigestIsNotTrustedEvenWhenTheContentIsFine() throws {
        let ck = try good()
        ck.encryptedValues["digest"] = "0000000000000000"
        #expect(CloudScriptRecord.decode(ck) == nil)
    }

    @Test func aDamagedAssetFailsTheDigest() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = String(repeating: "a", count: CloudScriptRecord.inlineBodyLimit + 1)
        let ck = try CloudScriptRecord.makeRecord(from: liveRecord(script(body: body)), assetDirectory: dir)
        let url = try #require((ck["bodyAsset"] as? CKAsset)?.fileURL)
        try Data("shorter".utf8).write(to: url)
        #expect(CloudScriptRecord.decode(ck) == nil)
    }

    @Test func anAssetThatIsNotUTF8GivesNil() throws {
        // The digest is right for the text "Hello", so only the encoding check can reject this file.
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ck = try CloudScriptRecord.makeRecord(from: liveRecord(script(body: "Hello")))
        ck.encryptedValues["body"] = nil
        let url = dir.appendingPathComponent("utf16.body")
        try #require("Hello".data(using: .utf16)).write(to: url)
        ck["bodyAsset"] = CKAsset(fileURL: url)
        #expect(CloudScriptRecord.decode(ck) == nil)
    }

    // MARK: Updating a record that already exists on the server

    private func bigBody() -> String { String(repeating: "a", count: CloudScriptRecord.inlineBodyLimit + 1) }

    @Test func aScriptThatShrinksDropsItsOldAsset() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ck = try CloudScriptRecord.makeRecord(from: liveRecord(script(body: bigBody()), clock: t), assetDirectory: dir)
        #expect(ck["bodyAsset"] is CKAsset)
        let small = liveRecord(script(body: "short"), clock: t + 1)
        try CloudScriptRecord.apply(small, to: ck, assetDirectory: dir)
        #expect(ck["bodyAsset"] == nil)
        #expect(ck.encryptedValues["body"] as? String == "short")
        #expect(ck.changedKeys().contains("bodyAsset"))
        #expect(CloudScriptRecord.decode(ck) == small)
    }

    @Test func aScriptThatGrowsDropsItsOldInlineBody() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ck = try CloudScriptRecord.makeRecord(from: liveRecord(script(body: "short"), clock: t))
        let big = liveRecord(script(body: bigBody()), clock: t + 1)
        try CloudScriptRecord.apply(big, to: ck, assetDirectory: dir)
        #expect(ck["bodyAsset"] is CKAsset)
        #expect(ck.encryptedValues["body"] == nil)
        #expect(CloudScriptRecord.decode(ck) == big)
    }

    @Test func aDeletionStripsAnExistingRecord() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for body in ["short", bigBody()] {
            let ck = try CloudScriptRecord.makeRecord(from: liveRecord(script(body: body), clock: t), assetDirectory: dir)
            let gone = SyncRecord.deleted(SyncTombstone(id: id, deletedAt: t + 9))
            try CloudScriptRecord.apply(gone, to: ck)
            #expect(ck.encryptedValues["title"] == nil)
            #expect(ck.encryptedValues["body"] == nil)
            #expect(ck.encryptedValues["digest"] == nil)
            #expect(ck["bodyAsset"] == nil)
            #expect(ck["createdAt"] == nil)
            #expect(ck["updatedAt"] == nil)
            #expect(CloudScriptRecord.decode(ck) == gone)
        }
    }

    @Test func aDeletedRecordCanBeRestoredByANewerLiveVersion() throws {
        let ck = try CloudScriptRecord.makeRecord(from: .deleted(SyncTombstone(id: id, deletedAt: t)))
        let back = liveRecord(script(body: "again"), clock: t + 1)
        try CloudScriptRecord.apply(back, to: ck)
        #expect(CloudScriptRecord.decode(ck) == back)
    }

    @Test func aRecordWithBothABodyAndAnAssetIsReadFromTheAsset() throws {
        // The state a half-applied update could leave on the server: the asset wins, and the digest checks it.
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = liveRecord(script(body: bigBody()), clock: t)
        let ck = try CloudScriptRecord.makeRecord(from: big, assetDirectory: dir)
        ck.encryptedValues["body"] = "stale inline body"
        #expect(CloudScriptRecord.decode(ck) == big)
    }

    // MARK: Forward compatibility

    @Test func unknownFieldsAreIgnored() throws {
        let record = liveRecord(script())
        let ck = try CloudScriptRecord.makeRecord(from: record)
        ck["futureField"] = "from a newer version"
        ck["futureNumber"] = Int64(9)
        ck.encryptedValues["futureSecret"] = "x"
        #expect(CloudScriptRecord.decode(ck) == record)
    }

    // MARK: Fits the merge rule

    @Test func decodedRecordsMergeLikeAnyOther() throws {
        let older = liveRecord(script(body: "old"), clock: t)
        let newer = liveRecord(script(body: "new"), clock: t + 1)
        let fetched = try [older, newer].compactMap { CloudScriptRecord.decode(try CloudScriptRecord.makeRecord(from: $0)) }
        let merged = SyncMerge.merge(local: [:], incoming: fetched).merged
        #expect(merged[id] == newer)
    }
}
