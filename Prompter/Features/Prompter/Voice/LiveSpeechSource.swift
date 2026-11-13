import AVFoundation
import Foundation

/// The real `SpeechSource`: the microphone (or, in debug builds, an audio file) recognised on the device by
/// SpeechAnalyzer, or SFSpeechRecognizer where that isn't available (see `SpeechRecognizerChoice`). Nothing leaves the
/// device and nothing is recorded: the audio goes straight into the recogniser and only the recognised words come back.
@MainActor
final class LiveSpeechSource: SpeechSource {
    var onWords: (([String]) -> Void)?
    var onFailure: ((VoiceProblem) -> Void)?

    private let wantedLocale: Locale
    private let vocabulary: [String]
    /// Debug builds: play this file instead of using the microphone.
    private let audioFile: URL?
    private var choice: SpeechRecognizerChoice?
    private var transcript = SpeechTranscript()
    private var feed: AudioFeed?
    private var backend: SpeechBackend?
    private var starting: Task<Void, Never>?
    /// Bumped by every start and stop, so callbacks from an older session are ignored.
    private var session = 0
    /// When listening restarted after the audio input changed; more than a few in a short while means it can't settle.
    private var inputRestarts: [Date] = []
    /// Tests: stand-ins for the audio feed and the recogniser (nil: the real ones).
    private let feedFactory: (@MainActor () -> AudioFeed)?
    private let backendFactory: (@MainActor (SpeechRecognizerChoice) -> SpeechBackend?)?

    init(locale: Locale, vocabulary: [String], audioFile: URL? = nil) {
        wantedLocale = locale
        self.vocabulary = vocabulary
        self.audioFile = audioFile
        feedFactory = nil
        backendFactory = nil
    }

    /// Tests: a recogniser already chosen (no `prepare()` needed), with stand-ins for the feed and the recogniser.
    init(
        choice: SpeechRecognizerChoice,
        makeFeed: @escaping @MainActor () -> AudioFeed,
        makeBackend: @escaping @MainActor (SpeechRecognizerChoice) -> SpeechBackend?
    ) {
        wantedLocale = Locale(identifier: "en_US")
        vocabulary = []
        audioFile = nil
        self.choice = choice
        feedFactory = makeFeed
        backendFactory = makeBackend
    }

    /// Never leave the microphone on.
    isolated deinit {
        feed?.stop()
        backend?.stop()
    }

    /// The source for a script: listens in the script's language, biased to its words. In debug builds `-voiceFile`
    /// swaps the microphone for that file, and `-voiceReplay` swaps recognition for recorded results.
    static func make(for document: PrompterDocument) -> SpeechSource {
        var file: URL?
        #if DEBUG
        let options = LaunchOptions()
        if let replay = options.voiceReplayURL { return ReplaySpeechSource(url: replay) }
        file = options.voiceFileURL
        #endif
        return LiveSpeechSource(
            locale: VoiceLocale.preferred(forScript: document.text),
            vocabulary: VoiceVocabulary.words(in: document),
            audioFile: file
        )
    }

    func prepare() async -> VoiceProblem? {
        if audioFile == nil {
            switch VoicePermissions.microphone {
            case .denied:
                return .microphoneDenied
            case .notAsked:
                guard await VoicePermissions.requestMicrophone() else { return .microphoneDenied }
            case .granted:
                break
            }
        }
        var modelMissing = false
        if let locale = await SpeechRecognizerChoice.analyzerLocale(for: wantedLocale) {
            if await SpeechRecognizerChoice.ensureAnalyzerModel(for: locale) {
                choice = .analyzer(locale)
                VoiceLog.logger.info("Voice ready: SpeechAnalyzer, \(locale.identifier, privacy: .public)")
                return nil
            }
            modelMissing = true
        }
        if let locale = SpeechRecognizerChoice.recognizerLocale(for: wantedLocale) {
            switch VoicePermissions.speechRecognition {
            case .denied:
                return .speechDenied
            case .notAsked:
                guard await VoicePermissions.requestSpeechRecognition() else { return .speechDenied }
            case .granted:
                break
            }
            choice = .recognizer(locale)
            VoiceLog.logger.info("Voice ready: SFSpeechRecognizer on device, \(locale.identifier, privacy: .public)")
            return nil
        }
        VoiceLog.logger.error("No on-device recogniser for \(self.wantedLocale.identifier, privacy: .public)")
        return modelMissing ? .modelUnavailable : .unsupported
    }

    /// Turns the microphone on: the feed readies the audio session, the recogniser gets ready for its format, then the
    /// buffers flow. The audio session is shared by every feed, so a start that a newer start or a stop overtook (a quick
    /// pause and resume, or closing and reopening the prompter) never touches it: it gives up before readying the feed,
    /// or, if it was already under way, stops its own feed without handing the session back while a newer feed uses it.
    /// (It used to deactivate the session under the newer take: the microphone went silent and the HUD said
    /// "Listening…" for good.)
    func start() {
        stop()
        guard let choice else {
            onFailure?(.failed)
            return
        }
        let current = session
        guard let backend = makeBackend(for: choice) else {
            onFailure?(.unsupported)
            return
        }
        let feed = makeFeed()
        self.backend = backend
        self.feed = feed
        feed.onInputChanged = { [weak self] in
            guard let self, self.session == current else { return }
            let now = Date()
            self.inputRestarts = self.inputRestarts.filter { now.timeIntervalSince($0) < 10 } + [now]
            if self.inputRestarts.count > 3 {
                self.failed(.failed, session: current)
            } else {
                self.start()
            }
        }

        let onText: SpeechTextHandler = { [weak self] segment, text, isFinal in
            self?.received(segment: segment, text: text, isFinal: isFinal, session: current)
        }
        let onFailure: SpeechFailureHandler = { [weak self] problem in
            self?.failed(problem, session: current)
        }
        starting = Task { [weak self] in
            // Overtaken before it began: the feed was never readied, so there is nothing to undo.
            guard let self, self.session == current else { return }
            do {
                let format = try feed.prepare()
                try await backend.start(inputFormat: format, onText: onText, onFailure: onFailure)
                guard self.session == current else {
                    self.retire(feed: feed, backend: backend)
                    return
                }
                try feed.start { buffer in backend.append(buffer) }
            } catch {
                guard self.session == current else {
                    self.retire(feed: feed, backend: backend)
                    return
                }
                VoiceLog.logger.error("Voice couldn't start: \(error, privacy: .public)")
                self.failed(.failed, session: current)
            }
        }
    }

    func stop() {
        session += 1
        starting?.cancel()
        starting = nil
        feed?.stop()
        backend?.stop()
        feed = nil
        backend = nil
        transcript.reset()
    }

    func forgetHeard() {
        transcript.forgetHeard()
    }

    /// A start that a newer start or a stop overtook while it was under way: its recogniser and feed go off, and the
    /// shared audio session is handed back only if no newer feed is using it.
    private func retire(feed: AudioFeed, backend: SpeechBackend) {
        backend.stop()
        feed.stop(releasingSession: self.feed == nil)
    }

    private func makeFeed() -> AudioFeed {
        if let feedFactory { return feedFactory() }
        #if DEBUG
        if let audioFile { return FileFeed(url: audioFile) }
        #endif
        return MicrophoneFeed()
    }

    /// nil: SFSpeechRecognizer isn't available for the locale after all.
    private func makeBackend(for choice: SpeechRecognizerChoice) -> SpeechBackend? {
        if let backendFactory { return backendFactory(choice) }
        switch choice {
        case .analyzer(let locale):
            return AnalyzerBackend(locale: locale, vocabulary: vocabulary)
        case .recognizer(let locale):
            return TaskBackend(locale: locale, vocabulary: vocabulary)
        }
    }

    private func received(segment: Int, text: String, isFinal: Bool, session: Int) {
        guard session == self.session, transcript.update(segment: segment, text: text, isFinal: isFinal) else { return }
        #if DEBUG
        VoiceLog.logger.debug("Heard: \(self.transcript.words.suffix(8).joined(separator: " "), privacy: .public)")
        #endif
        onWords?(transcript.words)
    }

    private func failed(_ problem: VoiceProblem, session: Int) {
        guard session == self.session else { return }
        stop()
        onFailure?(problem)
    }
}
