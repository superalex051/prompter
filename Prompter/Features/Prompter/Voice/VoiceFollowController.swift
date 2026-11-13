import Foundation

/// Voice-follow for one open prompter: listens while the engine plays in voice mode and moves the text to where the reader
/// is.
///
/// - **Getting ready:** as soon as the prompter is in voice mode (it opens in it, or Voice is picked in its settings) the
///   source asks for permission and readies the recogniser, so any system prompt shows while the presenter is still at
///   the phone, not after they started the take from the watch.
/// - **Listening:** only while the engine wants voice input (voice mode, playing). The microphone goes off on pause, at
///   the end, when the prompter closes or another mode is picked. Starting right after the countdown's "go" sound, it
///   waits `startDelay` so the session switch never clips the sound.
/// - **Following:** each change in what was heard goes through the `VoiceAligner`; a confident match sends the line of the
///   next word to read to the engine (`ScrollEngine.followVoice`), or the end after the last word. A move by hand (step,
///   drag, back to top) makes the aligner pick up from the new place, and what was heard before it stops counting (or
///   words from before a step back would pull the text forward again).
/// - **Problems:** permission denied, no recogniser, a failure while listening → `engine.setVoiceProblem`, so the take goes
///   on at the WPM pace and the HUD says why. Each new start tries again (access may have been granted in Settings).
@MainActor
final class VoiceFollowController {
    private enum Readiness: Equatable {
        case unknown, preparing, ready
        case failed(VoiceProblem)
    }

    let engine: ScrollEngine
    /// Built the first time the prompter is in voice mode (most takes never are, and a long script takes a moment to
    /// break into tokens); nil until then.
    private(set) var aligner: VoiceAligner?
    private var document: PrompterDocument
    private let source: SpeechSource
    /// Wait this long after "go" before turning the microphone on (0 in tests).
    private let startDelay: Duration
    private var readiness = Readiness.unknown
    private(set) var isListening = false
    /// The engine's `manualMoveCount` the aligner was last synced to.
    private var syncedMoveCount: Int?
    /// A failed preparation is retried once per take start.
    private var retriedThisTake = false
    private var pendingStart: Task<Void, Never>?
    private var isClosed = false
    /// The preparation in flight, if any (tests await it).
    private(set) var preparation: Task<Void, Never>?

    init(engine: ScrollEngine, document: PrompterDocument, source: SpeechSource, startDelay: Duration = .milliseconds(400)) {
        self.engine = engine
        self.document = document
        self.source = source
        self.startDelay = startDelay
        source.onWords = { [weak self] words in self?.heard(words) }
        source.onFailure = { [weak self] problem in self?.failed(problem) }
        engine.onVoiceChange = { [weak self] in self?.update() }
        update()
    }

    /// The prompter shows the script differently (Settings → Markdown formatting changed): the words to follow are the
    /// new document's, picked up from wherever the text is.
    func documentChanged(_ newDocument: PrompterDocument) {
        guard newDocument != document else { return }
        document = newDocument
        if aligner != nil {
            aligner = nil
            update()
        }
    }

    /// The prompter closed: the microphone goes off for good.
    func close() {
        isClosed = true
        engine.onVoiceChange = nil
        stopListening()
    }

    // MARK: State

    /// Re-reads the engine: gets ready when voice mode is on, listens exactly while it wants voice input.
    private func update() {
        guard !isClosed else { return }
        guard engine.isVoiceMode else {
            stopListening()
            retriedThisTake = false
            return
        }
        if aligner == nil {
            aligner = VoiceAligner(document: document)
            syncedMoveCount = nil   // the new aligner picks up from wherever the text is
        }
        if !engine.wantsVoiceInput {
            stopListening()
            retriedThisTake = false
        }
        switch readiness {
        case .unknown:
            prepare()
        case .failed:
            engine.setVoiceProblem(readinessProblem)
            if engine.wantsVoiceInput, !retriedThisTake {
                retriedThisTake = true
                prepare()
            }
        case .preparing:
            break
        case .ready:
            if engine.wantsVoiceInput { startListening() }
        }
    }

    private var readinessProblem: VoiceProblem? {
        if case .failed(let problem) = readiness { return problem }
        return nil
    }

    private func prepare() {
        readiness = .preparing
        preparation = Task { [weak self, source] in
            let problem = await source.prepare()
            self?.prepared(problem)
        }
    }

    private func prepared(_ problem: VoiceProblem?) {
        guard !isClosed else { return }
        readiness = problem.map(Readiness.failed) ?? .ready
        engine.setVoiceProblem(problem)
        update()
    }

    // MARK: Listening

    private func startListening() {
        guard !isListening else { return }
        isListening = true
        sync()
        pendingStart?.cancel()
        let delay = startDelay
        if delay > .zero {
            pendingStart = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, self.isListening else { return }
                self.source.start()
            }
        } else {
            source.start()
        }
    }

    private func stopListening() {
        pendingStart?.cancel()
        pendingStart = nil
        guard isListening else { return }
        isListening = false
        source.stop()
    }

    private func failed(_ problem: VoiceProblem) {
        guard !isClosed else { return }
        stopListening()
        readiness = .failed(problem)
        engine.setVoiceProblem(problem)
    }

    // MARK: Following

    private func heard(_ words: [String]) {
        guard isListening, engine.isFollowingVoice else { return }
        if sync() {
            // Moved by hand since the last words: these were (mostly) said before the move.
            source.forgetHeard()
            return
        }
        // Mutates the stored aligner in place (nil before voice mode: nothing to follow).
        guard aligner?.advance(with: words) != nil, let aligner else { return }
        if aligner.isAtEnd {
            engine.followVoice(.end)
        } else if let word = aligner.nextWord ?? aligner.matchedWord {
            // The line of the next word to read: once the last word of a line is heard, the next line comes up.
            engine.followVoice(.character(aligner.words[word].range.lowerBound))
        }
    }

    /// After a move by hand (or the first time), the aligner picks up at the line now at the reading line. True if it did.
    @discardableResult
    private func sync() -> Bool {
        guard syncedMoveCount != engine.manualMoveCount else { return false }
        syncedMoveCount = engine.manualMoveCount
        aligner?.resync(toCharacterIndex: engine.readingCharacterIndex)
        return true
    }
}
