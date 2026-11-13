import Foundation
import Observation

/// A device this one is paired with: on the Mac, each paired iPhone; on the iPhone, its Mac.
struct PairedDevice: Codable, Identifiable, Equatable, Sendable {
    var deviceID: String
    var name: String
    var platform: SyncHello.Platform
    /// The 256-bit key both sides use as the TLS pre-shared key (identity: the iPhone's device id).
    var key: Data
    var pairedAt: Date
    var lastSyncedAt: Date?

    var id: String { deviceID }
}

/// This device's sync identity and its pairings, in `sync.json` next to the library (Application Support/Prompter, or
/// the throwaway folder with `-demoData`).
///
/// The pairings' keys go in `keyVault` (the Keychain, this device only) when the build can use it, and `sync.json`
/// keeps the rest. A file from before that, with the keys in it, is moved over on load without unpairing anyone. Where
/// there is no vault (an ad hoc signed Mac build, demo libraries, tests) the keys stay in the file, which is readable
/// only by its owner (0600) and, on the iPhone, encrypted until the first unlock like the library.
///
/// A file whose keys are in nobody's vault here (restored from a backup onto another device, or moved to a new Mac)
/// pairs nothing: those pairings are dropped, this device takes a new identity so it isn't mistaken for the one the
/// file came from, and `pairingDataWasReset` asks the person to pair again.
@MainActor @Observable
final class PairingStore {
    let fileURL: URL
    @ObservationIgnored let keyVault: any PairingKeyVault
    /// Paired devices whose key is in `keyVault` (and so left out of the file).
    @ObservationIgnored private(set) var keysInVault: Set<String> = []
    /// This device's id: random, made once.
    private(set) var deviceID: String
    private(set) var devices: [PairedDevice]

    @ObservationIgnored private var lastSavedSync: [String: Date] = [:]
    /// How often a new "last synced" time is written to disk (it is always current in memory).
    static let syncTimeSaveInterval: TimeInterval = 30

    /// False while `sync.json` exists but can't be read yet (an iPhone before its first unlock after a restart): nothing
    /// is saved then, so the pairing isn't replaced, and `reloadIfNeeded()` tries again.
    private(set) var isLoaded = false

    /// `sync.json` couldn't be read (damaged), so this device started over with a new identity and no pairings, or some
    /// pairings' keys aren't on this device (see above). A damaged file was kept beside it ("sync-corrupt-<time>.json").
    /// The UI says `pairingResetMessage` until `acknowledgePairingReset()`.
    private(set) var pairingDataWasReset = false

    #if os(macOS)
    static let pairingResetMessage = "Pairing data was reset; pair your iPhone again."
    #else
    static let pairingResetMessage = "Pairing data was reset; pair with your Mac again."
    #endif

    init(directory: URL = ScriptStore.defaultDirectory, keyVault: any PairingKeyVault = FilePairingKeyVault()) {
        fileURL = directory.appending(path: "sync.json", directoryHint: .notDirectory)
        self.keyVault = keyVault
        deviceID = ""
        devices = []
        load()
    }

    /// Reads the file if an earlier attempt couldn't (sync calls this before it starts).
    func reloadIfNeeded() {
        if !isLoaded { load() }
    }

    private func load() {
        if FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            guard let data = try? Data(contentsOf: fileURL) else { return }
            if let file = try? Self.decoder().decode(File.self, from: data) {
                load(file)
                return
            }
            // Unreadable contents: keep a copy of it, start over (the pairings are lost; pairing again fixes it), and
            // say so rather than quietly becoming a device nobody is paired with.
            keepDamagedCopy(of: data)
            pairingDataWasReset = true
            syncLog.error("sync.json was damaged; started over with a new identity")
        }
        deviceID = UUID().uuidString
        devices = []
        isLoaded = true
        save()
    }

    /// Takes the pairings from a readable file: keys from the file are moved into the vault, keys missing from the file
    /// are read from it. Returns without loading (try again later) while the vault can't be read yet.
    private func load(_ file: File) {
        var vaultKeys: [String: Data] = [:]
        var lost: Set<String> = []
        for stored in file.devices where stored.key == nil {
            switch keyVault.read(account: stored.deviceID) {
            case .found(let key): vaultKeys[stored.deviceID] = key
            case .locked: return
            case .notFound, .unavailable: lost.insert(stored.deviceID)
            }
        }
        var loaded: [PairedDevice] = []
        var inVault: Set<String> = []
        var moved = false
        for stored in file.devices {
            if let key = stored.key {
                if keyVault.write(key, account: stored.deviceID) {
                    inVault.insert(stored.deviceID)
                    moved = true
                }
                loaded.append(stored.device(key: key))
            } else if let key = vaultKeys[stored.deviceID] {
                inVault.insert(stored.deviceID)
                loaded.append(stored.device(key: key))
            }
        }
        deviceID = file.deviceID
        devices = loaded
        keysInVault = inVault
        isLoaded = true
        for device in devices { lastSavedSync[device.deviceID] = device.lastSyncedAt }
        if !lost.isEmpty {
            pairingDataWasReset = true
            if loaded.isEmpty {
                // Every key is missing: this file was made on another device. Don't speak as that device.
                deviceID = UUID().uuidString
            }
            syncLog.error("\(lost.count) pairing key(s) aren't on this device; those pairings were dropped")
        }
        if moved || !lost.isEmpty {
            save()
            if moved { syncLog.notice("moved the pairing keys into the Keychain") }
        }
    }

    /// The person has seen `pairingResetMessage`.
    func acknowledgePairingReset() {
        pairingDataWasReset = false
    }

    func device(id: String) -> PairedDevice? {
        devices.first { $0.deviceID == id }
    }

    /// Adds a pairing, replacing an earlier one with the same device. `replacingAll`: the iPhone pairs with one Mac.
    func add(_ device: PairedDevice, replacingAll: Bool = false) {
        if replacingAll {
            for other in devices where other.deviceID != device.deviceID { forgetKey(of: other.deviceID) }
            devices = [device]
        } else {
            devices.removeAll { $0.deviceID == device.deviceID }
            devices.append(device)
        }
        if keyVault.write(device.key, account: device.deviceID) {
            keysInVault.insert(device.deviceID)
        } else {
            keysInVault.remove(device.deviceID)
        }
        save()
    }

    func remove(deviceID: String) {
        guard devices.contains(where: { $0.deviceID == deviceID }) else { return }
        devices.removeAll { $0.deviceID == deviceID }
        forgetKey(of: deviceID)
        save()
    }

    private func forgetKey(of deviceID: String) {
        keyVault.delete(account: deviceID)
        keysInVault.remove(deviceID)
    }

    func markSynced(deviceID: String, at date: Date = .now) {
        guard let index = devices.firstIndex(where: { $0.deviceID == deviceID }) else { return }
        devices[index].lastSyncedAt = date
        if let saved = lastSavedSync[deviceID], date.timeIntervalSince(saved) < Self.syncTimeSaveInterval { return }
        lastSavedSync[deviceID] = date
        save()
    }

    /// Writes the current state (the latest "last synced" times included) now.
    func saveNow() {
        for device in devices { lastSavedSync[device.deviceID] = device.lastSyncedAt }
        save()
    }

    // MARK: File

    /// Keeps the damaged `sync.json`'s bytes as "sync-corrupt-<unix time>.json" (never over an earlier copy).
    private func keepDamagedCopy(of data: Data) {
        let directory = fileURL.deletingLastPathComponent()
        let stamp = Int(Date.now.timeIntervalSince1970)
        var name = "sync-corrupt-\(stamp).json"
        var attempt = 1
        while FileManager.default.fileExists(atPath: directory.appending(path: name).path(percentEncoded: false)) {
            attempt += 1
            name = "sync-corrupt-\(stamp)-\(attempt).json"
        }
        do {
            #if os(iOS)
            try data.write(
                to: directory.appending(path: name),
                options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication]
            )
            #else
            try data.write(to: directory.appending(path: name), options: .withoutOverwriting)
            #endif
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: directory.appending(path: name).path(percentEncoded: false)
            )
        } catch {
            syncLog.error("could not keep the damaged sync.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Version 2 leaves out the keys that are in the vault. (Version 1 files, with every key, read the same way.)
    private struct File: Codable {
        var version = 2
        var deviceID: String
        var devices: [StoredDevice]
    }

    /// A pairing as the file keeps it: `key` is nil when it is in the vault.
    private struct StoredDevice: Codable {
        var deviceID: String
        var name: String
        var platform: SyncHello.Platform
        var key: Data?
        var pairedAt: Date
        var lastSyncedAt: Date?

        init(_ device: PairedDevice, includingKey: Bool) {
            deviceID = device.deviceID
            name = device.name
            platform = device.platform
            key = includingKey ? device.key : nil
            pairedAt = device.pairedAt
            lastSyncedAt = device.lastSyncedAt
        }

        func device(key: Data) -> PairedDevice {
            PairedDevice(
                deviceID: deviceID, name: name, platform: platform, key: key, pairedAt: pairedAt, lastSyncedAt: lastSyncedAt
            )
        }
    }

    private func save() {
        guard isLoaded else { return }
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let stored = devices.map { StoredDevice($0, includingKey: !keysInVault.contains($0.deviceID)) }
            let data = try encoder.encode(File(deviceID: deviceID, devices: stored))
            #if os(iOS)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: fileURL, options: .atomic)
            #endif
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path(percentEncoded: false))
        } catch {
            syncLog.error("could not save the pairings: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
