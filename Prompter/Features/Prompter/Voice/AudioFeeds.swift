import AVFoundation
import os

/// Where voice-follow's audio comes from: the microphone, or (debug builds) a file played in real time.
@MainActor
protocol AudioFeed: AnyObject {
    /// Gets ready (the microphone: the audio session) and returns the format the buffers will come in.
    func prepare() throws -> AVAudioFormat
    /// Starts delivering buffers, on an audio thread.
    func start(deliver: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
    /// Stops delivering (the microphone: off). `releasingSession`: also hand the shared audio session back; false when a
    /// newer feed is using it.
    func stop(releasingSession: Bool)
    /// The input changed or stalled under it (headphones or a microphone plugged in or out, AirPods connecting, an
    /// interruption ending, the media services restarting) and it stopped delivering; start again to carry on.
    var onInputChanged: (() -> Void)? { get set }
}

extension AudioFeed {
    /// Stops delivering and hands the audio session back.
    func stop() {
        stop(releasingSession: true)
    }
}

enum AudioFeedError: Error {
    case noInput
}

/// The microphone through `AVAudioEngine`, with the audio session active only between `prepare()` and `stop()`.
///
/// Session: `.playAndRecord` so system sounds still play while listening, `.measurement` so the recogniser gets the
/// voice without the call-style processing, `.defaultToSpeaker` so anything that does play comes out of the speaker
/// rather than the earpiece, and `.mixWithOthers` so listening never stops other audio. The countdown beeps all sound
/// before the session is switched on (see `VoiceFollowController.startDelay`).
///
/// Whatever stops the microphone under it is reported through `onInputChanged`, so `LiveSpeechSource` starts listening
/// afresh (and falls back to WPM if that keeps happening): a route change, the end of an interruption (an alarm, Siri),
/// the media services restarting, or no audio at all for `stallLimit` while it should be listening.
@MainActor
final class MicrophoneFeed: AudioFeed {
    var onInputChanged: (() -> Void)?
    private let engine = AVAudioEngine()
    private var isTapped = false
    private var observers: [any NSObjectProtocol] = []
    /// An interruption began and hasn't ended: no audio is expected, so the stall check waits.
    private var isInterrupted = false
    private var stallCheck: Task<Void, Never>?
    /// When the newest buffer arrived (system uptime); written on the audio thread.
    private let lastBuffer = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)

    /// Listening with no buffer for this long counts as the input having changed. Buffers come every ~40 ms, silence
    /// included, so only a microphone that has really stopped goes this long.
    nonisolated static let stallLimit: TimeInterval = 2
    private static let stallCheckInterval: Duration = .milliseconds(500)

    func prepare() throws -> AVAudioFormat {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .mixWithOthers])
        try session.setActive(true)
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioFeedError.noInput }
        return format
    }

    func start(deliver: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.tapBlock(deliver, noting: lastBuffer))
        isTapped = true
        engine.prepare()
        try engine.start()
        lastBuffer.withLock { $0 = Self.uptime }
        observe()
        startStallCheck()
    }

    func stop(releasingSession: Bool) {
        stallCheck?.cancel()
        stallCheck = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if isTapped {
            engine.inputNode.removeTap(onBus: 0)
            isTapped = false
        }
        engine.stop()
        if releasingSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: Private

    private nonisolated static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func observe() {
        let center = NotificationCenter.default
        // A route change stops the engine and may change the input format: listen again afresh.
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.inputChanged("Audio input changed") }
        })
        // An alarm, Siri or another app's audio interrupts the session and stops the engine; once it ends, listen again.
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                guard let self, let rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
                switch type {
                case .began:
                    VoiceLog.logger.info("Audio interrupted")
                    self.isInterrupted = true
                case .ended:
                    self.isInterrupted = false
                    self.inputChanged("Audio interruption ended")
                @unknown default:
                    break
                }
            }
        })
        // The media services restarted: every audio object is gone, so a new feed has to start from scratch.
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.inputChanged("Media services were reset") }
        })
    }

    /// Every `stallCheckInterval`: no buffer for `stallLimit` (and no interruption going on) counts as an input change.
    private func startStallCheck() {
        stallCheck?.cancel()
        stallCheck = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.stallCheckInterval)
                guard !Task.isCancelled, let self else { return }
                guard !self.isInterrupted else { continue }
                let quiet = Self.uptime - self.lastBuffer.withLock { $0 }
                if quiet > Self.stallLimit {
                    self.inputChanged("No audio for \(Int(quiet.rounded())) s")
                    return
                }
            }
        }
    }

    private func inputChanged(_ reason: String) {
        VoiceLog.logger.info("\(reason, privacy: .public); listening again")
        onInputChanged?()
    }

    /// Made outside the main actor: a closure written inside this class would be main-actor isolated, and the audio
    /// thread calling it would trap.
    private nonisolated static func tapBlock(
        _ deliver: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        noting lastBuffer: OSAllocatedUnfairLock<TimeInterval>
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            lastBuffer.withLock { $0 = ProcessInfo.processInfo.systemUptime }
            deliver(buffer)
        }
    }
}

#if DEBUG
/// Debug builds (`-voiceFile`): an audio file instead of the microphone, delivered in 0.1 s buffers at real-time pace,
/// then silence until stopped, as a quiet room would sound. Lets the simulator follow a recorded read-through.
@MainActor
final class FileFeed: AudioFeed {
    var onInputChanged: (() -> Void)?
    private let url: URL
    private var player: FilePlayer?
    private var task: Task<Void, Never>?

    init(url: URL) {
        self.url = url
    }

    func prepare() throws -> AVAudioFormat {
        let player = try FilePlayer(url: url)
        self.player = player
        return player.format
    }

    func start(deliver: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        guard let player else { throw AudioFeedError.noInput }
        task = Task.detached(priority: .userInitiated) {
            await player.play(deliver: deliver)
        }
    }

    /// No audio session to hand back.
    func stop(releasingSession: Bool) {
        task?.cancel()
        task = nil
        player = nil
    }
}

/// Reads the file on its own task only.
private final class FilePlayer: @unchecked Sendable {
    let format: AVAudioFormat
    private let file: AVAudioFile
    private static let chunkSeconds = 0.1

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        format = file.processingFormat
    }

    func play(deliver: @Sendable (AVAudioPCMBuffer) -> Void) async {
        let frames = AVAudioFrameCount(format.sampleRate * Self.chunkSeconds)
        let clock = ContinuousClock()
        let start = clock.now
        var sent = 0.0
        while !Task.isCancelled {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            if file.framePosition < file.length {
                do { try file.read(into: buffer, frameCount: frames) } catch { return }
            } else {
                buffer.frameLength = frames
                for channel in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                    if let data = channel.mData { memset(data, 0, Int(channel.mDataByteSize)) }
                }
            }
            guard buffer.frameLength > 0 else { return }
            deliver(buffer)
            sent += Double(buffer.frameLength) / format.sampleRate
            try? await clock.sleep(until: start.advanced(by: .seconds(sent)))
        }
    }
}
#endif
