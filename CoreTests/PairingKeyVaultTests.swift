import Foundation
import Security
import Testing
#if os(macOS)
@testable import PrompterMac
#else
@testable import Prompter
#endif

/// A vault in memory, which a test can lock, unlock or switch off.
final class MemoryPairingKeyVault: PairingKeyVault, @unchecked Sendable {
    enum Mode { case working, locked, unavailable }
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var currentMode: Mode = .working

    var mode: Mode {
        get { lock.withLock { currentMode } }
        set { lock.withLock { currentMode = newValue } }
    }

    var accounts: Set<String> { lock.withLock { Set(items.keys) } }

    func read(account: String) -> PairingKeyVaultRead {
        lock.withLock {
            switch currentMode {
            case .locked: return .locked
            case .unavailable: return .unavailable
            case .working: return items[account].map(PairingKeyVaultRead.found) ?? .notFound
            }
        }
    }

    func write(_ key: Data, account: String) -> Bool {
        lock.withLock {
            guard currentMode == .working else { return false }
            items[account] = key
            return true
        }
    }

    func delete(account: String) {
        lock.withLock { _ = items.removeValue(forKey: account) }
    }
}

@MainActor
struct PairingKeyVaultTests {
    let directory: URL

    init() throws {
        directory = try makeSyncTestDirectory()
    }

    private func device(_ id: String = UUID().uuidString, name: String = "iPhone") -> PairedDevice {
        PairedDevice(
            deviceID: id, name: name, platform: .iPhone, key: SyncPairing.makeDeviceKey(),
            pairedAt: Date(timeIntervalSince1970: 1_800_000_000), lastSyncedAt: nil
        )
    }

    private var fileText: String {
        (try? String(contentsOf: directory.appending(path: "sync.json"), encoding: .utf8)) ?? ""
    }

    /// The keys `sync.json` holds, by device id (a device whose key isn't in the file is left out).
    private var keysInFile: [String: Data] {
        guard let data = try? Data(contentsOf: directory.appending(path: "sync.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [[String: Any]] else { return [:] }
        var keys: [String: Data] = [:]
        for device in devices {
            if let id = device["deviceID"] as? String, let key = (device["key"] as? String).flatMap({ Data(base64Encoded: $0) }) {
                keys[id] = key
            }
        }
        return keys
    }

    /// The device ids `sync.json` lists.
    private var devicesInFile: Set<String> {
        guard let data = try? Data(contentsOf: directory.appending(path: "sync.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [[String: Any]] else { return [] }
        return Set(devices.compactMap { $0["deviceID"] as? String })
    }

    @Test func withoutAVaultTheKeysStayInTheFile() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PairingStore(directory: directory)
        let paired = device()
        store.add(paired)
        #expect(store.keysInVault.isEmpty)
        #expect(keysInFile == [paired.deviceID: paired.key])
        let reopened = PairingStore(directory: directory)
        #expect(reopened.devices == [paired])
        #expect(!reopened.pairingDataWasReset)
    }

    @Test func keysFromAnOlderFileMoveIntoTheVaultWithoutUnpairingAnyone() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        // Paired by a version that kept the keys in the file.
        let old = PairingStore(directory: directory)
        let first = device(name: "iPhone")
        let second = device(name: "iPad")
        old.add(first)
        old.add(second)
        let identity = old.deviceID
        #expect(keysInFile == [first.deviceID: first.key, second.deviceID: second.key])

        // This version, with a vault: same pairings, same identity, keys out of the file.
        let vault = MemoryPairingKeyVault()
        let store = PairingStore(directory: directory, keyVault: vault)
        #expect(store.devices == [first, second])
        #expect(store.deviceID == identity)
        #expect(!store.pairingDataWasReset)
        #expect(store.keysInVault == [first.deviceID, second.deviceID])
        #expect(vault.read(account: first.deviceID) == .found(first.key))
        #expect(keysInFile.isEmpty, "no key left in the file")
        #expect(devicesInFile == [first.deviceID, second.deviceID], "the rest of the pairings stays in the file")

        // And it reads back from the vault next time.
        let again = PairingStore(directory: directory, keyVault: vault)
        #expect(again.devices == [first, second])
        #expect(again.deviceID == identity)
    }

    @Test func newPairingsGoStraightIntoTheVault() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = MemoryPairingKeyVault()
        let store = PairingStore(directory: directory, keyVault: vault)
        let paired = device()
        store.add(paired)
        #expect(vault.accounts == [paired.deviceID])
        #expect(keysInFile.isEmpty)
        #expect(devicesInFile == [paired.deviceID])
        #expect(PairingStore(directory: directory, keyVault: vault).devices == [paired])
    }

    @Test func forgettingADeviceDeletesItsKey() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = MemoryPairingKeyVault()
        let store = PairingStore(directory: directory, keyVault: vault)
        let mac = device(name: "Mac")
        store.add(mac)
        let other = device(name: "Other Mac")
        store.add(other, replacingAll: true)
        #expect(vault.accounts == [other.deviceID], "the iPhone's one Mac replaced, its key with it")
        store.remove(deviceID: other.deviceID)
        #expect(vault.accounts.isEmpty)
        #expect(store.devices.isEmpty)
    }

    @Test func keysThatArentOnThisDeviceDropThePairingAndTheOldIdentity() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = PairingStore(directory: directory, keyVault: MemoryPairingKeyVault())
        original.add(device())
        let identity = original.deviceID

        // The same file on another device (a restored backup): its vault has none of the keys.
        let restored = PairingStore(directory: directory, keyVault: MemoryPairingKeyVault())
        #expect(restored.devices.isEmpty)
        #expect(restored.pairingDataWasReset)
        #expect(restored.deviceID != identity, "not mistaken for the device the file came from")
        #expect(restored.isLoaded)
        // Settled: the next launch has nothing to report.
        #expect(!PairingStore(directory: directory, keyVault: MemoryPairingKeyVault()).pairingDataWasReset)
    }

    @Test func aLockedVaultWaitsInsteadOfDroppingAnything() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = MemoryPairingKeyVault()
        let original = PairingStore(directory: directory, keyVault: vault)
        let paired = device()
        original.add(paired)
        let before = fileText

        // Before the first unlock after a restart.
        vault.mode = .locked
        let store = PairingStore(directory: directory, keyVault: vault)
        #expect(!store.isLoaded)
        #expect(store.devices.isEmpty)
        #expect(!store.pairingDataWasReset)
        #expect(fileText == before, "nothing written while it can't read")

        vault.mode = .working
        store.reloadIfNeeded()
        #expect(store.isLoaded)
        #expect(store.devices == [paired])
        #expect(store.deviceID == original.deviceID)
    }

    @Test func keychainStatusesMeanWhatTheVaultSays() {
        let key = Data([1, 2, 3])
        #expect(KeychainPairingKeyVault.readResult(status: errSecSuccess, data: key) == .found(key))
        #expect(KeychainPairingKeyVault.readResult(status: errSecItemNotFound, data: nil) == .notFound)
        #expect(KeychainPairingKeyVault.readResult(status: errSecMissingEntitlement, data: nil) == .unavailable)
        #expect(KeychainPairingKeyVault.readResult(status: errSecInteractionNotAllowed, data: nil) == .locked)
        #expect(KeychainPairingKeyVault.readResult(status: errSecIO, data: nil) == .locked, "a passing error never drops a pairing")
    }

    /// The real Keychain, under a throwaway service name. An ad hoc signed test host can't reach it (the vault then says
    /// so, and the keys stay in the file); a signed one round-trips.
    @Test func theRealKeychainRoundTripsOrSaysItIsUnavailable() {
        let vault = KeychainPairingKeyVault(service: "PrompterTests-\(UUID().uuidString)")
        let account = UUID().uuidString
        let key = SyncPairing.makeDeviceKey()
        defer { vault.delete(account: account) }
        if vault.write(key, account: account) {
            print("PairingKeyVaultTests: this test host can use the Keychain")
            #expect(vault.read(account: account) == .found(key))
            vault.delete(account: account)
            #expect(vault.read(account: account) == .notFound)
        } else {
            print("PairingKeyVaultTests: no Keychain in this test host (\(vault.read(account: account))); keys stay in the file")
            #expect(vault.read(account: account) != .found(key))
        }
    }
}
