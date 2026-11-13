import Foundation
import Network
import Testing
#if os(macOS)
@testable import PrompterMac
#else
@testable import Prompter
#endif

/// Framing, message coding, pairing codes and key derivation.
struct SyncProtocolTests {
    // MARK: Framing

    @Test func aFrameIsALengthPrefixAndThePayload() {
        let frame = SyncFrame.encode(Data("hello".utf8))
        #expect(Array(frame.prefix(4)) == [0, 0, 0, 5])
        #expect(frame.dropFirst(4) == Data("hello".utf8))
    }

    @Test func framesSurviveAnySplitOfTheStream() throws {
        let payloads = [Data("one".utf8), Data(), Data(repeating: 7, count: 70_000), Data("last".utf8)]
        let stream = payloads.reduce(into: Data()) { $0.append(SyncFrame.encode($1)) }
        for chunkSize in [1, 3, 4, 5, 1000, stream.count] {
            var decoder = SyncFrameDecoder()
            var received: [Data] = []
            var offset = 0
            while offset < stream.count {
                let end = min(offset + chunkSize, stream.count)
                received += try decoder.append(stream.subdata(in: offset..<end))
                offset = end
            }
            #expect(received == payloads, "chunk size \(chunkSize)")
            #expect(decoder.pendingByteCount == 0)
        }
    }

    @Test func anOversizedFrameIsRefused() {
        var decoder = SyncFrameDecoder()
        let length = UInt32(SyncFrame.maximumLength + 1).bigEndian
        let header = withUnsafeBytes(of: length) { Data($0) }
        #expect(throws: SyncFrame.TooLarge.self) { _ = try decoder.append(header) }
    }

    @Test func aHalfFrameWaitsForTheRest() throws {
        var decoder = SyncFrameDecoder()
        let frame = SyncFrame.encode(Data("abcdef".utf8))
        #expect(try decoder.append(frame.prefix(7)).isEmpty)
        #expect(try decoder.append(frame.dropFirst(7)) == [Data("abcdef".utf8)])
    }

    // MARK: Messages

    @Test func everyMessageRoundTrips() throws {
        let script = Script(
            title: "Intro “quoted”", body: "Line one\n\n// note\n[pause 2]\nÜnïcödé ✓",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), updatedAt: Date(timeIntervalSince1970: 1_800_000_060)
        )
        let hello = SyncHello(deviceID: "A", name: "Sam's MacBook", platform: .mac, protocolVersion: 1)
        let messages: [SyncMessage] = [
            .hello(hello),
            .manifest([SyncedScript(script: script, clock: 1_800_000_060.123).entry, SyncTombstone(id: UUID(), deletedAt: 5).entry]),
            .scripts([SyncedScript(script: script, clock: 1_800_000_060.123)]),
            .deletions([SyncTombstone(id: UUID(), deletedAt: 1_800_000_100.5)]),
            .ack(count: 3),
            .pairRequest(hello),
            .pairAccepted(hello, key: SyncPairing.makeDeviceKey()),
            .unpair,
            .remoteSubscribe(true),
            .remoteSubscribe(false),
            .remote(.start, id: 1),
            .remote(.speedStep(-5), id: 2),
            .remote(.setSpeed(140), id: 3),
            .remote(.requestStatus, id: 4),
            .presenterStatus(remoteSyncStatus, replyTo: 7),
            .presenterStatus(remoteSyncStatus, replyTo: nil),
            .presenterStatus(.noPrompter, replyTo: nil),
        ]
        for message in messages {
            #expect(try SyncMessageCoder.decode(SyncMessageCoder.encode(message)) == message)
        }
    }

    // MARK: Remote for the Mac (M9)

    /// Prompter for Mac presenting.
    private var remoteSyncStatus: PrompterStatus {
        PrompterStatus(
            hasPrompter: true, scriptTitle: "Mac take “one”", state: .countdown(3), progress: 0.5, remainingSeconds: 61,
            speedLabel: "140 wpm", sequence: 812_345_678_901, deviceName: "Sam's MacBook Pro"
        )
    }

    @Test func aPresenterStatusWithAnInfiniteTimeLeftStillTravels() throws {
        var status = remoteSyncStatus
        status.remainingSeconds = .infinity
        let decoded = try SyncMessageCoder.decode(SyncMessageCoder.encode(.presenterStatus(status, replyTo: nil)))
        guard case .presenterStatus(let back, nil) = decoded else {
            Issue.record("decoded \(decoded)")
            return
        }
        #expect(back.remainingSeconds == .infinity)
    }

    /// An app that doesn't know a message (a newer one's) can't decode it: `SyncConnection` then skips that frame and
    /// keeps the connection. So the remote messages need no new protocol version, and neither will the next ones.
    @Test func anUnknownMessageFailsToDecodeAndNothingElse() throws {
        let unknown = Data(#"{"somethingNew":{"_0":true}}"#.utf8)
        #expect(throws: (any Error).self) { try SyncMessageCoder.decode(unknown) }
        // The known ones around it are untouched.
        #expect(try SyncMessageCoder.decode(SyncMessageCoder.encode(.ack(count: 1))) == .ack(count: 1))
        // An older iPhone's view of a remote message: still one it doesn't know.
        let remote = try SyncMessageCoder.encode(.remote(.start, id: 1))
        #expect(String(decoding: remote, as: UTF8.self).contains("remote"))
    }

    @Test func aStatusFromAnOlderMacWithoutTheNewFieldsDecodes() throws {
        let json = #"{"presenterStatus":{"_0":{"hasPrompter":true,"scriptTitle":"Old","state":{"playing":{}},"#
            + #""progress":0.1,"remainingSeconds":10,"speedLabel":"Speed 3.0","sequence":1}}}"#
        let decoded = try SyncMessageCoder.decode(Data(json.utf8))
        guard case .presenterStatus(let status, let replyTo) = decoded else {
            Issue.record("decoded \(decoded)")
            return
        }
        #expect(replyTo == nil)
        #expect(status.deviceName == nil && status.note == nil)
        #expect(status.scriptTitle == "Old")
    }

    @Test func clocksKeepTheirMilliseconds() throws {
        let synced = SyncedScript(script: syncScript(), clock: 1_800_000_000.001)
        let decoded = try SyncMessageCoder.decode(SyncMessageCoder.encode(.scripts([synced])))
        #expect(decoded == .scripts([synced]))
    }

    // MARK: Pairing

    @Test func codesAreTwelveDigits() {
        #expect(SyncPairing.codeLength == 12)
        for _ in 0..<200 {
            let code = SyncPairing.makeCode()
            #expect(code.count == 12)
            #expect(code.allSatisfy { $0.isASCII && $0.isNumber })
        }
    }

    @Test func codesKeepLeadingZeros() {
        // A tiny fixed value: `Int64.random(in: 0..<1_000_000_000_000)` then gives 0. (Exactly 0 makes its rejection
        // sampling loop forever.)
        struct Fixed: RandomNumberGenerator {
            mutating func next() -> UInt64 { 1 << 20 }
        }
        var generator = Fixed()
        #expect(SyncPairing.makeCode(using: &generator) == "000000000000")
    }

    @Test func typedCodesAreNormalized() {
        #expect(SyncPairing.normalizedCode("123456789012") == "123456789012")
        #expect(SyncPairing.normalizedCode(" 123 456 789 012 ") == "123456789012")
        #expect(SyncPairing.normalizedCode("123-456-789-012") == "123456789012")
        #expect(SyncPairing.normalizedCode("123456") == nil, "an old 6-digit code")
        #expect(SyncPairing.normalizedCode("12345678901") == nil)
        #expect(SyncPairing.normalizedCode("1234567890123") == nil)
        #expect(SyncPairing.normalizedCode("12345678901a") == nil)
        #expect(SyncPairing.normalizedCode("١٢٣٤٥٦٧٨٩٠١٢") == nil, "ASCII digits only")
        #expect(SyncPairing.displayCode("042913075266") == "042 913 075 266")
        #expect(SyncPairing.displayCode("123") == "123", "anything else shows as it is")
    }

    @Test func theStretchingIsWhatTheSecurityNoteAssumes() {
        // `SyncPairing`'s note works out the odds of a fake Mac cracking a code from these numbers.
        #expect(SyncPairing.keyStretchingRounds == 1_000_000)
        #expect(SyncPairing.codeLength == 12)
        #expect(SyncPairing.codeLifetime == 300)
        #expect(SyncPairing.maximumFailedAttempts == 5)
        #expect(SyncPairing.pairingIdentity == "pair-v2", "not version 1's \"pair\", so old and new apps never meet as a wrong code")
        #expect(SyncPairing.pairingVersion == 2)
    }

    @Test func thePairingKeyIsDeterministicAndDependsOnTheCode() {
        let key = SyncPairing.pairingKey(code: "123456789012")
        #expect(key.count == 32)
        #expect(key == SyncPairing.pairingKey(code: "123456789012"))
        #expect(key != SyncPairing.pairingKey(code: "123456789013"))
        // Pinned, so a change to the derivation (which would stop old and new apps pairing) can't slip through. The value
        // is PBKDF2-HMAC-SHA256 with 1,000,000 rounds as Python's hashlib computes it, so the rounds really happen.
        #expect(key.map { String(format: "%02x", $0) }.joined() == "db7ee842aa1e0bb28a79dec9d573b22df299323d8323209d8cebdee192ddf1c9")
    }

    @Test func stretchingTheKeyTakesRealWorkAndRunsOffTheMainThread() async {
        let started = Date.now
        let key = await SyncPairing.derivePairingKey(code: "123456789012")
        let seconds = Date.now.timeIntervalSince(started)
        #expect(key == SyncPairing.pairingKey(code: "123456789012"))
        // About 0.1 s on Apple silicon; a cheap hash would take microseconds.
        #expect(seconds > 0.02, "took \(seconds) s")
    }

    @MainActor
    @Test func aMacWithAnOlderOrNewerPairingSchemeAsksForAnUpdateNotACode() throws {
        let library = try StoreFixture()
        let directory = try makeSyncTestDirectory()
        defer {
            library.remove()
            try? FileManager.default.removeItem(at: directory)
        }
        let client = SyncClient(library: library.store, pairing: PairingStore(directory: directory), name: "iPhone")
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 9)

        // A Mac from before 12-digit codes advertises no pairing version: tapping it says to update the Mac.
        let old = SyncClient.FoundMac(id: "A", name: "Old Mac", endpoint: endpoint, pairingVersion: nil)
        let updateMac = "Old Mac has an older Prompter. Update Prompter on the Mac, then pair again."
        #expect(client.pairingProblem(with: old) == updateMac)
        #expect(!client.checkCanPair(with: old))
        #expect(client.pairingState == .failed(updateMac))
        client.pair(with: old, code: "123456789012")
        #expect(client.pairingState == .failed(updateMac), "no connection is tried")

        // A Mac from a later version: update this device.
        let newer = SyncClient.FoundMac(id: "B", name: "New Mac", endpoint: endpoint, pairingVersion: SyncPairing.pairingVersion + 1)
        #expect(!client.checkCanPair(with: newer))
        #expect(client.pairingState == .failed("New Mac has a newer Prompter. Update Prompter on this iPhone, then pair again."))
        let iPad = SyncClient(
            library: library.store, pairing: PairingStore(directory: directory), name: "iPad", platform: .iPad
        )
        #expect(iPad.pairingProblem(with: newer) == "New Mac has a newer Prompter. Update Prompter on this iPad, then pair again.")

        // The same version: no problem, and a code of the wrong length is caught before connecting.
        let current = SyncClient.FoundMac(id: "C", name: "Mac", endpoint: endpoint)
        #expect(client.pairingProblem(with: current) == nil)
        client.pair(with: current, code: "123 456")
        #expect(client.pairingState == .failed("Enter the 12-digit code shown on your Mac."))
    }

    // MARK: What the Mac advertises (pairing hardening)

    @MainActor
    @Test func theMacAdvertisesItsNameOnlyWhileACodeIsShowing() async throws {
        let library = try StoreFixture()
        let directory = try makeSyncTestDirectory()
        defer {
            library.remove()
            try? FileManager.default.removeItem(at: directory)
        }
        let host = SyncHost(
            library: library.store, pairing: PairingStore(directory: directory), name: "Sam's MacBook Pro", advertises: false
        )
        // Paired, no code showing: a neutral name and only the random id a paired iPhone looks for.
        let neutral = "Prompter \(host.pairing.deviceID.prefix(4))"
        var advert = host.advertisement
        #expect(advert.serviceName == neutral)
        #expect(!advert.serviceName.contains("Sam"))
        #expect(advert.txtRecord["name"] == nil)
        #expect(advert.txtRecord["open"] == nil)
        #expect(advert.txtRecord["id"] == host.pairing.deviceID)
        #expect(advert.txtRecord["pv"] == "2")

        // A code showing: the name, so the person can pick this Mac on the iPhone.
        host.beginPairing(code: "123456789012")
        let deadline = Date.now.addingTimeInterval(5)
        while host.pairingWindow?.key == nil, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        advert = host.advertisement
        #expect(advert.serviceName == "Sam's MacBook Pro")
        #expect(advert.txtRecord["name"] == "Sam's MacBook Pro")
        #expect(advert.txtRecord["open"] == "1")

        // The code closes: neutral again.
        host.cancelPairing()
        advert = host.advertisement
        #expect(advert.serviceName == neutral)
        #expect(advert.txtRecord["name"] == nil)
    }

    @Test func theIPhoneOffersOnlyMacsShowingACode() {
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 9)
        func txt(_ pairs: [String: String]) -> NWTXTRecord {
            var record = NWTXTRecord()
            for (key, value) in pairs { record[key] = value }
            return record
        }
        // A Mac with no code showing: found (a paired iPhone connects to it by id), but not offered for pairing.
        let quiet = SyncClient.foundMac(serviceName: "Prompter", txt: txt(["id": "A", "v": "1", "pv": "2"]), endpoint: endpoint, isDemo: false)
        #expect(quiet?.id == "A")
        #expect(quiet?.name == "Prompter")
        #expect(quiet?.isShowingCode == false)
        // Showing a code: its name, offered.
        let pairing = SyncClient.foundMac(
            serviceName: "Studio", txt: txt(["id": "B", "name": "Studio", "v": "1", "pv": "2", "open": "1"]), endpoint: endpoint, isDemo: false
        )
        #expect(pairing?.name == "Studio")
        #expect(pairing?.isShowingCode == true)
        #expect(pairing?.pairingVersion == 2)
        // A Mac from before 12-digit codes always shows its name: offered, so it can say it needs an update.
        let old = SyncClient.foundMac(serviceName: "Old", txt: txt(["id": "C", "name": "Old Mac", "v": "1"]), endpoint: endpoint, isDemo: false)
        #expect(old?.isShowingCode == true)
        #expect(old?.pairingVersion == nil)
        // No id, or a demo Mac for a real iPhone: not shown.
        #expect(SyncClient.foundMac(serviceName: "X", txt: txt(["v": "1"]), endpoint: endpoint, isDemo: false) == nil)
        #expect(SyncClient.foundMac(serviceName: "X", txt: txt(["id": "D", "demo": "1"]), endpoint: endpoint, isDemo: false) == nil)
        #expect(SyncClient.foundMac(serviceName: "X", txt: txt(["id": "D", "demo": "1"]), endpoint: endpoint, isDemo: true) != nil)

        // The same Mac under both names for a moment: the entry showing a code wins, whichever came first.
        let both = [quiet!, SyncClient.FoundMac(id: "A", name: "Studio", endpoint: endpoint, isShowingCode: true)]
        #expect(SyncClient.merged(both).map(\.name) == ["Studio"])
        #expect(SyncClient.merged(both.reversed()).map(\.name) == ["Studio"])
        #expect(SyncClient.merged(both).first?.isShowingCode == true)
        #expect(SyncClient.merged([pairing!, old!, quiet!]).map(\.id) == ["C", "A", "B"], "one each, by name")
    }

    @Test func deviceKeysAreRandom() {
        let a = SyncPairing.makeDeviceKey()
        let b = SyncPairing.makeDeviceKey()
        #expect(a.count == 32)
        #expect(a != b)
    }

    @Test func launchOptionsParse() {
        let options = SyncLaunchOptions(arguments: [
            "app", "-syncPairingCode", "123 456 789 012", "-syncDemo", "-syncPort", "50123", "-syncHost", "127.0.0.1:50124",
        ])
        #expect(options.pairingCode == "123456789012")
        #expect(options.demo)
        #expect(options.port == 50123)
        #expect(options.host == "127.0.0.1")
        #expect(options.hostPort == 50124)
        let none = SyncLaunchOptions(arguments: ["app", "-demoData"])
        #expect(none.pairingCode == nil && !none.demo && none.port == nil && none.host == nil)
        #expect(SyncLaunchOptions(arguments: ["app", "-syncPairingCode", "12"]).pairingCode == nil)
        #expect(SyncLaunchOptions(arguments: ["app", "-syncPairingCode", "123456"]).pairingCode == nil, "6 digits are too few now")
    }

    @Test func reconnectBacksOff() {
        #expect([1, 2, 3, 4, 5, 6, 10].map(SyncClient.retryDelay(afterFailures:)) == [1, 2, 4, 8, 16, 30, 30])
        #expect(SyncClient.retryDelay(afterFailures: 0) == 1)
    }

    // MARK: Proof of key (M8 review)

    @Test func aHelloProofOnlyWorksWithTheSameKeyIDAndSession() {
        let key = SyncPairing.makeDeviceKey()
        let session = Data(repeating: 7, count: 32)
        let proof = SyncPairing.proof(key: key, deviceID: "PHONE", sessionSecret: session)
        #expect(SyncPairing.verify(proof: proof, key: key, deviceID: "PHONE", sessionSecret: session))
        #expect(!SyncPairing.verify(proof: proof, key: SyncPairing.makeDeviceKey(), deviceID: "PHONE", sessionSecret: session))
        #expect(!SyncPairing.verify(proof: proof, key: key, deviceID: "OTHER", sessionSecret: session))
        #expect(!SyncPairing.verify(proof: proof, key: key, deviceID: "PHONE", sessionSecret: Data(repeating: 8, count: 32)))
        #expect(!SyncPairing.verify(proof: nil, key: key, deviceID: "PHONE", sessionSecret: session))
        #expect(!SyncPairing.verify(proof: proof, key: key, deviceID: "PHONE", sessionSecret: nil))
    }

    @Test func aHelloWithoutAProofStillDecodes() throws {
        // What an app from before the proof sends: decodes, with no proof (and is then refused by the Mac).
        let json = #"{"hello":{"_0":{"deviceID":"A","name":"Mac","platform":"mac","protocolVersion":1}}}"#
        #expect(try SyncMessageCoder.decode(Data(json.utf8)) == .hello(SyncHello(deviceID: "A", name: "Mac", platform: .mac, protocolVersion: 1)))
    }

    // MARK: Pairing file (M8 review)

    @MainActor
    @Test func aDamagedPairingFileIsKeptAndTheResetIsReported() throws {
        let directory = try makeSyncTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = PairingStore(directory: directory)
        #expect(!first.pairingDataWasReset)
        let firstID = first.deviceID
        try Data("{ not json".utf8).write(to: directory.appending(path: "sync.json"))

        let reset = PairingStore(directory: directory)
        #expect(reset.pairingDataWasReset)
        #expect(reset.deviceID != firstID)
        #expect(reset.devices.isEmpty)
        let kept = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
            .filter { $0.hasPrefix("sync-corrupt-") }
        #expect(kept.count == 1)
        if let name = kept.first {
            #expect(try Data(contentsOf: directory.appending(path: name)) == Data("{ not json".utf8))
        }
        reset.acknowledgePairingReset()
        #expect(!reset.pairingDataWasReset)
        // The new file reads fine next time: no second reset.
        #expect(!PairingStore(directory: directory).pairingDataWasReset)
    }
}
