import Foundation
import Testing
#if os(macOS)
@testable import PrompterMac
#else
@testable import Prompter
#endif

/// Two sync sessions talking to each other in memory, each over its own real `ScriptStore`: the whole protocol without a
/// network. Messages are delivered one at a time, in order, like a TCP stream.
@MainActor
final class SyncSessionTests {
    let mac: StoreFixture
    let phone: StoreFixture
    var macSession: SyncSession!
    var phoneSession: SyncSession!
    /// Messages in flight: (to the phone?, message).
    var queue: [(toPhone: Bool, message: SyncMessage)] = []
    var sentByMac: [SyncMessage] = []
    var sentByPhone: [SyncMessage] = []

    nonisolated let directories: [URL]

    init() throws {
        let clock = SyncTestClock()
        mac = try StoreFixture(clock: clock)
        phone = try StoreFixture(clock: clock)
        directories = [mac.directory, phone.directory]
    }

    deinit {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
    }

    private func connect() {
        queue = []
        macSession = SyncSession(
            local: SyncHello(deviceID: "MAC", name: "Mac", platform: .mac, protocolVersion: 1),
            library: mac.store,
            send: { [unowned self] message in
                sentByMac.append(message)
                queue.append((true, message))
            }
        )
        phoneSession = SyncSession(
            local: SyncHello(deviceID: "PHONE", name: "iPhone", platform: .iPhone, protocolVersion: 1),
            library: phone.store,
            send: { [unowned self] message in
                sentByPhone.append(message)
                queue.append((false, message))
            }
        )
        mac.store.onLocalChange = { [unowned self] in macSession?.pushChanges() }
        phone.store.onLocalChange = { [unowned self] in phoneSession?.pushChanges() }
        macSession.start()
        phoneSession.start()
        deliverAll()
    }

    private func disconnect() {
        macSession = nil
        phoneSession = nil
        queue = []
        mac.store.onLocalChange = nil
        phone.store.onLocalChange = nil
    }

    private func deliverAll() {
        var steps = 0
        while !queue.isEmpty {
            let (toPhone, message) = queue.removeFirst()
            (toPhone ? phoneSession : macSession)?.receive(message)
            steps += 1
            precondition(steps < 1000, "the two sides keep talking: a loop")
        }
    }

    private var macTitles: Set<String> { Set(mac.store.scripts.map(\.title)) }
    private var phoneTitles: Set<String> { Set(phone.store.scripts.map(\.title)) }

    private static func dataMessages(_ messages: [SyncMessage]) -> [SyncMessage] {
        messages.filter {
            if case .scripts = $0 { return true }
            if case .deletions = $0 { return true }
            return false
        }
    }

    // MARK: Tests

    @Test func firstConnectionMergesBothLibraries() {
        mac.store.create(title: "Mac script", body: "Words")
        phone.store.create(title: "Phone script", body: "Words")
        connect()
        #expect(macTitles == ["Mac script", "Phone script"])
        #expect(phoneTitles == macTitles)
        #expect(mac.store.syncRecords == phone.store.syncRecords)
    }

    @Test func aChangeWhileConnectedIsPushedAndNotEchoed() throws {
        connect()
        sentByMac = []
        sentByPhone = []
        let script = mac.store.create(title: "Pasted on the Mac", body: "Hello")
        deliverAll()
        #expect(phone.store.script(id: script.id) == script)
        #expect(Self.dataMessages(sentByMac).count == 1)
        #expect(Self.dataMessages(sentByPhone).isEmpty, "nothing comes back")
        #expect(sentByPhone == [.ack(count: 1)])

        mac.clock.advance(by: 1)
        mac.store.update(script.id, body: "Hello again")
        deliverAll()
        #expect(phone.store.script(id: script.id)?.body == "Hello again")

        phone.clock.advance(by: 1)
        phone.store.delete(script.id)
        deliverAll()
        #expect(mac.store.script(id: script.id) == nil)
        #expect(mac.store.tombstones[script.id] != nil)
        #expect(mac.store.syncRecords == phone.store.syncRecords)
    }

    @Test func anUnchangedReconnectSendsNoScripts() {
        mac.store.create(title: "One", body: "Words")
        phone.store.create(title: "Two", body: "Words")
        connect()
        disconnect()
        sentByMac = []
        sentByPhone = []
        connect()
        #expect(Self.dataMessages(sentByMac).isEmpty)
        #expect(Self.dataMessages(sentByPhone).isEmpty)
    }

    @Test func changesMadeWhileApartCatchUpOnReconnect() throws {
        let shared = mac.store.create(title: "Shared", body: "v1")
        let doomed = mac.store.create(title: "Doomed", body: "Words")
        connect()
        disconnect()

        // Apart: the Mac edits and deletes, the phone writes a new one.
        mac.clock.advance(by: 60)
        mac.store.update(shared.id, body: "v2 from the Mac")
        mac.store.delete(doomed.id)
        phone.store.create(title: "Written offline", body: "Words")

        connect()
        #expect(phone.store.script(id: shared.id)?.body == "v2 from the Mac")
        #expect(phone.store.script(id: doomed.id) == nil)
        #expect(macTitles.contains("Written offline"))
        #expect(mac.store.syncRecords == phone.store.syncRecords)
    }

    @Test func bothEditTheSameScriptApartAndTheLaterEditWins() throws {
        let shared = mac.store.create(title: "Shared", body: "v1")
        connect()
        disconnect()
        mac.clock.advance(by: 10)
        mac.store.update(shared.id, body: "Mac edit")
        mac.clock.advance(by: 10)
        phone.store.update(shared.id, body: "iPhone edit, later")
        connect()
        #expect(mac.store.script(id: shared.id)?.body == "iPhone edit, later")
        #expect(phone.store.script(id: shared.id)?.body == "iPhone edit, later")
    }

    @Test func aDeletionApartBeatsAnOlderEditButNotANewerOne() throws {
        let a = mac.store.create(title: "A", body: "v1")
        let b = mac.store.create(title: "B", body: "v1")
        connect()
        disconnect()
        // A: edited on the phone, then deleted on the Mac later → stays deleted.
        mac.clock.advance(by: 5)
        phone.store.update(a.id, body: "phone edit")
        mac.clock.advance(by: 5)
        mac.store.delete(a.id)
        // B: deleted on the Mac, then edited on the phone later → comes back with the edit.
        mac.clock.advance(by: 5)
        mac.store.delete(b.id)
        mac.clock.advance(by: 5)
        phone.store.update(b.id, body: "phone edit after the delete")
        connect()
        #expect(mac.store.script(id: a.id) == nil && phone.store.script(id: a.id) == nil)
        #expect(mac.store.script(id: b.id)?.body == "phone edit after the delete")
        #expect(phone.store.script(id: b.id)?.body == "phone edit after the delete")
        #expect(mac.store.syncRecords == phone.store.syncRecords)
    }

    @Test func aSameInstantConflictEndsTheSameOnBothSides() throws {
        let shared = mac.store.create(title: "Shared", body: "v1")
        connect()
        disconnect()
        // Both edit at exactly the same moment on the shared clock: a real tie.
        mac.store.update(shared.id, body: "Mac at the same instant")
        phone.store.update(shared.id, body: "iPhone at the same instant")
        connect()
        #expect(mac.store.script(id: shared.id)?.body == phone.store.script(id: shared.id)?.body)
        #expect(mac.store.syncRecords == phone.store.syncRecords)
    }

    @Test func typingQuicklySendsEveryVersionInOrder() {
        let script = mac.store.create(title: "Typing", body: "")
        connect()
        for count in 1...20 {
            mac.store.update(script.id, body: String(repeating: "a", count: count))
        }
        deliverAll()
        #expect(phone.store.script(id: script.id)?.body == String(repeating: "a", count: 20))
    }

    @Test func aNewerPeerIsReportedAsIncompatible() {
        var events: [SyncSession.Event] = []
        let session = SyncSession(
            local: SyncHello(deviceID: "A", name: "A", platform: .mac, protocolVersion: 1),
            library: mac.store, send: { _ in }, onEvent: { events.append($0) }
        )
        let future = SyncHello(deviceID: "B", name: "B", platform: .iPhone, protocolVersion: 99)
        session.receive(.hello(future))
        #expect(events == [.incompatible(future)])
    }

    // M8 review: a big library goes out in several frames, each well under what the receiver accepts.
    @Test func aBigLibraryIsSplitIntoFramesTheReceiverAccepts() throws {
        // 14 scripts of about 700 KB: about 10 MB in all, more than two batches' worth.
        let paragraph = String(repeating: "Look into the lens and speak slowly. ", count: 19_000)
        var ids: [UUID] = []
        for index in 0..<14 {
            ids.append(mac.store.create(title: "Long \(index)", body: paragraph).id)
        }
        connect()
        let scriptMessages = sentByMac.compactMap { message -> [SyncedScript]? in
            if case .scripts(let scripts) = message { return scripts }
            return nil
        }
        #expect(scriptMessages.count >= 3, "split into several messages")
        for message in sentByMac {
            let frame = SyncFrame.encode(try SyncMessageCoder.encode(message))
            #expect(frame.count <= SyncSession.maximumBatchBytes + 64 * 1024)
            #expect(frame.count < SyncFrame.maximumLength)
        }
        #expect(scriptMessages.flatMap { $0 }.count == ids.count, "every script sent once")
        for id in ids { #expect(phone.store.script(id: id)?.body == paragraph) }
        #expect(phoneSession.unacknowledged == 0)
        #expect(macSession.unacknowledged == 0)
    }

    @Test func batchesKeepOrderAndPutAnOversizedScriptAlone() {
        let small = SyncedScript(script: syncScript(), clock: 1)
        let batches = SyncSession.batches(
            [(small, 40), (small, 40), (small, 150), (small, 10), (small, 50)], limit: 100
        )
        #expect(batches.map(\.count) == [2, 1, 2])
    }
}
