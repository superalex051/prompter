import Foundation
import Observation

struct ImportFailure: Equatable, Sendable {
    var filename: String
    var message: String
}

struct ImportSummary: Sendable {
    var imported: [Script]
    var failures: [ImportFailure]
}

/// What `ScriptStore.applyRemote` changed: the ids, and a serial that grows with every remote change (editors watch it
/// to take in a new version of the script they show).
struct RemoteChange: Equatable, Sendable {
    var ids: Set<Script.ID>
    var serial: Int
}

/// The script library, persisted as one JSON file:
/// `{"version":2,"scripts":[...],"clocks":{"<id>":<sync clock>},"tombstones":[{"id":…,"deletedAt":…}]}`.
///
/// Version 2 adds what Mac ⇄ iPhone sync needs (see `Core/Sync`): every script's last-writer-wins clock and the deletions
/// of the last 30 days. A version 1 file loads as it is (each script's clock is then its `updatedAt`), and an older app
/// reading a version 2 file just ignores the two new keys.
@MainActor @Observable
final class ScriptStore {
    /// Always sorted: updatedAt desc, then createdAt desc, then id.
    private(set) var scripts: [Script]
    /// User-facing; set on load/save failure. Stays set until `clearError()` (the UI calls it when the alert is dismissed)
    /// or, for a save failure, until the next successful save, so a later failure changes it again and gets reported.
    private(set) var lastError: String?
    /// `<directory>/scripts.json`
    let fileURL: URL

    /// The library couldn't be read because the phone hasn't been unlocked since it restarted (see `init`): it is
    /// empty and nothing is saved until `protectedDataBecameAvailable()` loads it. The launch route waits for this.
    private(set) var isWaitingForProtectedData = false

    @ObservationIgnored private let now: @Sendable () -> Date
    /// What a first launch (no file yet) starts with.
    @ObservationIgnored private let initialScripts: @Sendable (Date) -> [Script]
    @ObservationIgnored private let notificationCenter: NotificationCenter
    /// Set when the file could not be read (or a bad file could not be moved aside), so a save never overwrites it.
    @ObservationIgnored private var savingBlocked = false
    @ObservationIgnored private var protectedDataWait: ProtectedDataWait?
    /// Sync clock of each live script whose clock is known (see `SyncClock`); a script without one uses its `updatedAt`.
    @ObservationIgnored private var clocks: [Script.ID: Double] = [:]
    /// Deleted scripts' ids and deletion clocks, kept for `SyncTombstone.lifetime`.
    @ObservationIgnored private(set) var tombstones: [Script.ID: Double] = [:]

    /// Called after every change made on this device (create, edit, delete, restore, import…), never for one that came
    /// from sync (`applyRemote`), so sync can push local changes without echoing remote ones back.
    @ObservationIgnored var onLocalChange: (@MainActor () -> Void)?
    /// The last change sync applied (nil until one does).
    private(set) var remoteChange: RemoteChange?

    static let saveFailedMessage = "Couldn't save your latest changes. Check that your \(deviceName) has free storage, then try again."
    static let openFailedMessage = "Couldn't open your scripts, so new changes won't be saved. Close Prompter and open it again."
    static let corruptFileMessage = """
        Couldn't read your saved scripts, so your library starts empty. The damaged file was kept on this \(deviceName).
        """
    static let corruptFileNotMovedMessage = "Couldn't read your saved scripts, so new changes won't be saved."

    /// What the messages call this device.
    #if os(macOS)
    private static let deviceName = "Mac"
    #else
    private static let deviceName = "iPhone"
    #endif

    /// Application Support/Prompter (created on demand). On the Mac (not sandboxed) that is
    /// ~/Library/Application Support/Prompter.
    nonisolated static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Prompter", directoryHint: .isDirectory)
    }

    /// Loads synchronously. No file → scripts = initialScripts(now) and save. Undecodable file → move it to
    /// "scripts-corrupt-<unix time>.json" in the same directory, save an empty library (so the next launch doesn't re-seed),
    /// scripts = [], lastError = `corruptFileMessage`. A file that exists but can't be read (I/O or permission error) is
    /// left untouched: scripts = [], saving is blocked, lastError = `openFailedMessage`.
    /// Blank scripts (left behind when the app quit with a new script's editor open) are dropped.
    ///
    /// Before the first unlock after a restart (a watch message can launch the app in the background then) the file is
    /// still encrypted. The store always tries to load; only when that fails AND `isProtectedDataAvailable` is false
    /// (the file exists but can't be read, or a first launch's sample can't be written) does it wait instead of
    /// reporting an error: the library stays empty, `isWaitingForProtectedData` is true, nothing is saved, and it loads as
    /// above once protected data becomes available (see `ProtectedDataWait`, listening on `notificationCenter`) or
    /// `protectedDataBecameAvailable()` is called.
    ///
    /// The flag alone is not trusted: it can read false while `App.init` runs on a normal launch (seen on the simulator),
    /// and waiting then would show an empty library and lose the launch route for nothing.
    init(
        directory: URL = ScriptStore.defaultDirectory,
        now: @escaping @Sendable () -> Date = { Date() },
        initialScripts: @escaping @Sendable (Date) -> [Script] = { [SampleScript.make(now: $0)] },
        isProtectedDataAvailable: Bool = ProtectedDataWait.isProtectedDataAvailable,
        notificationCenter: NotificationCenter = .default
    ) {
        fileURL = directory.appending(path: "scripts.json", directoryHint: .notDirectory)
        self.now = now
        self.initialScripts = initialScripts
        self.notificationCenter = notificationCenter
        scripts = []
        lastError = nil
        load(isProtectedDataAvailable: isProtectedDataAvailable)
    }

    /// The phone was unlocked: a load that waited for it happens now (anything changed meanwhile is replaced by what is
    /// on disk, which nothing was allowed to overwrite). A failure now is reported as usual. Does nothing otherwise.
    func protectedDataBecameAvailable() {
        guard isWaitingForProtectedData else { return }
        isWaitingForProtectedData = false
        protectedDataWait?.cancel()
        protectedDataWait = nil
        scripts = []
        load(isProtectedDataAvailable: true)
    }

    func script(id: Script.ID) -> Script? {
        scripts.first { $0.id == id }
    }

    /// The UI calls this once it has shown `lastError`, so the next failure is reported again.
    func clearError() {
        lastError = nil
    }

    @discardableResult
    func create(title: String = "", body: String = "") -> Script {
        let script = Script(title: title, body: body, createdAt: timestamp())
        insert([script])
        return script
    }

    /// nil when the text has no words. Uses ScriptImporter.fromPlainText.
    @discardableResult
    func createFromText(_ text: String) -> Script? {
        guard let imported = try? ScriptImporter.fromPlainText(text) else { return nil }
        return create(title: imported.title, body: imported.body)
    }

    /// Starts/stops security-scoped access per URL. One script per readable file; failures carry the file name + message.
    func importFiles(at urls: [URL]) -> ImportSummary {
        let createdAt = timestamp()
        var imported: [Script] = []
        var failures: [ImportFailure] = []
        for url in urls {
            let isAccessing = url.startAccessingSecurityScopedResource()
            defer { if isAccessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let result = try ScriptImporter.importFile(at: url)
                imported.append(Script(title: result.title, body: result.body, createdAt: createdAt))
            } catch {
                failures.append(ImportFailure(filename: url.lastPathComponent, message: error.message))
            }
        }
        if !imported.isEmpty { insert(imported) }
        return ImportSummary(imported: imported, failures: failures)
    }

    /// No-op (no updatedAt bump, no save) when nothing actually changes.
    func update(_ id: Script.ID, title: String? = nil, body: String? = nil) {
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
        var script = scripts[index]
        if let title { script.title = title }
        if let body { script.body = body }
        guard script.title != scripts[index].title || script.body != scripts[index].body else { return }
        script.updatedAt = timestamp()
        clocks[id] = SyncClock.next(now: now(), after: clock(of: scripts[index]))
        scripts[index] = script
        scripts = Self.sorted(scripts)
        save()
        onLocalChange?()
    }

    func rename(_ id: Script.ID, to title: String) {
        update(id, title: title.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// New id, title "<displayTitle> copy", same body, createdAt = updatedAt = now.
    @discardableResult
    func duplicate(_ id: Script.ID) -> Script? {
        guard let original = script(id: id) else { return nil }
        let copy = Script(title: "\(original.displayTitle) copy", body: original.body, createdAt: timestamp())
        insert([copy])
        return copy
    }

    /// Returns the removed script so the UI can offer Undo.
    @discardableResult
    func delete(_ id: Script.ID) -> Script? {
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = scripts.remove(at: index)
        tombstones[id] = SyncClock.next(now: now(), after: clock(of: removed))
        clocks[id] = nil
        save()
        onLocalChange?()
        return removed
    }

    /// Undo for delete: re-inserts with its original id and timestamps (no-op if the id already exists). Its sync clock is
    /// new, so the restored script also wins over the deletion on a synced device.
    func restore(_ script: Script) {
        guard self.script(id: script.id) == nil else { return }
        insert([script])
    }

    /// Removes the script if `isBlank`; returns true if removed. The editor calls this when it closes.
    @discardableResult
    func deleteIfBlank(_ id: Script.ID) -> Bool {
        guard let script = script(id: id), script.isBlank else { return false }
        return delete(id) != nil
    }

    /// Re-adds the sample script (fresh timestamps) if no script has SampleScript.id. Used by M2 app settings.
    func restoreSampleScript() {
        guard script(id: SampleScript.id) == nil else { return }
        insert([SampleScript.make(now: timestamp())])
    }

    // MARK: Sync

    /// The sync clock of a script a first launch seeded (the sample) and nobody has edited since: older than any real
    /// version, so whatever another device has for that id (its edited sample, or the sample's deletion) wins.
    static let seedClock: Double = 0

    /// What sync compares and sends: every script with its clock, and every deletion. Left out:
    /// - blank scripts (a new script nobody has typed into yet), so they never show up on the other device;
    /// - seeded scripts nobody has edited (`seedClock`): a fresh install's sample must never replace the sample someone
    ///   edited on their other device, nor bring back one they deleted there. An edit here gives it a real clock.
    var syncRecords: [Script.ID: SyncRecord] {
        allRecords().filter { record in
            if case .live(let synced) = record.value {
                return !synced.script.isBlank && synced.clock > Self.seedClock
            }
            return true
        }
    }

    /// Merges scripts and deletions that came from another device (last writer wins, see `SyncMerge`) and returns the ones
    /// that changed this library. They keep their own dates and clocks, and `onLocalChange` is not called, so nothing is
    /// sent back. Ignored while the library is still waiting to be read.
    @discardableResult
    func applyRemote(scripts incomingScripts: [SyncedScript], deletions: [SyncTombstone]) -> [SyncRecord] {
        guard !isWaitingForProtectedData else { return [] }
        let incoming = incomingScripts.filter { !$0.script.isBlank }.map(SyncRecord.live) + deletions.map(SyncRecord.deleted)
        let applied = SyncMerge.merge(local: allRecords(), incoming: incoming).applied
        guard !applied.isEmpty else { return [] }
        let currentTime = now()
        var updated = scripts
        for record in applied {
            switch record {
            case .live(let synced):
                if let index = updated.firstIndex(where: { $0.id == synced.script.id }) {
                    updated[index] = synced.script
                } else {
                    updated.append(synced.script)
                }
                clocks[synced.script.id] = synced.clock
                tombstones[synced.script.id] = nil
            case .deleted(let tombstone):
                updated.removeAll { $0.id == tombstone.id }
                clocks[tombstone.id] = nil
                tombstones[tombstone.id] = tombstone.isExpired(now: currentTime) ? nil : tombstone.deletedAt
            }
        }
        scripts = Self.sorted(updated)
        save()
        remoteChange = RemoteChange(ids: Set(applied.map(\.id)), serial: (remoteChange?.serial ?? 0) + 1)
        return applied
    }

    /// Every live script (blank ones too) and every deletion.
    private func allRecords() -> [Script.ID: SyncRecord] {
        var records: [Script.ID: SyncRecord] = [:]
        for (id, deletedAt) in tombstones {
            records[id] = .deleted(SyncTombstone(id: id, deletedAt: deletedAt))
        }
        for script in scripts {
            records[script.id] = .live(SyncedScript(script: script, clock: clock(of: script)))
        }
        return records
    }

    // MARK: Private

    /// The file stores whole seconds (ISO 8601), so in-memory timestamps do too; a reload then changes nothing.
    private func timestamp() -> Date {
        Date(timeIntervalSince1970: now().timeIntervalSince1970.rounded(.down))
    }

    private func insert(_ newScripts: [Script]) {
        for script in newScripts {
            let previous = tombstones.removeValue(forKey: script.id) ?? clocks[script.id]
            clocks[script.id] = SyncClock.next(now: now(), after: previous)
        }
        scripts = Self.sorted(scripts + newScripts)
        save()
        onLocalChange?()
    }

    private func clock(of script: Script) -> Double {
        clocks[script.id] ?? SyncClock.rounded(script.updatedAt.timeIntervalSince1970)
    }

    private static func sorted(_ scripts: [Script]) -> [Script] {
        scripts.sorted { a, b in
            if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            return a.id.uuidString < b.id.uuidString
        }
    }

    /// `isProtectedDataAvailable` false: a failure to read the file or to write a first launch's sample waits for the
    /// first unlock (`waitForProtectedData()`) instead of being reported.
    private func load(isProtectedDataAvailable: Bool) {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            scripts = Self.sorted(initialScripts(timestamp()))
            // Seeded, not written by anyone: see `seedClock`.
            clocks = Dictionary(scripts.map { ($0.id, Self.seedClock) }, uniquingKeysWith: { first, _ in first })
            do {
                // Never replaces a file, even one that appeared since the check above.
                try write(replacingExisting: false)
            } catch {
                if isProtectedDataAvailable {
                    lastError = Self.saveFailedMessage
                } else {
                    waitForProtectedData()
                }
            }
            return
        }
        // A read error (locked by data protection, I/O error) says nothing about the contents: leave the file alone.
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            if isProtectedDataAvailable {
                savingBlocked = true
                lastError = Self.openFailedMessage
            } else {
                waitForProtectedData()
            }
            return
        }
        let file: ScriptFile
        do {
            file = try ScriptFile.decoder().decode(ScriptFile.self, from: data)
        } catch {
            moveUnreadableFileAside()
            return
        }
        let decoded = file.scripts
        // The editor removes a blank new script when it closes; this catches the ones the app quit on.
        let kept = decoded.filter { !$0.isBlank }
        scripts = Self.sorted(kept)
        let liveIDs = Set(kept.map(\.id))
        clocks = [:]
        for (key, clock) in file.clocks ?? [:] {
            if let id = UUID(uuidString: key), liveIDs.contains(id) { clocks[id] = clock }
        }
        let currentTime = now()
        tombstones = [:]
        for tombstone in file.tombstones ?? [] where !liveIDs.contains(tombstone.id) && !tombstone.isExpired(now: currentTime) {
            tombstones[tombstone.id] = max(tombstone.deletedAt, tombstones[tombstone.id] ?? tombstone.deletedAt)
        }
        if kept.count != decoded.count { save() }
    }

    /// The file can't be read or written yet (before the first unlock): start empty, save nothing, and load once
    /// protected data becomes available.
    private func waitForProtectedData() {
        scripts = []
        isWaitingForProtectedData = true
        protectedDataWait = ProtectedDataWait(center: notificationCenter) { [weak self] in
            self?.protectedDataBecameAvailable()
        }
    }

    /// Keeps the bad file under a new name (never overwriting an earlier copy) so the next save can't destroy it.
    private func moveUnreadableFileAside() {
        let directory = fileURL.deletingLastPathComponent()
        let stamp = Int(now().timeIntervalSince1970)
        var name = "scripts-corrupt-\(stamp).json"
        var attempt = 1
        while FileManager.default.fileExists(atPath: directory.appending(path: name).path(percentEncoded: false)) {
            attempt += 1
            name = "scripts-corrupt-\(stamp)-\(attempt).json"
        }
        do {
            try FileManager.default.moveItem(at: fileURL, to: directory.appending(path: name))
            lastError = Self.corruptFileMessage
            // An empty library on disk, so the next launch doesn't seed the sample and hide what happened.
            try? write()
        } catch {
            savingBlocked = true
            lastError = Self.corruptFileNotMovedMessage
        }
    }

    private func save() {
        // Before the first unlock the file can't be read, so writing would replace a library nobody has loaded.
        guard !savingBlocked, !isWaitingForProtectedData else { return }
        do {
            try write()
            if lastError == Self.saveFailedMessage { lastError = nil }
        } catch {
            lastError = Self.saveFailedMessage
        }
    }

    /// `replacingExisting` false: fails instead of writing over a file that is already there (a first launch's sample).
    private func write(replacingExisting: Bool = true) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let file = ScriptFile(
            version: ScriptFile.currentVersion,
            scripts: scripts,
            clocks: Dictionary(uniqueKeysWithValues: clocks.map { ($0.key.uuidString, $0.value) }),
            tombstones: tombstones.map { SyncTombstone(id: $0.key, deletedAt: $0.value) }
                .sorted { $0.id.uuidString < $1.id.uuidString }
        )
        let data = try ScriptFile.encoder().encode(file)
        try data.write(to: fileURL, options: replacingExisting ? .atomic : .withoutOverwriting)
    }
}

private struct ScriptFile: Codable {
    /// 2: adds `clocks` and `tombstones` for sync. Version 1 files have neither.
    static let currentVersion = 2

    var version: Int
    var scripts: [Script]
    /// Sync clock by script id (uuidString).
    var clocks: [String: Double]?
    var tombstones: [SyncTombstone]?

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
