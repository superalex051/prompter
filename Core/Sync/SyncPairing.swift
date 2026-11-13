import CommonCrypto
import CryptoKit
import Foundation

/// Pairing: a 12-digit code shown on the Mac, typed on the iPhone once.
///
/// The code is never sent. Both sides stretch it into a 256-bit key (`pairingKey`) and use that as the TLS pre-shared key
/// of one connection, so the connection only comes up if both used the same code. Over it the Mac hands the iPhone a fresh
/// random key (`makeDeviceKey`), and from then on that key, not the code, protects every sync connection.
///
/// What protects the code:
/// - Someone who only records a pairing on the network learns nothing to test codes against: the TLS suite is ECDHE-PSK
///   (see `SyncTransport`, pinned to TLS 1.2), so the session keys also depend on an ephemeral Diffie-Hellman exchange.
/// - Someone who connects to the Mac and guesses gets one guess per connection, and the Mac closes pairing after
///   `maximumFailedAttempts` wrong ones.
/// - Someone who pretends to be the Mac (advertises a Mac of the same name, and the person taps it) does get something
///   to test codes against offline: in TLS 1.2 the iPhone sends its Finished message, keyed by the code, first (RFC 4279,
///   section 7.2). That is why the code is 12 digits and stretched with `keyStretchingRounds` of PBKDF2: trying every
///   code takes one high-end GPU years and ten of them months, while a code works for `codeLifetime` (5 minutes) and
///   only until the real iPhone pairs. The odds of finding it in time are about 1 in 376,000 for one GPU and 1 in 37,600
///   for ten (hashcat mode 10900 on an RTX 4090: 8.9 billion PBKDF2-SHA256 rounds a second). The salt is fixed (a salt
///   per Mac wouldn't help: the fake Mac chooses what it advertises), so someone could stretch every code once, about
///   3.6 GPU-years, and keep 32 TB of keys to search on each attempt; that is far beyond what these scripts are worth.
///   Handing the key over without a typed code (iCloud, a QR code) is the way past this.
///
/// Version 1 apps used 6-digit codes and the PSK identity "pair". This version advertises `pairingVersion` in the Mac's
/// Bonjour record and offers the identity `pairingIdentity`, so an old app and a new one never mistake each other's
/// attempts for a wrong code.
enum SyncPairing {
    /// Bonjour service type the Mac advertises (also listed under `NSBonjourServices` in both Info.plists).
    static let serviceType = "_prompter-sync._tcp"
    /// TLS PSK identity of a pairing connection. Sync connections use the iPhone's device id.
    static let pairingIdentity = "pair-v2"
    /// The pairing scheme this app speaks, in the Mac's Bonjour TXT record as `pairingVersionKey`. Macs from before it
    /// (6-digit codes) advertise none.
    static let pairingVersion = 2
    static let pairingVersionKey = "pv"
    /// TXT key that is "1" while the Mac shows a pairing code. Only then does it advertise its name.
    static let isShowingCodeKey = "open"
    /// How long a code shown on the Mac stays valid.
    static let codeLifetime: TimeInterval = 5 * 60
    /// Wrong codes (failed pairing handshakes) the Mac accepts before it closes pairing.
    static let maximumFailedAttempts = 5
    static let codeLength = 12
    /// PBKDF2-HMAC-SHA256 rounds for the pairing key: about 0.1 s on an Apple silicon Mac, done once per code on each side
    /// and off the main thread.
    static let keyStretchingRounds: UInt32 = 1_000_000
    static let keyStretchingSalt = Data("Prompter pairing salt v2".utf8)

    /// A random 12-digit code ("042913075266").
    static func makeCode() -> String {
        var generator = SystemRandomNumberGenerator()
        return makeCode(using: &generator)
    }

    static func makeCode<G: RandomNumberGenerator>(using generator: inout G) -> String {
        let number = Int64.random(in: 0..<1_000_000_000_000, using: &generator)
        let digits = String(number)
        return String(repeating: "0", count: codeLength - digits.count) + digits
    }

    /// The 12 digits in what someone typed ("123 456 789 012", "123-456-789-012"), or nil if it isn't exactly 12 digits.
    static func normalizedCode(_ input: String) -> String? {
        let kept = input.filter { !$0.isWhitespace && $0 != "-" }
        guard kept.count == codeLength, kept.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return kept
    }

    /// "123 456 789 012", for display: groups of three.
    static func displayCode(_ code: String) -> String {
        guard code.count == codeLength else { return code }
        var groups: [Substring] = []
        var start = code.startIndex
        while start < code.endIndex {
            let end = code.index(start, offsetBy: 3, limitedBy: code.endIndex) ?? code.endIndex
            groups.append(code[start..<end])
            start = end
        }
        return groups.joined(separator: " ")
    }

    /// The pre-shared key of a pairing connection: PBKDF2-HMAC-SHA256 of the code, `keyStretchingRounds` rounds, with a
    /// fixed salt. Slow on purpose (see above): call `derivePairingKey(code:)` from the main actor.
    static func pairingKey(code: String) -> Data {
        var key = [UInt8](repeating: 0, count: 32)
        let password = Array(code.utf8)
        let salt = Array(keyStretchingSalt)
        let status = password.withUnsafeBufferPointer { password in
            password.withMemoryRebound(to: Int8.self) { password in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password.baseAddress, password.count,
                    salt, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    keyStretchingRounds,
                    &key, key.count
                )
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed (\(status))")
        return Data(key)
    }

    /// `pairingKey(code:)` on a background thread.
    static func derivePairingKey(code: String) async -> Data {
        await Task.detached(priority: .userInitiated) { pairingKey(code: code) }.value
    }

    /// Proof that the sender of a `hello` (or `pairRequest`) holds `key`: HMAC-SHA256 over this TLS session's exported
    /// secret (`SyncConnection.exportedSecret`) and the device id it claims. TLS with pre-shared keys doesn't tell the Mac
    /// which of its keys a connection used; this does, so a connection made with the pairing code's key can't claim to
    /// be an iPhone that is already paired. Bound to the session, so it can't be replayed on another connection.
    static func proof(key: Data, deviceID: String, sessionSecret: Data) -> Data {
        var message = sessionSecret
        message.append(contentsOf: Array(deviceID.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))
        return Data(code)
    }

    /// Whether `proof` is right for `key`, `deviceID` and the session (constant-time comparison).
    static func verify(proof: Data?, key: Data, deviceID: String, sessionSecret: Data?) -> Bool {
        guard let proof, let sessionSecret else { return false }
        var message = sessionSecret
        message.append(contentsOf: Array(deviceID.utf8))
        return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: message, using: SymmetricKey(data: key))
    }

    /// A fresh 256-bit key for one paired iPhone.
    static func makeDeviceKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
}
