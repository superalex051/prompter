import AVFoundation
import os
import Speech

/// The on-device recogniser voice-follow uses, picked per script language when a prompter opens.
///
/// 1. **SpeechAnalyzer + SpeechTranscriber** (iOS 26): always on-device, built for long-form audio (no task limits to
///    restart around), and with `.volatileResults` + `.fastResults` it revises the words in progress about once a
///    second with no backlog. Needs no speech-recognition permission. Its model is a system asset: usually already on the
///    device, otherwise downloaded once (`AssetInventory`).
/// 2. **SFSpeechRecognizer** with `requiresOnDeviceRecognition`, when SpeechTranscriber isn't available (it isn't on the
///    simulator, on older hardware, or for some languages) or its model can't be downloaded. Needs the speech-recognition
///    permission. Tasks end after silences and are limited in length, so `TaskBackend` restarts them.
enum SpeechRecognizerChoice: Equatable, Sendable {
    case analyzer(Locale)
    case recognizer(Locale)

    static var analyzerIsAvailable: Bool { SpeechTranscriber.isAvailable }

    /// Some language has an on-device SFSpeechRecognizer here.
    static var taskRecognizerIsAvailable: Bool {
        SFSpeechRecognizer.supportedLocales().contains { SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true }
    }

    /// SpeechTranscriber's locale for `wanted`, if it has one here.
    static func analyzerLocale(for wanted: Locale) async -> Locale? {
        guard SpeechTranscriber.isAvailable else { return nil }
        if let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) { return equivalent }
        return VoiceLocale.best(for: wanted, among: await SpeechTranscriber.supportedLocales)
    }

    /// An SFSpeechRecognizer locale for `wanted` that recognises on the device, if any.
    static func recognizerLocale(for wanted: Locale) -> Locale? {
        let candidates = SFSpeechRecognizer.supportedLocales().filter {
            SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true
        }
        return VoiceLocale.best(for: wanted, among: Array(candidates))
    }

    /// Makes sure SpeechTranscriber's model for `locale` is on the device, downloading it if needed. False if it can't be.
    static func ensureAnalyzerModel(for locale: Locale) async -> Bool {
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                VoiceLog.logger.info("Downloading the speech model for \(locale.identifier, privacy: .public)")
                try await request.downloadAndInstall()
            }
            return true
        } catch {
            VoiceLog.logger.error("Speech model for \(locale.identifier, privacy: .public) unavailable: \(error, privacy: .public)")
            return false
        }
    }
}

enum VoiceLog {
    static let logger = Logger(subsystem: LogSubsystem.current, category: "voice")
}

/// Text from a recogniser: segment number (see `SpeechTranscript`), the segment's words so far, and whether they are
/// final. Always delivered on the main actor.
typealias SpeechTextHandler = @MainActor @Sendable (_ segment: Int, _ text: String, _ isFinal: Bool) -> Void
typealias SpeechFailureHandler = @MainActor @Sendable (VoiceProblem) -> Void

/// One recogniser session: takes audio buffers on the audio thread, reports text on the main actor.
protocol SpeechBackend: AnyObject, Sendable {
    /// Gets ready for audio in `inputFormat`; buffers may be appended once this returns.
    func start(inputFormat: AVAudioFormat, onText: @escaping SpeechTextHandler, onFailure: @escaping SpeechFailureHandler) async throws
    /// Called on the audio thread with each buffer from the microphone (or file).
    func append(_ buffer: AVAudioPCMBuffer)
    func stop()
}

enum SpeechBackendError: Error {
    case noCompatibleFormat
    case recognizerUnavailable
}

// MARK: - SpeechAnalyzer

/// SpeechAnalyzer with a SpeechTranscriber reporting volatile (in-progress) and fast results. Audio is converted to the
/// transcriber's format on the audio thread and streamed in; results come back segment by segment: volatile ones for the
/// current segment, then its final, then the next segment.
final class AnalyzerBackend: SpeechBackend, @unchecked Sendable {
    private let locale: Locale
    private let vocabulary: [String]
    /// Guards everything below (the audio thread appends while the main actor may stop).
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var isStopped = false

    init(locale: Locale, vocabulary: [String]) {
        self.locale = locale
        self.vocabulary = vocabulary
    }

    func start(inputFormat: AVAudioFormat, onText: @escaping SpeechTextHandler, onFailure: @escaping SpeechFailureHandler) async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        )
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: inputFormat)
        else { throw SpeechBackendError.noCompatibleFormat }
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try? await analyzer.setContext(context)
        }
        try await analyzer.prepareToAnalyze(in: format)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let results = Task {
            var segment = 0
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let isFinal = result.isFinal
                    let current = segment
                    if isFinal { segment += 1 }
                    await onText(current, text, isFinal)
                }
            } catch {
                guard !Task.isCancelled else { return }
                VoiceLog.logger.error("Transcriber failed: \(error, privacy: .public)")
                await onFailure(.failed)
            }
        }
        let stoppedMeanwhile = lock.withLock {
            guard !isStopped else { return true }
            converter = format == inputFormat ? nil : AVAudioConverter(from: inputFormat, to: format)
            outputFormat = format
            self.continuation = continuation
            self.analyzer = analyzer
            resultsTask = results
            return false
        }
        if stoppedMeanwhile {
            results.cancel()
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            return
        }
        try await analyzer.start(inputSequence: stream)
        VoiceLog.logger.info("Listening with SpeechAnalyzer (\(self.locale.identifier, privacy: .public), \(format, privacy: .public))")
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !isStopped, let continuation, let outputFormat else { return }
            let input: AVAudioPCMBuffer?
            if let converter {
                input = AudioConversion.convert(buffer, with: converter, to: outputFormat)
            } else {
                input = AudioConversion.copy(buffer)
            }
            if let input { continuation.yield(AnalyzerInput(buffer: input)) }
        }
    }

    func stop() {
        let analyzer: SpeechAnalyzer? = lock.withLock {
            isStopped = true
            continuation?.finish()
            continuation = nil
            resultsTask?.cancel()
            resultsTask = nil
            let analyzer = self.analyzer
            self.analyzer = nil
            return analyzer
        }
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}

// MARK: - SFSpeechRecognizer

/// SFSpeechRecognizer recognising on the device from a buffer request, one task after another: a task that ends (after a
/// pause the recogniser takes as the end of speech, or an error) is replaced at once, and a long one is replaced before
/// the recogniser's own length limit. Each task is its own transcript segment.
final class TaskBackend: SpeechBackend, @unchecked Sendable {
    /// Start a fresh task once one has run this long (seconds).
    static let maximumTaskSeconds = 50.0
    /// This many tasks in a row failing within a second of starting means it can't work.
    static let failuresBeforeGivingUp = 5

    private let recognizer: SFSpeechRecognizer
    private let vocabulary: [String]
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var taskNumber = 0
    private var taskStarted = Date()
    private var quickFailures = 0
    private var isStopped = false
    private var onText: SpeechTextHandler?
    private var onFailure: SpeechFailureHandler?

    init?(locale: Locale, vocabulary: [String]) {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return nil }
        self.recognizer = recognizer
        self.vocabulary = Array(vocabulary.prefix(100))
    }

    func start(inputFormat: AVAudioFormat, onText: @escaping SpeechTextHandler, onFailure: @escaping SpeechFailureHandler) async throws {
        guard recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw SpeechBackendError.recognizerUnavailable
        }
        lock.withLock {
            self.onText = onText
            self.onFailure = onFailure
            guard !isStopped else { return }
            startTask()
        }
        VoiceLog.logger.info("Listening with SFSpeechRecognizer (\(self.recognizer.locale.identifier, privacy: .public), on device)")
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !isStopped else { return }
            if Date().timeIntervalSince(taskStarted) > Self.maximumTaskSeconds {
                request?.endAudio()
                startTask()
            }
            request?.append(buffer)
        }
    }

    func stop() {
        lock.withLock {
            isStopped = true
            request?.endAudio()
            task?.cancel()
            request = nil
            task = nil
        }
    }

    /// Call with the lock held.
    private func startTask() {
        taskNumber += 1
        let number = taskNumber
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        request.addsPunctuation = false
        request.contextualStrings = vocabulary
        self.request = request
        taskStarted = Date()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            self?.handle(number: number, text: text, isFinal: isFinal, error: error)
        }
    }

    private func handle(number: Int, text: String?, isFinal: Bool, error: (any Error)?) {
        let (onText, onFailure, giveUp): (SpeechTextHandler?, SpeechFailureHandler?, Bool) = lock.withLock {
            guard !isStopped else { return (nil, nil, false) }
            var giveUp = false
            if number == taskNumber, isFinal || error != nil {
                // The task ended: carry on with a new one, unless they keep failing straight away.
                if error != nil, text == nil, Date().timeIntervalSince(taskStarted) < 1 {
                    quickFailures += 1
                } else {
                    quickFailures = 0
                }
                if quickFailures >= Self.failuresBeforeGivingUp {
                    isStopped = true
                    giveUp = true
                } else {
                    startTask()
                }
            }
            return (self.onText, self.onFailure, giveUp)
        }
        if let text, let onText {
            Task { @MainActor in onText(number, text, isFinal) }
        }
        if giveUp, let onFailure {
            VoiceLog.logger.error("Recognition keeps failing: \(String(describing: error), privacy: .public)")
            Task { @MainActor in onFailure(.failed) }
        }
    }
}

// MARK: - Audio conversion

enum AudioConversion {
    /// `buffer` converted to `format` by a streaming converter (its state carries over between calls).
    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    /// A copy of `buffer` (an engine may reuse a tap's buffer once the tap returns).
    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let fromData = from.mData, let toData = to.mData else { continue }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }
}
