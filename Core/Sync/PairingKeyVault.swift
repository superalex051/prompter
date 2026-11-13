import Foundation
import Security

/// Where the keys of paired devices are kept, apart from `sync.json`.
protocol PairingKeyVault: Sendable {
    func read(account: String) -> PairingKeyVaultRead
    /// True once the key is stored and reads back the same.
    func write(_ key: Data, account: String) -> Bool
    func delete(account: String)
}

enum PairingKeyVaultRead: Equatable, Sendable {
    case found(Data)
    /// Nothing stored for that account (for instance a pairing file restored from a backup onto another device: the
    /// keys stay on the device they were made on).
    case notFound
    /// Can't be read right now (before the first unlock after a restart, or a passing error): try again later.
    case locked
    /// This build can't use the vault at all (an ad hoc signed build has no keychain access group).
    case unavailable
}

/// The Keychain, for builds signed with a team (App Store, TestFlight, Xcode device builds). Items are readable after
/// the first unlock and never leave this device: not in backups, not on a new device set up from one.
///
/// On the Mac it uses the data protection keychain, which an ad hoc signed build ("Sign to Run Locally") can't reach
/// (`errSecMissingEntitlement`): there `PairingStore` keeps the keys in its file, as before.
struct KeychainPairingKeyVault: PairingKeyVault {
    let service: String

    init(service: String = (Bundle.main.bundleIdentifier ?? "Prompter") + ".sync-keys") {
        self.service = service
    }

    private func baseQuery(account: String) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain] = true
        #endif
        return query
    }

    func read(account: String) -> PairingKeyVaultRead {
        var query = baseQuery(account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return Self.readResult(status: status, data: result as? Data)
    }

    /// What a `SecItemCopyMatching` status means for `read`.
    static func readResult(status: OSStatus, data: Data?) -> PairingKeyVaultRead {
        switch status {
        case errSecSuccess: data.map(PairingKeyVaultRead.found) ?? .notFound
        case errSecItemNotFound: .notFound
        case errSecMissingEntitlement: .unavailable
        // Anything else may pass (the device still locked, a busy keychain): wait rather than drop a pairing.
        default: .locked
        }
    }

    func write(_ key: Data, account: String) -> Bool {
        let query = baseQuery(account: account)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: key] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = key
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecAttrLabel] = "Prompter sync pairing"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            if status != errSecMissingEntitlement {
                syncLog.error("could not keep a pairing key in the Keychain (\(status))")
            }
            return false
        }
        return read(account: account) == .found(key)
    }

    func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}

/// No vault: the keys stay in the pairing file (throwaway demo libraries, tests, previews).
struct FilePairingKeyVault: PairingKeyVault {
    func read(account: String) -> PairingKeyVaultRead { .unavailable }
    func write(_ key: Data, account: String) -> Bool { false }
    func delete(account: String) {}
}
