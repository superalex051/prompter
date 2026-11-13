import Foundation
#if os(macOS)
@testable import PrompterMac
#else
@testable import Prompter
#endif

// Helpers for the sync tests, which run in both test targets (iOS and macOS).

/// A fresh, empty directory under the system temp folder.
func makeSyncTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "PrompterSyncTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A clock a test moves by hand (sub-second steps allowed).
final class SyncTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current += seconds
        lock.unlock()
    }
}

/// A script with fixed whole-second dates.
func syncScript(
    _ id: UUID = UUID(), title: String = "Title", body: String = "Body", at seconds: TimeInterval = 1_800_000_000
) -> Script {
    Script(id: id, title: title, body: body, createdAt: Date(timeIntervalSince1970: seconds))
}

func live(_ script: Script, clock: Double) -> SyncRecord {
    .live(SyncedScript(script: script, clock: clock))
}

func deleted(_ id: UUID, at clock: Double) -> SyncRecord {
    .deleted(SyncTombstone(id: id, deletedAt: clock))
}

/// A `ScriptStore` in its own temp directory, on a hand-moved clock, starting empty.
@MainActor
struct StoreFixture {
    let directory: URL
    let clock: SyncTestClock
    let store: ScriptStore

    init(directory: URL? = nil, clock: SyncTestClock = SyncTestClock()) throws {
        let directory = try directory ?? makeSyncTestDirectory()
        self.directory = directory
        self.clock = clock
        store = Self.open(directory: directory, clock: clock)
    }

    /// The same library read again from disk.
    func reopened() -> ScriptStore {
        Self.open(directory: directory, clock: clock)
    }

    static func open(directory: URL, clock: SyncTestClock) -> ScriptStore {
        ScriptStore(directory: directory, now: { clock.now }, initialScripts: { _ in [] }, isProtectedDataAvailable: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
