import CryptoKit
import Foundation
import Network
import Testing
@testable import PrompterMac

/// The real thing in one process: a `SyncHost` (the Mac's side) and a `SyncClient` (the iPhone's side), each with its own
/// library and pairing file, talking over real TLS connections on 127.0.0.1. No Bonjour (loopback needs no Local Network
/// permission), so the client connects to the listener's port directly, as `-syncHost` does.
@MainActor
@Suite(.serialized)
final class SyncLoopbackTests {
    let mac: StoreFixture
    let phone: StoreFixture
    let host: SyncHost
    let client: SyncClient
    nonisolated let directories: [URL]

    init() throws {
        mac = try StoreFixture()
        phone = try StoreFixture()
        let macPairing = try makeSyncTestDirectory()
        let phonePairing = try makeSyncTestDirectory()
        directories = [mac.directory, phone.directory, macPairing, phonePairing]
        host = SyncHost(
            library: mac.store, pairing: PairingStore(directory: macPairing), name: "Test Mac", advertises: false
        )
        client = SyncClient(library: phone.store, pairing: PairingStore(directory: phonePairing), name: "Test iPhone")
        mac.store.onLocalChange = { [weak host] in host?.libraryChanged() }
        phone.store.onLocalChange = { [weak client] in client?.libraryChanged() }
    }

    deinit {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: Helpers

    /// Polls `condition` until it holds or `timeout` passes (the network callbacks run while this waits).
    @discardableResult
    private func waitUntil(_ timeout: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition() {
            if Date.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// Waits until the code showing on the Mac works: its key is stretched and the listener has it.
    private func waitForCode() async -> Bool {
        await waitUntil {
            guard host.pairingWindow?.key != nil else { return false }
            if case .advertising = host.listenerState { return true }
            return false
        }
    }

    /// Starts the host with a pairing code showing and points the client at its port.
    private func startHost(code: String = "123456789012") async throws {
        host.start()
        host.beginPairing(code: code)
        let ready = await waitForCode()
        try #require(ready, "the listener should start")
        guard case .advertising(let port) = host.listenerState else { return }
        client.directEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
    }

    private func pairAndConnect() async throws {
        try await startHost()
        client.autoPairCode = "123456789012"
        client.setActive(true)
        let connected = await waitUntil { client.status == .connected && !host.connectedDeviceIDs.isEmpty }
        try #require(connected, "paired and connected (status \(client.status), pairing \(client.pairingState))")
    }

    private func shutDown() {
        client.setActive(false)
        host.stop()
    }

    // MARK: Tests

    @Test func pairsThenSyncsCreatesEditsAndDeletesBothWays() async throws {
        defer { shutDown() }
        try await pairAndConnect()
        #expect(client.pairedMac?.name == "Test Mac")
        #expect(host.pairing.devices.map(\.name) == ["Test iPhone"])
        #expect(host.pairingWindow == nil, "the code closes once an iPhone has paired")
        #expect(host.pairingMessage == "Paired with Test iPhone.")
        #expect(client.pairedMac?.key == host.pairing.devices.first?.key)
        #expect(client.pairedMac?.key != SyncPairing.pairingKey(code: "123456789012"), "the code is only used to pair")

        // Mac → iPhone: create.
        let started = Date.now
        let script = mac.store.create(title: "Written on the Mac", body: "Look into the lens.")
        #expect(await waitUntil { phone.store.script(id: script.id) == script })
        let latency = Date.now.timeIntervalSince(started)
        #expect(latency < 2, "arrived in \(latency) s")

        // iPhone → Mac: edit.
        phone.clock.advance(by: 5)
        phone.store.update(script.id, body: "Edited on the iPhone.")
        #expect(await waitUntil { mac.store.script(id: script.id)?.body == "Edited on the iPhone." })

        // Mac → iPhone: delete.
        mac.clock.advance(by: 10)
        mac.store.delete(script.id)
        #expect(await waitUntil { phone.store.script(id: script.id) == nil })
        #expect(phone.store.tombstones[script.id] != nil)

        // iPhone → Mac: create.
        let fromPhone = phone.store.create(title: "Written on the iPhone", body: "Words")
        #expect(await waitUntil { mac.store.script(id: fromPhone.id) != nil })
        #expect(await waitUntil { mac.store.syncRecords == phone.store.syncRecords })
        #expect(host.pairing.devices.first?.lastSyncedAt != nil)
    }

    @Test func aWrongCodeIsRefusedAndCounted() async throws {
        defer { shutDown() }
        try await startHost(code: "111111111111")
        client.autoPairCode = "222222222222"
        client.setActive(true)
        let failed = await waitUntil { if case .failed = client.pairingState { true } else { false } }
        #expect(failed)
        #expect(client.pairingState == .failed("That code didn't work. Check the code on your Mac and try again."))
        #expect(client.pairedMac == nil)
        #expect(host.pairing.devices.isEmpty)
        #expect(await waitUntil { host.pairingWindow?.failedAttempts == 1 })
    }

    @Test func tooManyWrongCodesClosePairing() async throws {
        defer { shutDown() }
        try await startHost(code: "111111111111")
        guard case .advertising(let port) = host.listenerState else { return }
        for attempt in 1...SyncPairing.maximumFailedAttempts {
            let guess = SyncConnection(
                to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                keys: [SyncTransport.PresharedKey(identity: SyncPairing.pairingIdentity, key: SyncPairing.pairingKey(code: "99999999999\(attempt)"))]
            )
            var ended: SyncConnection.Ending?
            guess.onEnd = { ended = $0 }
            guess.start()
            #expect(await waitUntil { ended != nil })
            #expect(ended == .handshakeRefused)
        }
        #expect(await waitUntil { host.pairingWindow == nil })
        #expect(host.pairingMessage == "Too many wrong codes. Click Pair an iPhone to try again.")
    }

    @Test func aForgottenIPhoneIsRefused() async throws {
        defer { shutDown() }
        try await pairAndConnect()
        let phoneID = try #require(host.pairing.devices.first?.deviceID)
        host.forget(deviceID: phoneID)
        // With nobody paired the Mac stops listening, so the iPhone can't find it.
        #expect(await waitUntil { client.status != .connected && client.status != .connecting })
        #expect(host.connectedDeviceIDs.isEmpty)
        #expect(host.listenerState == .off)
        // While the Mac listens again (pairing another iPhone), this one's old key is refused.
        host.beginPairing(code: "654321654321")
        #expect(await waitUntil(35) { client.status == .refused })
        // Its old key isn't a wrong code: the person pairing it again still has every attempt.
        #expect(host.pairingWindow?.failedAttempts == 0)
        // It stays out and stops knocking: nothing it writes reaches the Mac, and it doesn't retry by itself.
        let attempts = client.connectionAttempts
        let script = phone.store.create(title: "Not for the Mac", body: "Words")
        try? await Task.sleep(for: .seconds(3))
        #expect(mac.store.script(id: script.id) == nil)
        #expect(client.connectionAttempts == attempts, "no retries after the Mac refused it")
        #expect(client.status == .refused)
        #expect(host.pairingWindow?.failedAttempts == 0)
        #expect(host.pairingWindow != nil, "the code is still open")

        // Pairing again with the code on the Mac works, and sync picks up where it left off.
        let endpoint = try #require(client.directEndpoint)
        client.pair(with: SyncClient.FoundMac(id: "direct", name: "Test Mac", endpoint: endpoint), code: "654321654321")
        #expect(await waitUntil { client.status == .connected && !host.connectedDeviceIDs.isEmpty },
                "paired again (status \(client.status), pairing \(client.pairingState))")
        #expect(host.pairingMessage == "Paired with Test iPhone.")
        #expect(await waitUntil { mac.store.script(id: script.id) != nil })
    }

    @Test func aRefusedIPhoneTriesAgainOnSyncNow() async throws {
        defer { shutDown() }
        try await pairAndConnect()
        let phoneID = try #require(host.pairing.devices.first?.deviceID)
        host.forget(deviceID: phoneID)
        host.beginPairing(code: "654321654321")
        #expect(await waitUntil(35) { client.status == .refused })
        let attempts = client.connectionAttempts
        client.syncNow()
        #expect(await waitUntil { client.connectionAttempts > attempts }, "Sync now tries again")
        #expect(await waitUntil(10) { client.status == .refused })
    }

    @Test func forgettingOnTheIPhoneUnpairsTheMacToo() async throws {
        defer { shutDown() }
        try await pairAndConnect()
        client.forget()
        #expect(client.status == .notPaired)
        #expect(await waitUntil { host.pairing.devices.isEmpty })
    }

    @Test func goingToTheBackgroundDisconnectsAndComingBackCatchesUp() async throws {
        defer { shutDown() }
        try await pairAndConnect()
        client.setActive(false)
        #expect(client.status == .paused)
        #expect(await waitUntil { host.connectedDeviceIDs.isEmpty }, "the Mac sees the iPhone leave")

        let whileAway = mac.store.create(title: "Written while the iPhone was away", body: "Words")
        try? await Task.sleep(for: .milliseconds(500))
        #expect(phone.store.script(id: whileAway.id) == nil)

        client.setActive(true)
        #expect(await waitUntil { phone.store.script(id: whileAway.id) != nil }, "caught up on return")
        #expect(client.status == .connected)
    }

    @Test func theIPhoneReconnectsWhenTheMacComesBack() async throws {
        defer { shutDown() }
        try await pairAndConnect()
        host.stop()
        #expect(await waitUntil { client.status != .connected })
        host.start()
        // The retry back-off is 1 s, then 2 s.
        #expect(await waitUntil(15) { client.status == .connected })
        let script = mac.store.create(title: "After the Mac came back", body: "Words")
        #expect(await waitUntil { phone.store.script(id: script.id) != nil })
    }

    // MARK: M8 review

    /// Another iPhone (or iPad) with its own library and pairing, pointed at the same Mac.
    private func makeSecondClient(code: String) async throws -> (client: SyncClient, library: StoreFixture, pairing: URL) {
        let library = try StoreFixture()
        let pairingDirectory = try makeSyncTestDirectory()
        let second = SyncClient(
            library: library.store, pairing: PairingStore(directory: pairingDirectory), name: "Test iPad", platform: .iPad
        )
        library.store.onLocalChange = { [weak second] in second?.libraryChanged() }
        host.beginPairing(code: code)
        #expect(await waitForCode())
        second.directEndpoint = client.directEndpoint
        second.autoPairCode = code
        second.setActive(true)
        return (second, library, pairingDirectory)
    }

    @Test func theMacPassesChangesFromOneDeviceToTheOthers() async throws {
        defer { shutDown() }
        try await pairAndConnect()
        let second = try await makeSecondClient(code: "222333444555")
        defer {
            second.client.setActive(false)
            second.library.remove()
            try? FileManager.default.removeItem(at: second.pairing)
        }
        #expect(await waitUntil { second.client.status == .connected && host.connectedDeviceIDs.count == 2 })

        // iPhone → Mac → iPad, while all three are connected.
        let script = phone.store.create(title: "From the iPhone", body: "Words")
        #expect(await waitUntil { mac.store.script(id: script.id) == script })
        #expect(await waitUntil { second.library.store.script(id: script.id) == script }, "relayed by the Mac")

        // iPad → Mac → iPhone.
        second.library.clock.advance(by: 5)
        second.library.store.update(script.id, body: "Edited on the iPad")
        #expect(await waitUntil { phone.store.script(id: script.id)?.body == "Edited on the iPad" })
        #expect(await waitUntil {
            mac.store.syncRecords == phone.store.syncRecords && phone.store.syncRecords == second.library.store.syncRecords
        })
    }

    @Test func pushesStillGoOutAfterSyncOnTheMacRestarts() async throws {
        defer { shutDown() }
        try await pairAndConnect()
        // A change whose push is still on its way when sync stops.
        _ = mac.store.create(title: "Just before the stop", body: "Words")
        host.stop()
        #expect(await waitUntil { client.status != .connected })
        host.start()
        #expect(await waitUntil(15) { client.status == .connected && !host.connectedDeviceIDs.isEmpty })
        let after = mac.store.create(title: "After the restart", body: "Words")
        #expect(await waitUntil(3) { phone.store.script(id: after.id) != nil }, "pushed, not only on the next reconnect")
    }

    @Test func aConnectionMadeWithThePairingCodeCantSpeakAsAPairedIPhone() async throws {
        defer { shutDown() }
        try await pairAndConnect()
        let phoneID = client.hello.deviceID
        host.beginPairing(code: "777888999000")
        #expect(await waitForCode())
        let endpoint = try #require(client.directEndpoint)
        let intruder = SyncConnection(
            to: endpoint,
            keys: [SyncTransport.PresharedKey(identity: SyncPairing.pairingIdentity, key: SyncPairing.pairingKey(code: "777888999000"))]
        )
        var wasReady = false
        var tlsVersion: tls_protocol_version_t?
        var ended: SyncConnection.Ending?
        intruder.onReady = { [weak intruder] in
            wasReady = true
            tlsVersion = intruder?.negotiatedTLSVersion
            intruder?.send(.hello(SyncHello(deviceID: phoneID, name: "Intruder", platform: .iPhone, protocolVersion: 1)))
            intruder?.send(.manifest([]))
        }
        intruder.onEnd = { ended = $0 }
        intruder.start()
        #expect(await waitUntil { ended != nil })
        #expect(wasReady, "TLS came up: the code is right")
        #expect(tlsVersion == .TLSv12, "pinned to TLS 1.2: a TLS 1.3 PSK binder would let a listener test codes")
        #expect(ended == .closedByPeer || ended.map { if case .failed = $0 { true } else { false } } == true)
        #expect(client.status == .connected, "the real iPhone's session is untouched")
        #expect(host.connectedDeviceIDs == [phoneID])
        #expect(host.pairing.devices.count == 1)
    }

    @Test func silentConnectionsAreClosedAndOnlyAFewMayWaitAtOnce() async throws {
        let pairingDirectory = try makeSyncTestDirectory()
        defer { try? FileManager.default.removeItem(at: pairingDirectory) }
        let quickHost = SyncHost(
            library: mac.store, pairing: PairingStore(directory: pairingDirectory), name: "Quick Mac", advertises: false,
            handshakeTimeout: .seconds(2)
        )
        quickHost.start()
        defer { quickHost.stop() }
        quickHost.beginPairing(code: "123123123123")
        #expect(await waitUntil { quickHost.pairingWindow?.key != nil && quickHost.listenerState != .off })
        #expect(await waitUntil { if case .advertising = quickHost.listenerState { true } else { false } })
        guard case .advertising(let port) = quickHost.listenerState else { return }

        // Six connections from one address finish TLS (they know the code) and then say nothing.
        var endings: [Int: SyncConnection.Ending] = [:]
        var connections: [SyncConnection] = []
        let key = SyncPairing.pairingKey(code: "123123123123")
        for index in 0..<6 {
            let connection = SyncConnection(
                to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                keys: [SyncTransport.PresharedKey(identity: SyncPairing.pairingIdentity, key: key)]
            )
            connection.onEnd = { endings[index] = $0 }
            connection.start()
            connections.append(connection)
            try? await Task.sleep(for: .milliseconds(100))
        }
        let started = Date.now
        // Only two from one address may wait: each new one closed that address's oldest, so the first four are gone…
        #expect(await waitUntil(1.5) { endings.count >= 4 })
        #expect(Set(endings.keys) == [0, 1, 2, 3])
        #expect(quickHost.pendingConnectionCount == 2)
        // …and the last two are closed once the handshake time is up.
        #expect(await waitUntil(8) { endings.count == connections.count })
        #expect(Date.now.timeIntervalSince(started) > 1)
        #expect(quickHost.pairingWindow?.failedAttempts == 0, "silence isn't a wrong code")
        for connection in connections { connection.cancel() }
    }

    // MARK: 12-digit codes (pairing hardening)

    @Test func aPairingAttemptFromAnOlderAppIsNotCountedAsAWrongCode() async throws {
        defer { shutDown() }
        try await startHost(code: "123456789012")
        let endpoint = try #require(client.directEndpoint)
        // What an app from before 12-digit codes sends: the identity "pair" and a 6-digit code's HKDF key.
        let oldKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data("123456".utf8)),
            salt: Data("Prompter pairing salt v1".utf8),
            info: Data("prompter-sync pairing psk v1".utf8),
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
        let old = SyncConnection(to: endpoint, keys: [SyncTransport.PresharedKey(identity: "pair", key: oldKey)])
        var ended: SyncConnection.Ending?
        old.onEnd = { ended = $0 }
        old.start()
        #expect(await waitUntil { ended != nil })
        #expect(ended == .unknownIdentity)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(host.pairingWindow?.failedAttempts == 0, "it tried no code of this Mac's, so the person keeps every attempt")
        #expect(host.pairingWindow != nil)
    }

    @Test func pairingWithAMacThatShowsNoCodeSaysSo() async throws {
        defer { shutDown() }
        try await pairAndConnect()
        #expect(host.pairingWindow == nil)
        let library = try StoreFixture()
        let pairingDirectory = try makeSyncTestDirectory()
        defer {
            library.remove()
            try? FileManager.default.removeItem(at: pairingDirectory)
        }
        let second = SyncClient(library: library.store, pairing: PairingStore(directory: pairingDirectory), name: "Test iPad", platform: .iPad)
        second.setActive(true)
        defer { second.setActive(false) }
        let endpoint = try #require(client.directEndpoint)
        second.pair(with: SyncClient.FoundMac(id: "direct", name: "Test Mac", endpoint: endpoint), code: "123456789012")
        #expect(await waitUntil { if case .failed = second.pairingState { true } else { false } })
        #expect(second.pairingState == .failed(
            "Test Mac isn't showing a pairing code. On the Mac, click Pair an iPhone to get a new one. If the code there has 6 digits, update Prompter on the Mac."
        ))
        #expect(host.pairing.devices.count == 1)
    }

    // MARK: Connections that never start TLS (pairing hardening)

    /// Plain TCP connections to the Mac's port that never send a TLS hello, as a griefer on the same Wi-Fi could open.
    private func openSilentTCPConnections(count: Int, from host: NWEndpoint.Host, port: UInt16) async -> [NWConnection] {
        var connections: [NWConnection] = []
        for _ in 0..<count {
            let connection = NWConnection(host: host, port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            connection.start(queue: .main)
            connections.append(connection)
            try? await Task.sleep(for: .milliseconds(50))
        }
        return connections
    }

    @Test func silentTCPConnectionsCantLockAnIPhoneOut() async throws {
        defer { shutDown() }
        try await startHost(code: "123456789012")
        guard case .advertising(let port) = host.listenerState else { return }
        // More than the Mac lets wait, from two addresses, none of them ever starting TLS.
        let silent = await openSilentTCPConnections(count: 4, from: "127.0.0.1", port: port)
            + openSilentTCPConnections(count: 2, from: "::1", port: port)
        defer { for connection in silent { connection.cancel() } }
        try? await Task.sleep(for: .milliseconds(300))
        // The iPhone still pairs and connects, well before any of them would time out.
        client.autoPairCode = "123456789012"
        client.setActive(true)
        let connected = await waitUntil(2.5) { client.status == .connected && !host.connectedDeviceIDs.isEmpty }
        #expect(connected, "paired despite the silent connections (status \(client.status), pairing \(client.pairingState))")
    }

    @Test func aConnectionThatNeverStartsTLSIsClosedSoon() async throws {
        let pairingDirectory = try makeSyncTestDirectory()
        defer { try? FileManager.default.removeItem(at: pairingDirectory) }
        let quickHost = SyncHost(
            library: mac.store, pairing: PairingStore(directory: pairingDirectory), name: "Quick Mac", advertises: false,
            tlsHandshakeTimeout: .seconds(1)
        )
        quickHost.start()
        defer { quickHost.stop() }
        quickHost.beginPairing(code: "123123123123")
        #expect(await waitUntil { if case .advertising = quickHost.listenerState { true } else { false } })
        guard case .advertising(let port) = quickHost.listenerState else { return }
        let silent = await openSilentTCPConnections(count: 1, from: "127.0.0.1", port: port)
        defer { for connection in silent { connection.cancel() } }
        #expect(await waitUntil(1) { quickHost.pendingConnectionCount == 1 }, "the Mac took it (before any TLS)")
        let started = Date.now
        #expect(await waitUntil(3) { quickHost.pendingConnectionCount == 0 })
        let waited = Date.now.timeIntervalSince(started)
        #expect(waited < 2, "closed after the 1 s TLS limit, not the 10 s one (\(waited) s)")
        #expect(SyncHost.defaultTLSHandshakeTimeout == .seconds(3))
    }

    @Test func oneAddressHoldsAtMostTwoWaitingPlacesAndTheTotalIsCapped() async throws {
        try await startHost(code: "123456789012")
        defer { shutDown() }
        guard case .advertising(let port) = host.listenerState else { return }
        #expect(SyncHost.maximumPendingPerAddress == 2)
        #expect(SyncHost.maximumPendingConnections == 4)
        let fromOne = await openSilentTCPConnections(count: 5, from: "127.0.0.1", port: port)
        defer { for connection in fromOne { connection.cancel() } }
        #expect(await waitUntil(1) { host.pendingConnectionCount == 2 })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(host.pendingConnectionCount == 2, "five from one address leave two waiting")
        let fromOther = await openSilentTCPConnections(count: 3, from: "::1", port: port)
        defer { for connection in fromOther { connection.cancel() } }
        #expect(await waitUntil(1) { host.pendingConnectionCount == 4 })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(host.pendingConnectionCount == 4, "never more than four in all")
        #expect(SyncHost.address(of: .hostPort(host: "192.168.1.20", port: 50123)) == "192.168.1.20")
    }
}
