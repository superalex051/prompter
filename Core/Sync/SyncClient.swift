import Foundation
import Network
import Observation

/// The iPhone's side of sync: while the app is in the foreground it browses Bonjour for Macs running Prompter, connects
/// to the one it is paired with, and keeps a `SyncSession` going; in the background it disconnects. It also does the
/// one-off pairing with a Mac's 12-digit code.
@MainActor @Observable
final class SyncClient {
    /// A Mac running Prompter on the network (or nearby over peer-to-peer Wi-Fi).
    struct FoundMac: Identifiable, Equatable {
        var id: String
        var name: String
        var endpoint: NWEndpoint
        /// The pairing scheme the Mac speaks (`SyncPairing.pairingVersion`); nil for a Mac from before 12-digit codes.
        var pairingVersion: Int? = SyncPairing.pairingVersion
        /// The Mac shows a pairing code right now. (Macs from before 12-digit codes don't say; they count as showing
        /// one, so they appear in the list and say they need an update.)
        var isShowingCode = true
    }

    enum Status: Equatable {
        case notPaired
        /// In the background: nothing runs.
        case paused
        case searching
        /// Searched for a while and the paired Mac isn't there.
        case notFound
        case connecting
        case connected
        /// The Mac refused this iPhone's key: it was forgotten on the Mac. Nothing retries on its own from here (not even
        /// when the Mac shows up again): pairing again, or Sync now, tries again.
        case refused
        /// The Mac's app is newer than this one.
        case incompatible
        /// Local network access is off for Prompter.
        case noPermission
    }

    enum PairingState: Equatable {
        case idle
        case pairing(macName: String)
        case failed(String)
        case paired(macName: String)
    }

    let pairing: PairingStore
    let name: String
    let platform: SyncHello.Platform
    let isDemo: Bool
    /// Every Mac running Prompter nearby, including ones that show no pairing code (a paired Mac is found among these).
    private(set) var foundMacs: [FoundMac] = []
    /// The Macs to offer for pairing: those showing a code. A Mac shows its name only then.
    var pairableMacs: [FoundMac] { foundMacs.filter(\.isShowingCode) }
    private(set) var status: Status
    private(set) var pairingState: PairingState = .idle
    private(set) var isActive = false
    /// What the paired Mac's prompter is doing, while connected (the Mac pushes it as it changes; `hasPrompter` false
    /// while it isn't presenting). nil when not connected, or before the Mac has said.
    private(set) var presenterStatus: PrompterStatus?

    /// Debug: connect here instead of looking the Mac up with Bonjour (`-syncHost 127.0.0.1:50123`).
    @ObservationIgnored var directEndpoint: NWEndpoint?
    /// Debug: pair with the first Mac found, with this code, without any UI (`-syncPairingCode 123456789012`).
    @ObservationIgnored var autoPairCode: String?
    /// Called on the main actor when records from the Mac changed the library, and when a session starts.
    @ObservationIgnored var onApplied: ([SyncRecord]) -> Void = { _ in }
    @ObservationIgnored var onConnected: () -> Void = {}
    /// Called on the main actor whenever `presenterStatus` changes (also to nil on disconnecting): the remote hub relays
    /// it to the Apple Watch.
    @ObservationIgnored var onPresenterStatusChange: () -> Void = {}
    /// Ask the Mac for its presenter status on every connection (the Apple Watch remote for the Mac).
    @ObservationIgnored var subscribesToPresenter = true

    @ObservationIgnored private let library: any SyncLibrary
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var connection: SyncConnection?
    @ObservationIgnored private var session: SyncSession?
    @ObservationIgnored private var pairingConnection: SyncConnection?
    /// Stretching the typed code's key (`SyncPairing.derivePairingKey`) before the pairing connection starts.
    @ObservationIgnored private var pairingKeyTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var notFoundTask: Task<Void, Never>?
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var failedConnects = 0
    @ObservationIgnored private var refusals = 0
    /// The Mac refused this iPhone's key twice in a row: stay away until the person pairs again or taps Sync now.
    @ObservationIgnored private var isRefused = false
    @ObservationIgnored private var isDiscovering = false
    /// Sync connections started so far (pairing ones not included), for tests.
    @ObservationIgnored private(set) var connectionAttempts = 0
    /// Remote commands sent to the Mac and waiting for its answer, by id.
    @ObservationIgnored private var remoteWaiters: [Int: RemoteWaiter] = [:]
    @ObservationIgnored private var nextRemoteID = 1

    private struct RemoteWaiter {
        var reply: (PrompterStatus?) -> Void
        var timeout: Task<Void, Never>
    }

    /// How long a remote command waits for the Mac's answer before it gives up (and answers nil).
    static let remoteReplyTimeout: Duration = .milliseconds(1500)

    /// Back-off between reconnect attempts: 1, 2, 4, 8, 16, then every 30 seconds.
    nonisolated static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        min(30, pow(2, Double(max(0, failures - 1))))
    }

    /// How long "Looking for your Mac" shows before it turns into "Mac not found".
    static let searchPatience: Duration = .seconds(6)

    init(
        library: any SyncLibrary,
        pairing: PairingStore,
        name: String,
        platform: SyncHello.Platform = .iPhone,
        isDemo: Bool = false,
        now: @escaping () -> Date = { .now }
    ) {
        self.library = library
        self.pairing = pairing
        self.name = name
        self.platform = platform
        self.isDemo = isDemo
        self.now = now
        status = pairing.devices.isEmpty ? .notPaired : .paused
    }

    var pairedMac: PairedDevice? { pairing.devices.first }

    var hello: SyncHello {
        SyncHello(deviceID: pairing.deviceID, name: name, platform: platform, protocolVersion: SyncHello.currentProtocolVersion)
    }

    // MARK: Foreground and background

    /// The app came to the foreground (true) or left it (false). In the background everything stops cleanly; coming back
    /// reconnects and catches up.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            pairing.reloadIfNeeded()
            if !pairing.isLoaded { return }
            failedConnects = 0
            updateBrowsing()
            if directEndpoint != nil { autoPairIfNeeded() }
            connectIfNeeded()
        } else {
            stopEverything()
            status = pairedMac == nil ? .notPaired : .paused
        }
    }

    /// The library changed here: push it to the Mac, gathering changes for `SyncHost.pushDelay`.
    func libraryChanged() {
        guard pushTask == nil else { return }
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: SyncHost.pushDelay)
            guard let self, !Task.isCancelled else { return }
            self.pushTask = nil
            self.session?.pushChanges()
        }
    }

    /// Reconnects now (a fresh comparison of the two libraries).
    func syncNow() {
        guard isActive, pairedMac != nil else { return }
        disconnect()
        failedConnects = 0
        refusals = 0
        isRefused = false
        retryTask?.cancel()
        connectIfNeeded()
    }

    // MARK: Remote (the Mac's prompter)

    /// Sends a remote command to the Mac's prompter. `reply` runs once, on the main actor: with the Mac's status after
    /// the command, or nil when not connected or no answer came within `remoteReplyTimeout`.
    func sendRemote(_ command: RemoteCommand, reply: @escaping (PrompterStatus?) -> Void) {
        guard status == .connected, let connection, session != nil else {
            reply(nil)
            return
        }
        let id = nextRemoteID
        nextRemoteID += 1
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.remoteReplyTimeout)
            guard !Task.isCancelled, let self else { return }
            syncLog.notice("remote command \(id) unanswered")
            self.endRemoteWait(id, with: nil)
        }
        remoteWaiters[id] = RemoteWaiter(reply: reply, timeout: timeout)
        connection.send(.remote(command, id: id))
    }

    private func receivePresenterStatus(_ status: PrompterStatus, replyTo: Int?) {
        if presenterStatus != status {
            presenterStatus = status
            onPresenterStatusChange()
        }
        if let replyTo { endRemoteWait(replyTo, with: status) }
    }

    private func endRemoteWait(_ id: Int, with status: PrompterStatus?) {
        guard let waiter = remoteWaiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.reply(status)
    }

    /// The connection is gone: no presenter status, and every command waiting for an answer gets nil.
    private func resetRemote() {
        let waiting = remoteWaiters.keys.sorted()
        for id in waiting { endRemoteWait(id, with: nil) }
        if presenterStatus != nil {
            presenterStatus = nil
            onPresenterStatusChange()
        }
    }

    // MARK: Pairing

    /// The word for this device in messages ("iPhone" or "iPad").
    private var deviceWord: String { platform == .iPad ? "iPad" : "iPhone" }

    /// Why this device can't pair with `mac` at all, or nil: one of the two runs a Prompter from before 12-digit codes, or
    /// from after this one.
    func pairingProblem(with mac: FoundMac) -> String? {
        guard let version = mac.pairingVersion else {
            return "\(mac.name) has an older Prompter. Update Prompter on the Mac, then pair again."
        }
        if version > SyncPairing.pairingVersion {
            return "\(mac.name) has a newer Prompter. Update Prompter on this \(deviceWord), then pair again."
        }
        return nil
    }

    /// Shows why this device can't pair with `mac` (`pairingProblem(with:)`) and returns false; true when it can.
    @discardableResult
    func checkCanPair(with mac: FoundMac) -> Bool {
        guard let problem = pairingProblem(with: mac) else { return true }
        pairingState = .failed(problem)
        return false
    }

    func pair(with mac: FoundMac, code typed: String) {
        guard checkCanPair(with: mac) else { return }
        guard let code = SyncPairing.normalizedCode(typed) else {
            pairingState = .failed("Enter the \(SyncPairing.codeLength)-digit code shown on your Mac.")
            return
        }
        pair(endpoint: mac.endpoint, macName: mac.name, code: code)
    }

    /// Stretches the code's key in the background (a fraction of a second), then connects with it.
    private func pair(endpoint: NWEndpoint, macName: String, code: String) {
        pairingConnection?.cancel()
        pairingConnection = nil
        pairingKeyTask?.cancel()
        pairingState = .pairing(macName: macName)
        pairingKeyTask = Task { [weak self] in
            let key = await SyncPairing.derivePairingKey(code: code)
            guard let self, !Task.isCancelled, case .pairing = self.pairingState else { return }
            self.pairingKeyTask = nil
            self.connectToPair(endpoint: endpoint, macName: macName, key: key)
        }
    }

    private func connectToPair(endpoint: NWEndpoint, macName: String, key: Data) {
        let connection = SyncConnection(
            to: endpoint, keys: [SyncTransport.PresharedKey(identity: SyncPairing.pairingIdentity, key: key)]
        )
        pairingConnection = connection
        connection.onReady = { [weak self, weak connection] in
            guard let self, let connection else { return }
            var hello = self.hello
            if let secret = connection.exportedSecret {
                hello.proof = SyncPairing.proof(key: key, deviceID: hello.deviceID, sessionSecret: secret)
            }
            connection.send(.pairRequest(hello))
        }
        connection.onMessage = { [weak self, weak connection] message in
            guard let self, case .pairAccepted(let mac, let key) = message else { return }
            let device = PairedDevice(
                deviceID: mac.deviceID, name: mac.name, platform: mac.platform, key: key, pairedAt: self.now(),
                lastSyncedAt: nil
            )
            self.pairing.add(device, replacingAll: true)
            self.pairingState = .paired(macName: mac.name)
            syncLog.notice("paired with \(mac.name, privacy: .public)")
            connection?.cancel()
            self.disconnect()
            self.failedConnects = 0
            self.refusals = 0
            self.isRefused = false
            // The Mac rebuilds its listener with the new key; give it a moment before connecting with it.
            self.retryTask?.cancel()
            self.retryTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, !Task.isCancelled else { return }
                self.connectIfNeeded()
            }
        }
        connection.onEnd = { [weak self, weak connection] ending in
            guard let self, let connection, connection === self.pairingConnection else { return }
            self.pairingConnection = nil
            guard case .pairing = self.pairingState else { return }
            switch ending {
            case .handshakeRefused:
                self.pairingState = .failed("That code didn't work. Check the code on your Mac and try again.")
            case .unknownIdentity:
                // The Mac has no pairing key at all: no code is showing (it expired, was cancelled, or closed after too
                // many wrong ones), or it runs a Prompter from before 12-digit codes.
                self.pairingState = .failed(
                    "\(macName) isn't showing a pairing code. On the Mac, click Pair an iPhone to get a new one. If the code there has 6 digits, update Prompter on the Mac."
                )
            default:
                self.pairingState = .failed(
                    "Couldn't reach \(macName). Make sure Prompter is open on it and both are on the same Wi-Fi."
                )
            }
        }
        connection.start()
    }

    func clearPairingState() {
        if case .pairing = pairingState { return }
        pairingState = .idle
    }

    /// Unpairs: tells the Mac (if it's connected) so it forgets this iPhone too, then drops the key here.
    func forget() {
        let closing = connection
        connection = nil
        session = nil
        resetRemote()
        if let closing, closing.isReady {
            closing.sendThenClose(.unpair)
        } else {
            closing?.cancel()
        }
        retryTask?.cancel()
        notFoundTask?.cancel()
        refusals = 0
        isRefused = false
        if let mac = pairedMac { pairing.remove(deviceID: mac.deviceID) }
        pairingState = .idle
        status = .notPaired
        updateBrowsing()
    }

    // MARK: Browsing

    /// Settings → Sync with Mac is on screen (true) or not: the list of Macs nearby is needed only there.
    func setDiscovering(_ discovering: Bool) {
        isDiscovering = discovering
        updateBrowsing()
    }

    /// Bonjour runs only when it's needed: while paired (to find the Mac) or while the person is looking for a Mac to
    /// pair with. An iPhone that never uses sync never touches the local network, so it never sees the Local Network
    /// permission prompt either.
    private var wantsBrowser: Bool {
        isActive && directEndpoint == nil && (pairedMac != nil || isDiscovering || autoPairCode != nil)
    }

    private func updateBrowsing() {
        if wantsBrowser {
            startBrowsing()
        } else if let browser {
            browser.cancel()
            self.browser = nil
            foundMacs = []
        }
    }

    private func startBrowsing() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: SyncPairing.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.browseResultsChanged(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.browserStateChanged(state) }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    private func browserStateChanged(_ state: NWBrowser.State) {
        switch state {
        case .failed(let error), .waiting(let error):
            syncLog.error("browser: \(error.debugDescription, privacy: .public)")
            // kDNSServiceErr_PolicyDenied: the person turned Local Network off for Prompter.
            if case .dns(let code) = error, code == -65570 {
                status = .noPermission
            }
        case .ready:
            if status == .noPermission { status = pairedMac == nil ? .notPaired : .searching }
        default:
            break
        }
    }

    private func browseResultsChanged(_ results: Set<NWBrowser.Result>) {
        foundMacs = Self.merged(results.compactMap { result in
            guard case .service(let serviceName, _, _, _) = result.endpoint, case .bonjour(let txt) = result.metadata else {
                return nil
            }
            return Self.foundMac(serviceName: serviceName, txt: txt, endpoint: result.endpoint, isDemo: isDemo)
        })
        autoPairIfNeeded()
        if let mac = pairedMac, connection == nil, !isRefused, foundMacs.contains(where: { $0.id == mac.deviceID }) {
            // The Mac (re)appeared: no need to wait for the next retry. (Not after a refusal: the Mac advertises again
            // whenever its listener restarts, and this iPhone's key still wouldn't work.)
            retryTask?.cancel()
            connectIfNeeded()
        }
    }

    /// A Mac from its Bonjour service, or nil when it isn't one to show: no id, or a demo Mac (`-demoData`) for a real
    /// iPhone or the other way round (so a test never meets real data).
    nonisolated static func foundMac(serviceName: String, txt: NWTXTRecord, endpoint: NWEndpoint, isDemo: Bool) -> FoundMac? {
        guard let id = txt["id"], (txt["demo"] == "1") == isDemo else { return nil }
        let pairingVersion = txt[SyncPairing.pairingVersionKey].flatMap { Int($0) }
        return FoundMac(
            id: id, name: txt["name"] ?? serviceName, endpoint: endpoint, pairingVersion: pairingVersion,
            isShowingCode: pairingVersion == nil || txt[SyncPairing.isShowingCodeKey] == "1"
        )
    }

    /// One entry per Mac, sorted by name. A Mac can show up twice for a moment (it re-registers under its own name when a
    /// code opens, and the old entry lingers): the one showing a code wins, so the Mac is never missing from the list.
    nonisolated static func merged(_ found: [FoundMac]) -> [FoundMac] {
        var macs: [String: FoundMac] = [:]
        for mac in found {
            if let kept = macs[mac.id], kept.isShowingCode || !mac.isShowingCode { continue }
            macs[mac.id] = mac
        }
        return macs.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func autoPairIfNeeded() {
        guard let code = autoPairCode, pairedMac == nil, pairingConnection == nil, pairingKeyTask == nil else { return }
        if let directEndpoint {
            pair(endpoint: directEndpoint, macName: "Mac", code: code)
        } else if let mac = pairableMacs.first {
            pair(endpoint: mac.endpoint, macName: mac.name, code: code)
        }
    }

    // MARK: Connecting

    private func connectIfNeeded() {
        guard isActive, connection == nil, let mac = pairedMac else {
            if isActive, pairedMac == nil { status = .notPaired }
            return
        }
        guard !isRefused else {
            status = .refused
            return
        }
        guard let endpoint = directEndpoint ?? foundMacs.first(where: { $0.id == mac.deviceID })?.endpoint else {
            if status != .notFound, status != .noPermission, status != .refused { beginSearching() }
            return
        }
        notFoundTask?.cancel()
        status = .connecting
        connectionAttempts += 1
        let connection = SyncConnection(
            to: endpoint, keys: [SyncTransport.PresharedKey(identity: pairing.deviceID, key: mac.key)]
        )
        self.connection = connection
        connection.onReady = { [weak self, weak connection] in
            guard let self, let connection, connection === self.connection else { return }
            self.startSession(on: connection, macID: mac.deviceID)
        }
        connection.onMessage = { [weak self, weak connection] message in
            guard let self, let connection, connection === self.connection else { return }
            if case .presenterStatus(let status, let replyTo) = message {
                self.receivePresenterStatus(status, replyTo: replyTo)
            } else {
                self.session?.receive(message)
            }
        }
        connection.onEnd = { [weak self, weak connection] ending in
            guard let self, let connection, connection === self.connection else { return }
            self.connectionEnded(ending)
        }
        connection.start()
    }

    private func beginSearching() {
        status = .searching
        notFoundTask?.cancel()
        notFoundTask = Task { [weak self] in
            try? await Task.sleep(for: Self.searchPatience)
            guard let self, !Task.isCancelled, self.status == .searching else { return }
            self.status = .notFound
        }
    }

    private func startSession(on connection: SyncConnection, macID: String) {
        var hello = self.hello
        if let mac = pairedMac, let secret = connection.exportedSecret {
            hello.proof = SyncPairing.proof(key: mac.key, deviceID: hello.deviceID, sessionSecret: secret)
        }
        let session = SyncSession(
            local: hello,
            library: library,
            send: { [weak connection] in connection?.send($0) },
            onEvent: { [weak self] event in self?.sessionEvent(event, macID: macID) }
        )
        self.session = session
        session.start()
    }

    private func sessionEvent(_ event: SyncSession.Event, macID: String) {
        switch event {
        case .peerIdentified(let mac):
            guard mac.deviceID == macID else {
                // Someone else answered with this iPhone's key: not the paired Mac.
                connection?.cancel()
                return
            }
            status = .connected
            failedConnects = 0
            refusals = 0
            syncLog.notice("connected to \(mac.name, privacy: .public)")
            if subscribesToPresenter { connection?.send(.remoteSubscribe(true)) }
            onConnected()
        case .synced:
            pairing.markSynced(deviceID: macID, at: now())
        case .applied(let records):
            pairing.markSynced(deviceID: macID, at: now())
            syncLog.notice("applied \(SyncSession.describe(records), privacy: .public) from the Mac at \(Date.now.timeIntervalSince1970, format: .fixed(precision: 3), privacy: .public)")
            onApplied(records)
        case .incompatible:
            status = .incompatible
            connection?.cancel()
        }
    }

    private func connectionEnded(_ ending: SyncConnection.Ending) {
        let wasConnected = status == .connected
        connection = nil
        session = nil
        resetRemote()
        pairing.saveNow()
        guard isActive, pairedMac != nil else { return }
        if status == .incompatible { return }
        failedConnects += 1
        refusals = ending.isRefusal ? refusals + 1 : 0
        if refusals >= 2 {
            // Twice in a row, so not a listener that happened to be restarting: the Mac doesn't know this key any more.
            // Stop here: retrying can't help, and it would only keep knocking on the Mac.
            status = .refused
            isRefused = true
            retryTask?.cancel()
            syncLog.notice("the Mac refused this iPhone's key; not retrying until it pairs again")
            return
        } else if wasConnected || status == .connecting {
            status = .searching
        }
        syncLog.notice("disconnected (\(String(describing: ending), privacy: .public)), retrying")
        scheduleRetry()
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        let delay = Self.retryDelay(afterFailures: failedConnects)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.connectIfNeeded()
        }
    }

    /// Closes the sync connection without treating it as a failure (no retry is scheduled).
    private func disconnect() {
        let closing = connection
        connection = nil
        session = nil
        closing?.cancel()
        resetRemote()
    }

    private func stopEverything() {
        disconnect()
        pairingConnection?.cancel()
        pairingConnection = nil
        pairingKeyTask?.cancel()
        pairingKeyTask = nil
        if case .pairing = pairingState { pairingState = .idle }
        browser?.cancel()
        browser = nil
        foundMacs = []
        retryTask?.cancel()
        notFoundTask?.cancel()
        pushTask?.cancel()
        pushTask = nil
    }
}
