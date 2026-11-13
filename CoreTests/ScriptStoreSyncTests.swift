import Foundation
import Testing
#if os(macOS)
@testable import PrompterMac
#else
@testable import Prompter
#endif

/// The library's side of sync: file format v2 (clocks + tombstones), `applyRemote` and the local-change hook.
@MainActor
struct ScriptStoreSyncTests {
    // MARK: File format

    @Test func aVersion1FileLoadsAndIsUpgradedOnTheNextSave() throws {
        let directory = try makeSyncTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let v1 = """
            {"scripts":[{"body":"Hello","createdAt":"2027-01-15T08:00:00Z","id":"\(id.uuidString)","title":"Old file",\
            "updatedAt":"2027-01-15T08:00:00Z"}],"version":1}
            """
        try Data(v1.utf8).write(to: directory.appending(path: "scripts.json"))

        let fixture = try StoreFixture(directory: directory)
        let store = fixture.store
        #expect(store.scripts.map(\.title) == ["Old file"])
        #expect(store.lastError == nil)
        // Without a stored clock, the script's clock is its updatedAt.
        let updatedAt = try #require(store.scripts.first?.updatedAt)
        guard case .live(let synced) = store.syncRecords[id] else {
            Issue.record("missing record")
            return
        }
        #expect(synced.clock == updatedAt.timeIntervalSince1970)

        fixture.clock.advance(by: 30)
        store.update(id, body: "Hello again")
        let json = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appending(path: "scripts.json"))
        ) as? [String: Any])
        #expect(json["version"] as? Int == 2)
        #expect((json["clocks"] as? [String: Double])?[id.uuidString] != nil)
        #expect(json["tombstones"] as? [Any] != nil)
    }

    @Test func clocksAndTombstonesSurviveAReload() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = fixture.store
        let kept = store.create(title: "Kept", body: "Words")
        fixture.clock.advance(by: 0.25)
        store.update(kept.id, body: "More words")
        let gone = store.create(title: "Gone", body: "Words")
        fixture.clock.advance(by: 1.5)
        store.delete(gone.id)

        let reopened = fixture.reopened()
        #expect(reopened.syncRecords == store.syncRecords)
        #expect(reopened.tombstones[gone.id] == store.tombstones[gone.id])
        #expect(reopened.tombstones[gone.id] != nil)
    }

    @Test func oldTombstonesAreDroppedOnLoad() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let script = fixture.store.create(title: "Old", body: "Words")
        fixture.store.delete(script.id)
        fixture.clock.advance(by: 31 * 86_400)
        #expect(fixture.reopened().tombstones.isEmpty)
    }

    // MARK: Local changes

    @Test func everyLocalChangeIsReportedAndMovesTheClockForward() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = fixture.store
        var reports = 0
        store.onLocalChange = { reports += 1 }

        let script = store.create(title: "A", body: "One")
        let first = try #require(clock(of: script.id, in: store))
        store.update(script.id, body: "Two")            // same instant on the test clock
        let second = try #require(clock(of: script.id, in: store))
        #expect(second > first, "two edits in the same millisecond still order")
        store.update(script.id, body: "Two")            // no change: no report
        store.rename(script.id, to: "B")
        store.duplicate(script.id)
        store.delete(script.id)
        let deletedAt = try #require(store.tombstones[script.id])
        #expect(deletedAt > second)
        #expect(reports == 5)
    }

    @Test func undoingADeleteWinsOverTheDeletion() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = fixture.store
        let script = store.create(title: "Undo me", body: "Words")
        let removed = try #require(store.delete(script.id))
        let deletedAt = try #require(store.tombstones[script.id])
        store.restore(removed)
        #expect(store.tombstones[script.id] == nil)
        let restoredClock = try #require(clock(of: script.id, in: store))
        #expect(restoredClock > deletedAt)
        #expect(store.script(id: script.id) == removed, "the dates stay as they were, so it lands where it was")
    }

    @Test func blankScriptsAreNotShared() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let blank = fixture.store.create()
        #expect(fixture.store.syncRecords[blank.id] == nil)
        fixture.store.update(blank.id, title: "Now it has a title")
        #expect(fixture.store.syncRecords[blank.id] != nil)
    }

    // MARK: applyRemote

    @Test func remoteScriptsAreAddedWithTheirOwnDatesAndNotReportedBack() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = fixture.store
        var reports = 0
        store.onLocalChange = { reports += 1 }
        let remote = syncScript(title: "From the Mac", body: "Words", at: 1_700_000_000)

        let applied = store.applyRemote(scripts: [SyncedScript(script: remote, clock: 1_700_000_000.5)], deletions: [])
        #expect(applied.count == 1)
        #expect(store.script(id: remote.id) == remote, "no timestamp bump")
        #expect(clock(of: remote.id, in: store) == 1_700_000_000.5)
        #expect(reports == 0, "a remote change is never reported as a local one, so it isn't echoed")
        #expect(store.remoteChange?.ids == [remote.id])
        #expect(fixture.reopened().script(id: remote.id) == remote, "saved")

        // The same thing again changes nothing.
        let serial = store.remoteChange?.serial
        #expect(store.applyRemote(scripts: [SyncedScript(script: remote, clock: 1_700_000_000.5)], deletions: []).isEmpty)
        #expect(store.remoteChange?.serial == serial)
    }

    @Test func aRemoteEditReplacesAnOlderLocalOneOnly() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = fixture.store
        let script = store.create(title: "Shared", body: "Local")
        let localClock = try #require(clock(of: script.id, in: store))

        var older = script
        older.body = "Older remote"
        store.applyRemote(scripts: [SyncedScript(script: older, clock: localClock - 1)], deletions: [])
        #expect(store.script(id: script.id)?.body == "Local")

        var newer = script
        newer.body = "Newer remote"
        store.applyRemote(scripts: [SyncedScript(script: newer, clock: localClock + 1)], deletions: [])
        #expect(store.script(id: script.id)?.body == "Newer remote")
    }

    @Test func aRemoteDeletionRemovesTheScriptAndIsRemembered() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = fixture.store
        let script = store.create(title: "Doomed", body: "Words")
        let localClock = try #require(clock(of: script.id, in: store))

        store.applyRemote(scripts: [], deletions: [SyncTombstone(id: script.id, deletedAt: localClock + 1)])
        #expect(store.script(id: script.id) == nil)
        #expect(store.tombstones[script.id] == localClock + 1)

        // A stale copy from a device that was away can't bring it back.
        store.applyRemote(scripts: [SyncedScript(script: script, clock: localClock)], deletions: [])
        #expect(store.script(id: script.id) == nil)
        #expect(fixture.reopened().script(id: script.id) == nil)
    }

    @Test func aRemoteDeletionOlderThanALocalEditIsIgnored() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = fixture.store
        let script = store.create(title: "Edited later", body: "Words")
        let localClock = try #require(clock(of: script.id, in: store))
        store.applyRemote(scripts: [], deletions: [SyncTombstone(id: script.id, deletedAt: localClock - 10)])
        #expect(store.script(id: script.id) != nil)
    }

    @Test func remoteBlankScriptsAreIgnored() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let blank = syncScript(title: " ", body: "\n")
        #expect(fixture.store.applyRemote(scripts: [SyncedScript(script: blank, clock: 1)], deletions: []).isEmpty)
        #expect(fixture.store.scripts.isEmpty)
    }

    @Test func remoteChangesKeepTheLibrarySorted() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = fixture.store
        let local = store.create(title: "Local", body: "Words")
        let newer = syncScript(title: "Newer", body: "Words", at: local.updatedAt.timeIntervalSince1970 + 60)
        let older = syncScript(title: "Older", body: "Words", at: local.updatedAt.timeIntervalSince1970 - 60)
        store.applyRemote(
            scripts: [SyncedScript(script: older, clock: 1), SyncedScript(script: newer, clock: 2)], deletions: []
        )
        #expect(store.scripts.map(\.title) == ["Newer", "Local", "Older"])
    }

    // MARK: The seeded sample (M8 review)

    /// A first launch's library (the sample, seeded), as the Mac makes it.
    private func seededStore(clock: SyncTestClock = SyncTestClock()) throws -> (ScriptStore, URL) {
        let directory = try makeSyncTestDirectory()
        let store = ScriptStore(
            directory: directory, now: { clock.now }, initialScripts: { [SampleScript.make(now: $0)] },
            isProtectedDataAvailable: true
        )
        return (store, directory)
    }

    @Test func aSeededSampleIsNotSharedUntilEdited() throws {
        let time = SyncTestClock()
        let (store, directory) = try seededStore(clock: time)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(store.script(id: SampleScript.id) != nil)
        #expect(store.syncRecords[SampleScript.id] == nil, "a fresh install's sample isn't offered to the other device")
        // Still so after a relaunch.
        let reopened = ScriptStore(directory: directory, now: { time.now }, initialScripts: { _ in [] },
                                   isProtectedDataAvailable: true)
        #expect(reopened.script(id: SampleScript.id) != nil)
        #expect(reopened.syncRecords[SampleScript.id] == nil)
        // Edited here: a real version, shared like any script.
        time.advance(by: 60)
        reopened.update(SampleScript.id, body: "My own notes")
        #expect(clock(of: SampleScript.id, in: reopened) == time.now.timeIntervalSince1970)
    }

    @Test func theOtherDevicesEditedSampleReplacesAFreshlySeededOne() throws {
        // The iPhone's sample, edited long before the Mac app was first opened.
        let (mac, directory) = try seededStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var edited = SampleScript.make(now: Date(timeIntervalSince1970: 1_700_000_000))
        edited.body = "Edited on the iPhone last year."
        let applied = mac.applyRemote(scripts: [SyncedScript(script: edited, clock: 1_700_000_000)], deletions: [])
        #expect(applied.count == 1)
        #expect(mac.script(id: SampleScript.id)?.body == "Edited on the iPhone last year.")
    }

    @Test func aSeededSampleNeverBringsBackOneDeletedOnTheOtherDevice() throws {
        let (mac, directory) = try seededStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Deleted on the iPhone before sync existed: no tombstone there, so the iPhone's manifest simply lacks it.
        #expect(SyncMerge.outgoing(local: mac.syncRecords, peer: [:]).isEmpty, "nothing to send: the sample stays here")
        // Deleted on the iPhone since: its tombstone (however old) removes the seed.
        let (other, otherDirectory) = try seededStore()
        defer { try? FileManager.default.removeItem(at: otherDirectory) }
        other.applyRemote(scripts: [], deletions: [SyncTombstone(id: SampleScript.id, deletedAt: 1_799_000_000)])
        #expect(other.script(id: SampleScript.id) == nil)
    }

    private func clock(of id: UUID, in store: ScriptStore) -> Double? {
        if case .live(let synced) = store.syncRecords[id] { return synced.clock }
        return nil
    }
}
