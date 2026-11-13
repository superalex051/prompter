import AVFoundation
import Foundation
import Testing
@testable import Prompter

/// The audio session every feed shares (AVAudioSession is one per app).
@MainActor
final class FakeAudioSession {
    var isActive = false
}

/// Records what `LiveSpeechSource` does with a feed; readying it activates the shared session, stopping it with
/// `releasingSession` deactivates it.
@MainActor
final class FakeAudioFeed: AudioFeed {
    var onInputChanged: (() -> Void)?
    let session: FakeAudioSession
    private(set) var isPrepared = false
    private(set) var isStarted = false
    /// `releasingSession` of every `stop` call, in order.
    private(set) var stops: [Bool] = []

    init(session: FakeAudioSession) {
        self.session = session
    }

    func prepare() throws -> AVAudioFormat {
        isPrepared = true
        session.isActive = true
        return AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    }

    func start(deliver: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        isStarted = true
    }

    func stop(releasingSession: Bool) {
        stops.append(releasingSession)
        if releasingSession { session.isActive = false }
    }
}

/// A recogniser whose `start` can be held until the test lets it finish, like the real one getting its model ready.
final class GatedSpeechBackend: SpeechBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let holds: Bool
    private var waiting: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private var startCalled = false
    private var stopped = false

    init(holds: Bool) {
        self.holds = holds
    }

    var hasStartBegun: Bool { lock.withLock { startCalled } }
    var isStopped: Bool { lock.withLock { stopped } }

    func start(
        inputFormat: AVAudioFormat,
        onText: @escaping SpeechTextHandler,
        onFailure: @escaping SpeechFailureHandler
    ) async throws {
        lock.withLock { startCalled = true }
        guard holds else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock {
                if isReleased { return true }
                waiting = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// Lets a held `start` finish.
    func release() {
        let continuation = lock.withLock {
            isReleased = true
            defer { waiting = nil }
            return waiting
        }
        continuation?.resume()
    }

    func append(_ buffer: AVAudioPCMBuffer) {}

    func stop() {
        lock.withLock { stopped = true }
    }
}

/// A start that a newer start or a stop overtook must never hand back the audio session a newer take is using: that
/// left the microphone silently dead after a quick pause and resume (or closing and reopening the prompter), with the
/// HUD saying "Listening…" for good.
@MainActor
struct LiveSpeechSourceTests {
    @MainActor
    final class Rig {
        let session = FakeAudioSession()
        var feeds: [FakeAudioFeed] = []
        var backends: [GatedSpeechBackend] = []
        /// Whether each new backend holds its `start` until released.
        var holdNextBackends: [Bool] = []
        var source: LiveSpeechSource!
    }

    func makeRig(holds: [Bool]) -> Rig {
        let rig = Rig()
        rig.holdNextBackends = holds
        rig.source = LiveSpeechSource(
            choice: .analyzer(Locale(identifier: "en_US")),
            makeFeed: { [unowned rig] in
                let feed = FakeAudioFeed(session: rig.session)
                rig.feeds.append(feed)
                return feed
            },
            makeBackend: { [unowned rig] _ in
                let holds = rig.holdNextBackends.isEmpty ? false : rig.holdNextBackends.removeFirst()
                let backend = GatedSpeechBackend(holds: holds)
                rig.backends.append(backend)
                return backend
            }
        )
        return rig
    }

    /// Lets the source's start tasks run until `condition` holds (at most 2 s).
    func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func aStartOvertakenWhileUnderWayLeavesTheNewerTakesSessionAlone() async {
        let rig = makeRig(holds: [true, false])
        rig.source.start()
        await waitUntil { rig.backends.first?.hasStartBegun == true }
        let first = rig.feeds[0]
        #expect(first.isPrepared)

        // A quick pause and resume while the first start is still getting the recogniser ready.
        rig.source.stop()
        rig.source.start()
        await waitUntil { rig.feeds.count == 2 && rig.feeds[1].isStarted }
        let second = rig.feeds[1]
        #expect(second.isStarted)
        #expect(rig.session.isActive)

        // The first start finishes now: it stops its own recogniser and feed, but the session stays with the new take.
        rig.backends[0].release()
        await waitUntil { first.stops.count == 2 }
        #expect(first.stops == [true, false])   // the pause handed the session back; the stale start didn't touch it
        #expect(rig.backends[0].isStopped)
        #expect(!first.isStarted)
        #expect(rig.session.isActive, "the newer take's microphone must stay on")
        #expect(second.stops.isEmpty)
        #expect(!rig.backends[1].isStopped)
        rig.source.stop()
    }

    @Test func aStartOvertakenBeforeItBeganNeverReadiesItsFeed() async {
        let rig = makeRig(holds: [false, false])
        rig.source.start()
        rig.source.stop()
        rig.source.start()
        await waitUntil { rig.feeds.count == 2 && rig.feeds[1].isStarted }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!rig.feeds[0].isPrepared)       // gave up before touching the audio session
        #expect(!rig.feeds[0].isStarted)
        #expect(!rig.backends[0].hasStartBegun)
        #expect(rig.feeds[1].isStarted)
        #expect(rig.session.isActive)
        rig.source.stop()
        #expect(!rig.session.isActive)
    }

    @Test func aStopWithNothingNewerStillHandsTheSessionBack() async {
        let rig = makeRig(holds: [true])
        rig.source.start()
        await waitUntil { rig.backends.first?.hasStartBegun == true }
        rig.source.stop()                       // the prompter closed while the recogniser was getting ready
        rig.backends[0].release()
        await waitUntil { rig.feeds[0].stops.count == 2 }
        #expect(rig.feeds[0].stops == [true, true])
        #expect(!rig.feeds[0].isStarted)
        #expect(!rig.session.isActive)
    }

    @Test func anInputChangeRestartsListeningOnANewFeed() async {
        let rig = makeRig(holds: [false, false])
        rig.source.start()
        await waitUntil { rig.feeds.first?.isStarted == true }
        rig.feeds[0].onInputChanged?()          // a route change, an interruption ending, the media services resetting
        await waitUntil { rig.feeds.count == 2 && rig.feeds[1].isStarted }
        #expect(rig.feeds[0].stops == [true])
        #expect(rig.feeds[1].isStarted)
        #expect(rig.session.isActive)
        rig.source.stop()
    }
}
