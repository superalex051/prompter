#if DEBUG
import Foundation

/// Debug builds (`-voiceReplay`): instead of listening, replays a speech recogniser's recorded results at the times they
/// were recorded, through the same transcript bookkeeping `LiveSpeechSource` uses. The simulator has no working speech
/// recogniser, so this is how it shows the prompter following a real read-through. scripts/voice-check.sh records the
/// file on the Mac by streaming an audio file through the app's own SpeechAnalyzer code.
///
/// File: one result per line, `seconds|v|text` (volatile) or `seconds|F|text` (final, which ends a segment), seconds
/// counted from when listening started. Lines starting with `#` are comments.
@MainActor
final class ReplaySpeechSource: SpeechSource {
    struct Result: Equatable, Sendable {
        var seconds: Double
        var isFinal: Bool
        var text: String
    }

    var onWords: (([String]) -> Void)?
    var onFailure: ((VoiceProblem) -> Void)?

    private let url: URL
    private var results: [Result] = []
    private var transcript = SpeechTranscript()
    private var task: Task<Void, Never>?

    init(url: URL) {
        self.url = url
    }

    static func parse(_ text: String) -> [Result] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard !line.hasPrefix("#") else { return nil }
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let seconds = Double(parts[0]), parts[1] == "v" || parts[1] == "F" else { return nil }
            return Result(seconds: seconds, isFinal: parts[1] == "F", text: String(parts[2]))
        }
    }

    func prepare() async -> VoiceProblem? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            VoiceLog.logger.error("No voice replay at \(self.url.path(), privacy: .public)")
            return .unsupported
        }
        results = Self.parse(text)
        VoiceLog.logger.info("Voice ready: replaying \(self.results.count) recorded results")
        return results.isEmpty ? .unsupported : nil
    }

    func start() {
        stop()
        VoiceLog.logger.info("Listening (replay)")
        let results = self.results
        task = Task { [weak self] in
            let clock = ContinuousClock()
            let start = clock.now
            var segment = 0
            for result in results {
                try? await clock.sleep(until: start.advanced(by: .seconds(result.seconds)))
                guard !Task.isCancelled, let self else { return }
                if self.transcript.update(segment: segment, text: result.text, isFinal: result.isFinal) {
                    VoiceLog.logger.debug("Heard: \(self.transcript.words.suffix(8).joined(separator: " "), privacy: .public)")
                    self.onWords?(self.transcript.words)
                }
                if result.isFinal { segment += 1 }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        transcript.reset()
    }

    func forgetHeard() {
        transcript.forgetHeard()
    }
}
#endif
