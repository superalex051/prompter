import Foundation
import os

/// The Mac's end of the Apple Watch remote. watchOS only talks to its paired iPhone, so the iPhone relays the watch's
/// commands over the paired sync connection (`SyncHost` hands them here) and relays the answers back.
///
/// Commands go through the open `PresenterSession`, exactly like the Presenter view's buttons and the keys: speed steps
/// are saved, the elapsed time is right, and the canvases wake. Without a presenting session nothing happens and the
/// answer says "not presenting". The Mac's prompter is on screen whenever it presents (the output fills the
/// teleprompter screen), so unlike the iPhone nothing is refused for being off screen.
///
/// While presenting, a main-actor loop samples the status every `sampleInterval` and hands it to `publish` (the host
/// sends it to the iPhones that asked, only when what the watch shows changed). When presenting stops it publishes
/// "not presenting" once and stops.
@MainActor
final class MacRemoteControl {
    nonisolated static let sampleInterval: Duration = .milliseconds(250)

    private let deviceName: String
    private let session: () -> PresenterSession?
    private let publish: (PrompterStatus) -> Void
    private let sampleInterval: Duration?
    private var sequenceClock = SequenceClock()
    private var sampleTask: Task<Void, Never>?
    /// The last state logged, so the log shows each change once (the end-to-end check reads it).
    private var loggedState: String?

    /// `session`: the presenting session, if any. `publish`: hands a status to the iPhones that asked. `sampleInterval`
    /// nil turns the sampling loop off (tests call `publishNow()`).
    init(
        deviceName: String,
        session: @escaping () -> PresenterSession?,
        publish: @escaping (PrompterStatus) -> Void,
        sampleInterval: Duration? = MacRemoteControl.sampleInterval
    ) {
        self.deviceName = deviceName
        self.session = session
        self.publish = publish
        self.sampleInterval = sampleInterval
    }

    /// Applies a command relayed from the watch and returns the fresh status (the answer to the iPhone).
    func handle(_ command: RemoteCommand) -> PrompterStatus {
        let time = Date.now.timeIntervalSince1970
        guard let session = session() else {
            let status = status()
            if command != .requestStatus {
                macRemoteLog.notice("remote \(String(describing: command), privacy: .public) refused: not presenting")
            }
            return status
        }
        Self.apply(command, to: session)
        let status = status()
        if command != .requestStatus {
            macRemoteLog.notice("""
                remote \(String(describing: command), privacy: .public) applied at \
                \(time, format: .fixed(precision: 3), privacy: .public): \(status.logDescription, privacy: .public)
                """)
        }
        noteState(status)
        publish(status)
        return status
    }

    /// The command, through the session (never the engine alone): see the type's notes.
    static func apply(_ command: RemoteCommand, to session: PresenterSession) {
        switch command {
        case .start: session.start()
        case .pause: session.pause()
        case .resume:
            // Resume only resumes (from idle it would start a take the watch didn't ask to start).
            if session.engine.state == .paused { session.togglePlay() }
        case .togglePlay: session.togglePlay()
        case .speedStep(let steps): session.speedStep(steps)
        case .setSpeed(let value):
            session.engine.setSpeed(value)
            // Saved like a speed step, so the pace persists.
            if session.settingsStore.settings != session.engine.settings {
                session.settingsStore.settings = session.engine.settings
            }
            session.wakeCanvases()
        case .backToTop: session.backToTop()
        case .jumpBack: session.jumpBack()
        case .requestStatus: break
        }
    }

    /// What the Mac's prompter is doing now, as the watch shows it (with this Mac's name).
    func status() -> PrompterStatus {
        guard let session = session() else {
            var status = PrompterStatus.noPrompter
            status.deviceName = deviceName
            status.sequence = sequenceClock.next()
            return status
        }
        let engine = session.engine
        return PrompterStatus(
            hasPrompter: true,
            scriptTitle: session.scriptTitle,
            state: engine.state,
            progress: engine.progress,
            remainingSeconds: engine.remainingSeconds,
            speedLabel: engine.speedLabel,
            sequence: sequenceClock.next(),
            isOnScreen: nil,
            deviceName: deviceName
        )
    }

    /// Presenting started, switched script or stopped: tells the iPhones at once and starts or stops sampling.
    func presentingChanged() {
        publishNow()
        if session() != nil {
            startSampling()
        } else {
            stopSampling()
        }
    }

    /// One tick: the current status to the host (which sends it only where something changed).
    func publishNow() {
        let status = status()
        noteState(status)
        publish(status)
    }

    // MARK: Private

    private func noteState(_ status: PrompterStatus) {
        let state = status.hasPrompter ? "\(status.state) \(status.speedLabel)" : "not presenting"
        guard state != loggedState else { return }
        loggedState = state
        macRemoteLog.notice("""
            presenter \(state, privacy: .public) at \(Date.now.timeIntervalSince1970, format: .fixed(precision: 3), privacy: .public)
            """)
    }

    private func startSampling() {
        guard sampleTask == nil, let sampleInterval else { return }
        sampleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: sampleInterval)
                // Only strong for this tick, so the loop never keeps the remote alive.
                guard !Task.isCancelled, let self else { return }
                guard self.session() != nil else {
                    self.stopSampling()
                    return
                }
                self.publishNow()
            }
        }
    }

    private func stopSampling() {
        sampleTask?.cancel()
        sampleTask = nil
    }
}

/// The Mac's remote log (Console: the app bundle ID as subsystem, category remote).
let macRemoteLog = Logger(subsystem: LogSubsystem.current, category: "remote")
