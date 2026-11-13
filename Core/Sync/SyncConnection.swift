import Foundation
import Network
import OSLog

let syncLog = Logger(subsystem: LogSubsystem.current, category: "sync")

/// Network parameters for sync: TCP + TLS with pre-shared keys.
///
/// Network.framework does pre-shared keys only in TLS 1.2 (a TLS 1.3 external PSK handshake fails; checked on macOS 26),
/// so the connection is pinned to TLS 1.2 with the one suite `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256`: the key proves
/// both sides know the secret, and the ephemeral ECDHE exchange gives forward secrecy and stops anyone who only records a
/// pairing from testing codes against it offline. Keep the pin: in TLS 1.3 the ClientHello carries a binder keyed by the
/// PSK alone, which a passive listener could test codes against. An active fake Mac can still test codes against the
/// iPhone's Finished message; `SyncPairing` explains why the code is long and stretched for that. The Mac lists every
/// paired iPhone's key (identity: the iPhone's device id) and TLS picks the one the iPhone offers; a peer with no matching
/// key fails the handshake.
enum SyncTransport {
    /// TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256 (RFC 7905). `tls_ciphersuite_t` has no name for it.
    static let cipherSuite: UInt16 = 0xCCAC

    struct PresharedKey: Equatable, Sendable {
        var identity: String
        var key: Data
    }

    static func parameters(keys: [PresharedKey]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        for psk in keys {
            sec_protocol_options_add_pre_shared_key(
                security, dispatchData(psk.key) as __DispatchData, dispatchData(Data(psk.identity.utf8)) as __DispatchData
            )
        }
        if let suite = tls_ciphersuite_t(rawValue: cipherSuite) {
            sec_protocol_options_append_tls_ciphersuite(security, suite)
        }
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(security, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // Notices a peer that vanished (Wi-Fi off, laptop lid closed) within about half a minute.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 10

        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    private static func dispatchData(_ data: Data) -> DispatchData {
        data.withUnsafeBytes { DispatchData(bytes: $0) }
    }
}

/// One TLS connection carrying framed `SyncMessage`s. Everything runs on the main queue, so the callbacks are main-actor.
@MainActor
final class SyncConnection {
    enum Ending: Equatable {
        /// `cancel()` was called here.
        case cancelled
        /// The other side closed the connection.
        case closedByPeer
        /// TLS refused the handshake: an identity both sides know, with a different key (a wrong pairing code, or a
        /// stale device key).
        case handshakeRefused
        /// TLS refused the handshake because the other side doesn't know the identity offered at all
        /// (`errSSLUnknownPSKIdentity`): on the Mac, an iPhone it forgot; on the iPhone, a Mac that forgot it. No code
        /// was tried, so the Mac doesn't count it as a wrong pairing code.
        case unknownIdentity

        /// Either kind of refused handshake.
        var isRefusal: Bool { self == .handshakeRefused || self == .unknownIdentity }
        /// Anything else: the network went away, the peer couldn't be reached, a bad frame.
        case failed(String)
    }

    let connection: NWConnection
    var onReady: () -> Void = {}
    var onMessage: (SyncMessage) -> Void = { _ in }
    /// Called once, when the connection is over for whatever reason.
    var onEnd: (Ending) -> Void = { _ in }

    private(set) var isReady = false
    /// A secret both ends of this one TLS session derive (RFC 5705 exporter), read once the connection is ready. A
    /// `hello` proves with it that the sender holds its device key (see `SyncPairing.proof`).
    private(set) var exportedSecret: Data?
    /// The TLS version the handshake settled on, read once the connection is ready (always 1.2, see `SyncTransport`).
    private(set) var negotiatedTLSVersion: tls_protocol_version_t?
    private var hasEnded = false
    private var decoder = SyncFrameDecoder()

    init(connection: NWConnection) {
        self.connection = connection
    }

    convenience init(to endpoint: NWEndpoint, keys: [SyncTransport.PresharedKey]) {
        self.init(connection: NWConnection(to: endpoint, using: SyncTransport.parameters(keys: keys)))
    }

    var endpointDescription: String { "\(connection.endpoint)" }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.handle(state) }
        }
        connection.start(queue: .main)
    }

    func send(_ message: SyncMessage) {
        guard !hasEnded else { return }
        do {
            let frame = SyncFrame.encode(try SyncMessageCoder.encode(message))
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { syncLog.error("send failed: \(error.localizedDescription, privacy: .public)") }
            })
        } catch {
            syncLog.error("could not encode a message: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Sends a last message and closes once it has gone out (`cancel()` alone can drop what is still queued).
    func sendThenClose(_ message: SyncMessage) {
        guard !hasEnded, let payload = try? SyncMessageCoder.encode(message) else {
            cancel()
            return
        }
        connection.send(content: SyncFrame.encode(payload), completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        })
    }

    /// Closes the connection; `onEnd(.cancelled)` follows.
    func cancel() {
        end(.cancelled)
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard !isReady else { return }
            isReady = true
            exportedSecret = Self.exportedSecret(of: connection)
            if let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
                negotiatedTLSVersion = sec_protocol_metadata_get_negotiated_tls_protocol_version(
                    metadata.securityProtocolMetadata
                )
            }
            receiveNext()
            onReady()
        case .waiting(let error), .failed(let error):
            // `.waiting` is the client's view of a refused handshake or an unreachable peer. Sync retries on its own
            // schedule (with the browser's help), so the connection is ended rather than left to retry by itself.
            end(ending(for: error))
        case .cancelled:
            end(.cancelled)
        default:
            break
        }
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.hasEnded else { return }
                if let data, !data.isEmpty {
                    do {
                        for payload in try self.decoder.append(data) {
                            guard !self.hasEnded else { return }
                            do {
                                self.onMessage(try SyncMessageCoder.decode(payload))
                            } catch {
                                // A message from a newer app this one doesn't know: skip it, keep the connection.
                                syncLog.notice("skipped a message it couldn't read")
                            }
                        }
                    } catch {
                        self.end(.failed("bad frame"))
                        return
                    }
                }
                if let error {
                    self.end(self.ending(for: error))
                } else if isComplete {
                    self.end(.closedByPeer)
                } else {
                    self.receiveNext()
                }
            }
        }
    }

    private func end(_ ending: Ending) {
        guard !hasEnded else { return }
        hasEnded = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onEnd(ending)
    }

    /// The label of the exporter secret (`exportedSecret`).
    static let exporterLabel = "prompter-sync hello proof v1"

    private static func exportedSecret(of connection: NWConnection) -> Data? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            return nil
        }
        let secret = exporterLabel.withCString { label in
            sec_protocol_metadata_create_secret(metadata.securityProtocolMetadata, exporterLabel.utf8.count, label, 32)
        }
        return secret.map { Data($0 as DispatchData) }
    }

    /// errSSLUnknownPSKIdentity: the other side has no key for the identity offered.
    static let unknownPSKIdentityStatus: OSStatus = -9864

    /// A TLS error before the connection was up is a refused handshake; after, it's just the connection going away.
    private func ending(for error: NWError) -> Ending {
        if !isReady, case .tls(let status) = error, status == Self.unknownPSKIdentityStatus {
            syncLog.notice("TLS handshake refused: unknown identity")
            return .unknownIdentity
        }
        if !isReady, case .tls(let status) = error {
            // errSSLBadRecordMac (-9846), errSSLPeerBadRecordMac (-9820), errSSLHandshakeFail (-9858), errSSLClosedNoNotify
            // (-9816), errSSLDecryptionFail and friends: the keys didn't match.
            syncLog.notice("TLS handshake refused (\(status))")
            return .handshakeRefused
        }
        return .failed(error.debugDescription)
    }
}
