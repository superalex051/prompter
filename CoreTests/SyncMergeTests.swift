import Foundation
import Testing
#if os(macOS)
@testable import PrompterMac
#else
@testable import Prompter
#endif

/// Last writer wins, with deletions: every conflict between two versions of a script.
struct SyncMergeTests {
    let id = UUID()
    let t: Double = 1_800_000_000

    private func entry(_ record: SyncRecord) -> SyncManifestEntry { record.entry }

    // MARK: The rule

    @Test func anythingWinsOverNothing() {
        #expect(SyncMerge.wins(entry(live(syncScript(id), clock: t)), over: nil))
        #expect(SyncMerge.wins(entry(deleted(id, at: t)), over: nil))
    }

    @Test func theNewerEditWins() {
        let older = live(syncScript(id, body: "old"), clock: t)
        let newer = live(syncScript(id, body: "new"), clock: t + 0.001)
        #expect(SyncMerge.wins(entry(newer), over: entry(older)))
        #expect(!SyncMerge.wins(entry(older), over: entry(newer)))
    }

    @Test func aDeletionNewerThanTheEditWins() {
        let edit = live(syncScript(id), clock: t)
        let deletion = deleted(id, at: t + 5)
        #expect(SyncMerge.wins(entry(deletion), over: entry(edit)))
        #expect(!SyncMerge.wins(entry(edit), over: entry(deletion)))
    }

    @Test func anEditNewerThanTheDeletionBringsTheScriptBack() {
        // Edited on one device after it was deleted on the other: the newer edit is kept (last writer wins).
        let deletion = deleted(id, at: t)
        let edit = live(syncScript(id), clock: t + 5)
        #expect(SyncMerge.wins(entry(edit), over: entry(deletion)))
    }

    @Test func anOlderEditNeverResurrectsADeletedScript() {
        let deletion = deleted(id, at: t + 5)
        let staleCopy = live(syncScript(id, body: "from a device that was away"), clock: t)
        #expect(!SyncMerge.wins(entry(staleCopy), over: entry(deletion)))
    }

    @Test func atTheSameInstantADeletionBeatsAnEdit() {
        let edit = live(syncScript(id), clock: t)
        let deletion = deleted(id, at: t)
        #expect(SyncMerge.wins(entry(deletion), over: entry(edit)))
        #expect(!SyncMerge.wins(entry(edit), over: entry(deletion)))
    }

    @Test func twoDeletionsAtTheSameInstantAreTheSame() {
        #expect(!SyncMerge.wins(entry(deleted(id, at: t)), over: entry(deleted(id, at: t))))
    }

    @Test func aTieBetweenTwoEditsIsBrokenTheSameWayOnBothDevices() {
        let a = live(syncScript(id, body: "typed on the Mac"), clock: t)
        let b = live(syncScript(id, body: "typed on the iPhone"), clock: t)
        // Exactly one of the two wins, whichever device does the comparing.
        #expect(SyncMerge.wins(entry(a), over: entry(b)) != SyncMerge.wins(entry(b), over: entry(a)))
    }

    @Test func identicalVersionsNeverReplaceEachOther() {
        let a = live(syncScript(id), clock: t)
        #expect(!SyncMerge.wins(entry(a), over: entry(a)))
    }

    @Test func theDigestCoversTitleBodyAndDates() {
        let base = syncScript(id)
        var retitled = base
        retitled.title = "Other"
        var rewritten = base
        rewritten.body = "Other"
        var redated = base
        redated.updatedAt += 1
        let digests = Set([base, retitled, rewritten, redated].map(SyncDigest.of))
        #expect(digests.count == 4)
        #expect(SyncDigest.of(base) == SyncDigest.of(syncScript(id)), "stable")
        #expect(SyncDigest.of(base).count == 16)
    }

    // MARK: Clock skew

    @Test func aLocalChangeBeatsTheVersionItWasMadeOnEvenWhenThisClockIsBehind() {
        // The Mac's clock runs 2 minutes ahead; the iPhone edits the Mac's version a moment later by its own clock.
        let macVersion = t + 120
        let iPhoneNow = Date(timeIntervalSince1970: t + 1)
        let edit = SyncClock.next(now: iPhoneNow, after: macVersion)
        #expect(edit > macVersion)
        #expect(edit == macVersion + 0.001)
    }

    @Test func aLocalChangeUsesNowWhenNowIsLater() {
        #expect(SyncClock.next(now: Date(timeIntervalSince1970: t + 10.25), after: t) == t + 10.25)
        #expect(SyncClock.next(now: Date(timeIntervalSince1970: t + 10.2504), after: nil) == t + 10.25)
    }

    @Test func manyChangesInOneMillisecondStillGoForward() {
        var clock = t
        let now = Date(timeIntervalSince1970: t)
        for _ in 0..<5 {
            let next = SyncClock.next(now: now, after: clock)
            #expect(next > clock)
            clock = next
        }
        #expect(clock == t + 0.005)
    }

    // MARK: Merging libraries

    @Test func mergeAppliesOnlyWhatWins() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let local: [UUID: SyncRecord] = [
            a: live(syncScript(a, body: "local newer"), clock: t + 10),
            b: live(syncScript(b, body: "local older"), clock: t),
            c: deleted(c, at: t + 10),
        ]
        let incoming = [
            live(syncScript(a, body: "remote older"), clock: t),
            live(syncScript(b, body: "remote newer"), clock: t + 10),
            live(syncScript(c, body: "stale copy"), clock: t),
            live(syncScript(d, body: "new here"), clock: t),
        ]
        let (merged, applied) = SyncMerge.merge(local: local, incoming: incoming)
        #expect(applied.map(\.id) == [b, d])
        #expect(merged[a] == local[a])
        #expect(merged[b] == incoming[1])
        #expect(merged[c] == local[c])
        #expect(merged[d] == incoming[3])
    }

    @Test func mergingTwiceChangesNothingTheSecondTime() {
        let a = UUID()
        let incoming = [live(syncScript(a), clock: t)]
        let first = SyncMerge.merge(local: [:], incoming: incoming)
        let second = SyncMerge.merge(local: first.merged, incoming: incoming)
        #expect(second.applied.isEmpty)
        #expect(second.merged == first.merged)
    }

    @Test func outgoingIsWhatThePeerLacksOrHasOlder() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let local: [UUID: SyncRecord] = [
            a: live(syncScript(a), clock: t + 10),    // peer has older → send
            b: live(syncScript(b), clock: t),         // peer has the same → don't
            c: deleted(c, at: t + 10),                // peer still has it → send the deletion
            d: live(syncScript(d), clock: t),         // peer has newer → don't (it sends its own)
        ]
        let peer: [UUID: SyncManifestEntry] = [
            a: live(syncScript(a), clock: t).entry,
            b: local[b]!.entry,
            c: live(syncScript(c), clock: t).entry,
            d: live(syncScript(d), clock: t + 20).entry,
        ]
        #expect(Set(SyncMerge.outgoing(local: local, peer: peer).map(\.id)) == [a, c])
        #expect(Set(SyncMerge.outgoing(local: local, peer: [:]).map(\.id)) == [a, b, c, d])
    }

    @Test func tombstonesExpireAfterThirtyDays() {
        let tombstone = SyncTombstone(id: id, deletedAt: t)
        #expect(!tombstone.isExpired(now: Date(timeIntervalSince1970: t + 29 * 86_400)))
        #expect(tombstone.isExpired(now: Date(timeIntervalSince1970: t + 31 * 86_400)))
    }
}
