import Foundation
import Network
import Observation

/// The Mac's side of sync: advertises `_prompter-sync._tcp` over Bonjour, accepts TLS connections from paired iPhones
/// (and, while a pairing code is showing, from an iPhone that knows it), and runs a `SyncSession` with each.
///
/// The listener only runs while there is someone to talk to (a paired iPhone or an open pairing code), and it is rebuilt
/// whenever the set of keys changes; connections already open stay up.
@MainActor @Observable
final class SyncHost {
    struct PairingWindow: Equatable {
        var code: String
        /// When the code stops working (`SyncPairing.codeLifetime` after it was shown).
        var expiresAt: Date?
        /// Wrong codes tried so far (failed pairing handshakes); pairing closes at `SyncPairing.maximumFailedAttempts`.
        var failedAttempts = 0
        /// A debug code (`-syncPairingCode`, demo libraries only) that stays open after an iPhone pairs, until it expires.
        var staysOpenAfterPairing = false
        /// The code's stretched key (`SyncPairing.pairingKey`), worked out in the background a moment after the code
        /// shows. The listener accepts the code once it is there.
        var key: Data?
    }

    enum ListenerState: Equatable {
        /// Nothing to advertise: no paired iPhone and no pairing code.
        case off
        case starting
        case advertising(port: UInt16)
        case failed(String)
    }

    let pairing: PairingStore
    let name: String
    let isDemo: Bool
    /// Advertise over Bonjour (off in the loopback checks: `-syncPort`, and the unit tests).
    let advertises: Bool
    private(set) var listenerState: ListenerState = .off
    private(set) var pairingWindow: PairingWindow?
    /// A line about the last pairing ("Paired with iPhone.", "The code expired…").
    private(set) var pairingMessage: String?
    /// Paired iPhones with a sync session open right now.
    private(set) var connectedDeviceIDs: Set<String> = []

    /// Called on the main actor for each sync event, for logs and the `-syncDemo` driver.
    @ObservationIgnored var onApplied: ([SyncRecord], PairedDevice) -> Void = { _, _ in }
    /// The Apple Watch remote, relayed by a paired iPhone: applies a command to the Mac's prompter and returns the fresh
    /// status (the app's `MacRemoteControl`). nil: the answer is always "not presenting".
    @ObservationIgnored var remoteHandler: ((RemoteCommand) -> PrompterStatus)?
    /// The Mac's prompter status right now, for an iPhone that just asked for updates. nil: "not presenting".
    @ObservationIgnored var presenterStatusProvider: (() -> PrompterStatus)?

    @ObservationIgnored private let library: any SyncLibrary
    @ObservationIgnored private let port: NWEndpoint.Port
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var peers: [ObjectIdentifier: Peer] = [:]
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var pairingKeyTask: Task<Void, Never>?
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var listenerKeys: [SyncTransport.PresharedKey] = []
    /// The port the first listener got: rebuilt listeners keep it, so an iPhone that knows it can come straight back.
    @ObservationIgnored private var boundPort: NWEndpoint.Port?
    @ObservationIgnored private var quickRetries = 0
    @ObservationIgnored private let handshakeTimeout: Duration
    @ObservationIgnored private let tlsHandshakeTimeout: Duration
    /// Counts connections in the order they arrived, so the oldest waiting one is known.
    @ObservationIgnored private var acceptedCount = 0

    /// How long local changes are gathered before they go out (typing sends about three times a second).
    static let pushDelay: Duration = .milliseconds(300)
    /// A connection that hasn't said who it is (or asked to pair) within this time is closed.
    static let defaultHandshakeTimeout: Duration = .seconds(10)
    /// A connection that hasn't finished its TLS handshake within this time is closed. (An iPhone on the same network
    /// finishes it in milliseconds; a connection that never starts TLS only holds a place.)
    static let defaultTLSHandshakeTimeout: Duration = .seconds(3)
    /// Connections still waiting (in their TLS handshake, or not yet identified), at most. A new one past the limit closes
    /// the oldest waiting one, so connections that just sit there can't lock an iPhone out.
    static let maximumPendingConnections = 4
    /// Waiting connections from one address, at most: a new one from that address closes its own oldest. One device
    /// opening connections can't take the places of others.
    static let maximumPendingPerAddress = 2

    /// Connections still waiting (see `maximumPendingConnections`), for tests.
    var pendingConnectionCount: Int { peers.values.filter { $0.session == nil }.count }

    private final class Peer {
        let connection: SyncConnection
        /// The remote address ("192.168.1.20", "fe80::1%en0"), for `maximumPendingPerAddress`.
        let address: String
        /// When it arrived, in `acceptedCount` order.
        let order: Int
        var session: SyncSession?
        var deviceID: String?
        /// The iPhone asked for presenter statuses (`remoteSubscribe`).
        var wantsPresenterStatus = false
        /// The last presenter status sent to it, so a push goes out only when what the watch shows changed.
        var lastPresenterStatus: PrompterStatus?
        /// Closes the connection if it doesn't identify itself in time.
        var handshakeTimer: Task<Void, Never>?
        /// Closes the connection if its TLS handshake doesn't finish in time.
        var tlsTimer: Task<Void, Never>?
        init(connection: SyncConnection, address: String, order: Int) {
            self.connection = connection
            self.address = address
            self.order = order
        }
    }

    init(
        library: any SyncLibrary,
        pairing: PairingStore,
        name: String,
        isDemo: Bool = false,
        port: NWEndpoint.Port = .any,
        advertises: Bool = true,
        handshakeTimeout: Duration = SyncHost.defaultHandshakeTimeout,
        tlsHandshakeTimeout: Duration = SyncHost.defaultTLSHandshakeTimeout,
        now: @escaping () -> Date = { .now }
    ) {
        self.handshakeTimeout = handshakeTimeout
        self.tlsHandshakeTimeout = tlsHandshakeTimeout
        self.library = library
        self.pairing = pairing
        self.name = name
        self.isDemo = isDemo
        self.advertises = advertises
        self.port = port
        self.now = now
    }

    var hello: SyncHello {
        SyncHello(deviceID: pairing.deviceID, name: name, platform: .mac, protocolVersion: SyncHello.currentProtocolVersion)
    }

    func isConnected(_ deviceID: String) -> Bool {
        connectedDeviceIDs.contains(deviceID)
    }

    // MARK: Remote (Apple Watch through the iPhone)

    /// A paired iPhone with a session open asked for presenter statuses.
    var hasPresenterSubscribers: Bool {
        peers.values.contains { $0.session != nil && $0.wantsPresenterStatus }
    }

    /// Sends `status` to every iPhone that asked for presenter statuses, unless what its watch shows wouldn't change
    /// (`LivePushGate.showsDifferently`: state, title, speed, whole seconds left, progress by half a percent…). Call it as
    /// often as you like; while nothing moves nothing goes out.
    func publishPresenterStatus(_ status: PrompterStatus) {
        for peer in peers.values where peer.session != nil && peer.wantsPresenterStatus {
            if let last = peer.lastPresenterStatus, !LivePushGate.showsDifferently(status, from: last) { continue }
            sendPresenterStatus(status, replyTo: nil, to: peer)
        }
    }

    /// The status when no one handles remote commands: nothing presenting.
    private var notPresentingStatus: PrompterStatus {
        var status = PrompterStatus.noPrompter
        status.deviceName = name
        return status
    }

    private func sendPresenterStatus(_ status: PrompterStatus, replyTo: Int?, to peer: Peer) {
        peer.lastPresenterStatus = status
        peer.connection.send(.presenterStatus(status, replyTo: replyTo))
    }

    // MARK: Running

    func start() {
        isStarted = true
        updateListener()
    }

    func stop() {
        isStarted = false
        pushTask?.cancel()
        // Cleared too, or `libraryChanged()` would think a push is still on its way and never push again after `start()`.
        pushTask = nil
        expiryTask?.cancel()
        pairingKeyTask?.cancel()
        restartTask?.cancel()
        listener?.cancel()
        listener = nil
        listenerKeys = []
        listenerState = .off
        let closing = peers.values
        peers = [:]
        for peer in closing {
            peer.handshakeTimer?.cancel()
            peer.tlsTimer?.cancel()
            peer.connection.cancel()
        }
        connectedDeviceIDs = []
    }

    /// The library changed on this Mac: push it to every connected iPhone, gathering changes for `pushDelay`.
    func libraryChanged() {
        guard pushTask == nil else { return }
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.pushDelay)
            guard let self, !Task.isCancelled else { return }
            self.pushTask = nil
            for peer in self.peers.values { peer.session?.pushChanges() }
        }
    }

    // MARK: Pairing

    /// Shows a new 12-digit code for `SyncPairing.codeLifetime`; the listener starts accepting it once its key is ready
    /// (`pairingWindow?.key`, a fraction of a second later).
    @discardableResult
    func beginPairing(code: String = SyncPairing.makeCode()) -> String {
        pairingWindow = PairingWindow(code: code, expiresAt: now().addingTimeInterval(SyncPairing.codeLifetime))
        pairingMessage = nil
        scheduleExpiry()
        derivePairingKey(for: code)
        updateListener()
        return code
    }

    /// A debug pairing code (`-syncPairingCode`, only with `-demoData`): stays open after an iPhone pairs, so checks can
    /// pair again, but like any code it expires after `SyncPairing.codeLifetime` and closes after too many wrong tries.
    func openStandingPairing(code: String) {
        pairingWindow = PairingWindow(
            code: code, expiresAt: now().addingTimeInterval(SyncPairing.codeLifetime), staysOpenAfterPairing: true
        )
        pairingMessage = nil
        scheduleExpiry()
        derivePairingKey(for: code)
        updateListener()
    }

    /// Stretches the code's key off the main thread, then lets the listener accept it (if the same code still shows).
    private func derivePairingKey(for code: String) {
        pairingKeyTask?.cancel()
        pairingKeyTask = Task { [weak self] in
            let key = await SyncPairing.derivePairingKey(code: code)
            guard let self, !Task.isCancelled, self.pairingWindow?.code == code else { return }
            self.pairingWindow?.key = key
            self.updateListener()
        }
    }

    func cancelPairing(message: String? = nil) {
        expiryTask?.cancel()
        pairingKeyTask?.cancel()
        pairingWindow = nil
        pairingMessage = message
        updateListener()
    }

    /// The person has seen `pairingMessage` (the UI clears it after a while, and when its tab closes).
    func clearPairingMessage() {
        pairingMessage = nil
    }

    /// Unpairs an iPhone: its key is dropped (so it can't connect again) and an open session with it is closed.
    func forget(deviceID: String) {
        pairing.remove(deviceID: deviceID)
        for peer in peers.values where peer.deviceID == deviceID { peer.connection.cancel() }
        updateListener()
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let expiresAt = pairingWindow?.expiresAt else { return }
        let delay = max(0, expiresAt.timeIntervalSince(now()))
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.cancelPairing(message: "The code expired. Click Pair an iPhone to get a new one.")
        }
    }

    // MARK: Listener

    private var currentKeys: [SyncTransport.PresharedKey] {
        var keys = pairing.devices.map { SyncTransport.PresharedKey(identity: $0.deviceID, key: $0.key) }
        if let key = pairingWindow?.key {
            keys.append(SyncTransport.PresharedKey(identity: SyncPairing.pairingIdentity, key: key))
        }
        return keys
    }

    /// (Re)builds the listener when its keys changed; stops it when nobody could connect.
    private func updateListener() {
        guard isStarted else { return }
        let keys = currentKeys
        if keys == listenerKeys, listener != nil { return }
        listener?.cancel()
        listener = nil
        listenerKeys = keys
        guard !keys.isEmpty else {
            listenerState = .off
            return
        }
        do {
            let parameters = SyncTransport.parameters(keys: keys)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: port == .any ? (boundPort ?? .any) : port)
            if advertises {
                let advert = advertisement
                listener.service = NWListener.Service(
                    name: advert.serviceName, type: SyncPairing.serviceType, domain: nil, txtRecord: advert.txtRecord
                )
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                MainActor.assumeIsolated {
                    guard let self, let listener, listener === self.listener else { return }
                    self.listenerStateChanged(state, port: listener.port)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated {
                    guard let self else {
                        connection.cancel()
                        return
                    }
                    self.accept(connection)
                }
            }
            listenerState = .starting
            self.listener = listener
            listener.start(queue: .main)
        } catch {
            listenerState = .failed(error.localizedDescription)
            syncLog.error("listener failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The Bonjour service name used while no pairing code is showing: says what it is, not whose Mac it is. The first
    /// characters of the random id (in the TXT record anyway) keep two Macs on one network apart.
    var neutralServiceName: String { "Prompter \(pairing.deviceID.prefix(4))" }
    /// What the Mac advertises over Bonjour (Wi-Fi and peer-to-peer). The Mac's name goes out only while a pairing code
    /// is showing, when the person needs to pick it on the iPhone; the rest of the time the service is called
    /// `neutralServiceName` and carries just the random id a paired iPhone looks for.
    var advertisement: (serviceName: String, txtRecord: NWTXTRecord) {
        let isShowingCode = pairingWindow?.key != nil
        var txt = NWTXTRecord()
        txt["id"] = pairing.deviceID
        if isShowingCode {
            txt["name"] = name
            txt[SyncPairing.isShowingCodeKey] = "1"
        }
        txt["v"] = String(SyncHello.currentProtocolVersion)
        txt[SyncPairing.pairingVersionKey] = String(SyncPairing.pairingVersion)
        if isDemo { txt["demo"] = "1" }
        return (isShowingCode ? name : neutralServiceName, txt)
    }

    private func listenerStateChanged(_ state: NWListener.State, port: NWEndpoint.Port?) {
        switch state {
        case .ready:
            quickRetries = 0
            if boundPort == nil { boundPort = port }
            listenerState = .advertising(port: port?.rawValue ?? 0)
            syncLog.notice("listening on port \(port?.rawValue ?? 0)\(self.advertises ? ", advertising \(SyncPairing.serviceType)" : ", not advertising", privacy: .public)")
        case .failed(let error), .waiting(let error):
            listenerState = .failed(error.localizedDescription)
            syncLog.error("listener: \(error.localizedDescription, privacy: .public)")
            // Try again shortly (the network may come back, or the port free up). A listener rebuilt on its old port
            // usually finds it still held for a moment by the one just cancelled: that retries almost at once.
            listener?.cancel()
            listener = nil
            restartTask?.cancel()
            let portBusy = error == .posix(.EADDRINUSE) && quickRetries < 20
            quickRetries = portBusy ? quickRetries + 1 : 0
            restartTask = Task { [weak self] in
                try? await Task.sleep(for: portBusy ? .milliseconds(50) : .seconds(2))
                guard let self, !Task.isCancelled else { return }
                self.listenerKeys = []
                self.updateListener()
            }
        default:
            break
        }
    }

    // MARK: Connections

    /// The address part of a connection's remote endpoint.
    nonisolated static func address(of endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint { return "\(host)" }
        return "\(endpoint)"
    }

    private func accept(_ nwConnection: NWConnection) {
        // The handler gets connections before their TLS handshake, so anyone on the network can open some and say
        // nothing. Only a few may wait at a time, and only two per address; past either limit the oldest waiting one
        // goes, so connections that just sit there can't keep an iPhone out.
        let address = Self.address(of: nwConnection.endpoint)
        let waiting = peers.values.filter { $0.session == nil }.sorted { $0.order < $1.order }
        let fromAddress = waiting.filter { $0.address == address }
        if fromAddress.count >= Self.maximumPendingPerAddress, let oldest = fromAddress.first {
            syncLog.notice("closed the oldest waiting connection from one address to make room")
            oldest.connection.cancel()
        } else if waiting.count >= Self.maximumPendingConnections, let oldest = waiting.first {
            syncLog.notice("closed the oldest waiting connection to make room")
            oldest.connection.cancel()
        }
        acceptedCount += 1
        let connection = SyncConnection(connection: nwConnection)
        let peer = Peer(connection: connection, address: address, order: acceptedCount)
        let key = ObjectIdentifier(peer)
        peers[key] = peer
        let timeout = handshakeTimeout
        peer.handshakeTimer = Task { [weak self, weak peer] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, let peer, self.peers[key] === peer, peer.session == nil else { return }
            syncLog.notice("closed a connection that didn't identify itself in time")
            peer.connection.cancel()
        }
        let tlsTimeout = tlsHandshakeTimeout
        peer.tlsTimer = Task { [weak self, weak peer] in
            try? await Task.sleep(for: tlsTimeout)
            guard !Task.isCancelled, let self, let peer, self.peers[key] === peer, !peer.connection.isReady else { return }
            syncLog.notice("closed a connection that didn't finish its TLS handshake in time")
            peer.connection.cancel()
        }
        connection.onReady = { [weak peer] in
            peer?.tlsTimer?.cancel()
            peer?.tlsTimer = nil
        }
        connection.onMessage = { [weak self, weak peer] message in
            guard let self, let peer else { return }
            self.receive(message, from: peer)
        }
        connection.onEnd = { [weak self, weak peer] ending in
            guard let self, let peer else { return }
            self.ended(peer, key: key, ending: ending)
        }
        connection.start()
    }

    private func receive(_ message: SyncMessage, from peer: Peer) {
        switch message {
        case .pairRequest(let hello):
            acceptPairing(hello, from: peer)
        case .hello(let hello):
            guard peer.session == nil else {
                peer.session?.receive(message)
                return
            }
            guard let device = pairing.device(id: hello.deviceID) else {
                // Only reachable with a pairing code's key: a sync session needs the device's own key.
                syncLog.notice("refused a device that isn't paired")
                peer.connection.cancel()
                return
            }
            // TLS doesn't say which of the Mac's keys the connection used: the proof shows it was this device's own key
            // (not the pairing code's, nor another iPhone's).
            guard SyncPairing.verify(
                proof: hello.proof, key: device.key, deviceID: hello.deviceID, sessionSecret: peer.connection.exportedSecret
            ) else {
                syncLog.notice("refused a hello without a valid proof of its key")
                peer.connection.cancel()
                return
            }
            peer.handshakeTimer?.cancel()
            peer.handshakeTimer = nil
            // A new connection from the same iPhone replaces an older one that hasn't noticed it's gone.
            for other in peers.values where other !== peer && other.deviceID == hello.deviceID {
                other.connection.cancel()
            }
            peer.deviceID = hello.deviceID
            let deviceID = hello.deviceID
            let session = SyncSession(
                local: self.hello,
                library: library,
                send: { [weak connection = peer.connection] in connection?.send($0) },
                onEvent: { [weak self] event in self?.sessionEvent(event, deviceID: deviceID) }
            )
            peer.session = session
            session.start()
            session.receive(message)
            connectedDeviceIDs.insert(deviceID)
            syncLog.notice("iPhone connected: \(hello.name, privacy: .public)")
        case .unpair:
            if let deviceID = peer.deviceID {
                syncLog.notice("the iPhone forgot this Mac")
                forget(deviceID: deviceID)
            }
        case .remoteSubscribe(let wants):
            // Only a paired iPhone that has proven its key (a session is open): never the pairing connection.
            guard peer.session != nil else { return }
            peer.wantsPresenterStatus = wants
            peer.lastPresenterStatus = nil
            if wants { sendPresenterStatus(presenterStatusProvider?() ?? notPresentingStatus, replyTo: nil, to: peer) }
        case .remote(let command, let id):
            guard peer.session != nil else { return }
            let status = remoteHandler?(command) ?? notPresentingStatus
            sendPresenterStatus(status, replyTo: id, to: peer)
        case .presenterStatus:
            break   // only the Mac sends these
        default:
            peer.session?.receive(message)
        }
    }

    private func acceptPairing(_ hello: SyncHello, from peer: Peer) {
        guard let window = pairingWindow, let pairingKey = window.key, peer.session == nil,
              SyncPairing.verify(
                proof: hello.proof, key: pairingKey, deviceID: hello.deviceID, sessionSecret: peer.connection.exportedSecret
              )
        else {
            peer.connection.cancel()
            return
        }
        let device = PairedDevice(
            deviceID: hello.deviceID, name: hello.name, platform: hello.platform,
            key: SyncPairing.makeDeviceKey(), pairedAt: now(), lastSyncedAt: nil
        )
        pairing.add(device)
        peer.connection.send(.pairAccepted(self.hello, key: device.key))
        syncLog.notice("paired with \(hello.name, privacy: .public)")
        if window.staysOpenAfterPairing {
            pairingWindow?.failedAttempts = 0
            updateListener()
        } else {
            cancelPairing(message: "Paired with \(hello.name).")
        }
    }

    private func ended(_ peer: Peer, key: ObjectIdentifier, ending: SyncConnection.Ending) {
        peers[key] = nil
        peer.handshakeTimer?.cancel()
        peer.handshakeTimer = nil
        peer.tlsTimer?.cancel()
        peer.tlsTimer = nil
        if let deviceID = peer.deviceID, !peers.values.contains(where: { $0.deviceID == deviceID && $0.session != nil }) {
            connectedDeviceIDs.remove(deviceID)
            pairing.saveNow()
            syncLog.notice("iPhone disconnected")
        }
        // A handshake that failed while a code is showing, with an identity the Mac knows but the wrong key, is a wrong
        // code (or a guess): only a few are allowed. An identity the Mac doesn't know at all (`.unknownIdentity`: an
        // iPhone it forgot, still trying its old key) tried no code, so it doesn't count; otherwise a forgotten iPhone
        // retrying in the background would use up the attempts of the person pairing it again.
        if ending == .handshakeRefused, peer.deviceID == nil, var window = pairingWindow {
            window.failedAttempts += 1
            pairingWindow = window
            if window.failedAttempts >= SyncPairing.maximumFailedAttempts {
                cancelPairing(message: "Too many wrong codes. Click Pair an iPhone to try again.")
            }
        }
    }

    private func sessionEvent(_ event: SyncSession.Event, deviceID: String) {
        switch event {
        case .synced:
            pairing.markSynced(deviceID: deviceID, at: now())
        case .applied(let records):
            pairing.markSynced(deviceID: deviceID, at: now())
            // The Mac is the hub: what one iPhone (or iPad) sent goes on to the others. The sender's session already
            // knows it has these versions, so nothing goes back to it.
            for peer in peers.values where peer.deviceID != deviceID { peer.session?.pushChanges() }
            if let device = pairing.device(id: deviceID) {
                syncLog.notice("applied \(SyncSession.describe(records), privacy: .public) from \(device.name, privacy: .public) at \(Date.now.timeIntervalSince1970, format: .fixed(precision: 3), privacy: .public)")
                onApplied(records, device)
            }
        case .peerIdentified:
            break
        case .incompatible(let hello):
            syncLog.error("\(hello.name, privacy: .public) speaks a newer sync protocol")
        }
    }
}
