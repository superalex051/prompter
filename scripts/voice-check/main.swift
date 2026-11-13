// Voice-follow check on the Mac (see scripts/voice-check.sh): streams an audio file in real time through the app's own
// voice code (AnalyzerBackend = SpeechAnalyzer + SpeechTranscriber, AudioConversion, SpeechTranscript, VoiceAligner),
// prints where the reader is after each recogniser update, and records the timed results for `-voiceReplay`.
//
//   voice-check <audio file> <script text file> <results out file>

import AVFoundation
import Foundation

@main
struct VoiceCheck {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else {
            print("usage: voice-check <audio file> <script text file> <results out file>")
            exit(2)
        }
        do {
            try await run(audio: URL(filePath: arguments[1]), script: URL(filePath: arguments[2]), output: URL(filePath: arguments[3]))
        } catch {
            print("FAILED: \(error)")
            exit(1)
        }
    }

    @MainActor
    static func run(audio: URL, script: URL, output: URL) async throws {
        let body = try String(contentsOf: script, encoding: .utf8)
        let document = PrompterDocument(body: body)
        let aligner = VoiceAligner(document: document)
        let wanted = VoiceLocale.preferred(forScript: document.text)
        print("Script: \(aligner.words.count) words; listening for \(wanted.identifier)")

        guard let locale = await SpeechRecognizerChoice.analyzerLocale(for: wanted) else {
            print("FAILED: SpeechTranscriber has no locale for \(wanted.identifier) (available: \(SpeechRecognizerChoice.analyzerIsAvailable))")
            exit(1)
        }
        guard await SpeechRecognizerChoice.ensureAnalyzerModel(for: locale) else {
            print("FAILED: no speech model for \(locale.identifier)")
            exit(1)
        }
        print("SpeechAnalyzer + SpeechTranscriber, \(locale.identifier)")

        let file = try AVAudioFile(forReading: audio)
        let format = file.processingFormat
        let duration = Double(file.length) / format.sampleRate
        let backend = AnalyzerBackend(locale: locale, vocabulary: VoiceVocabulary.words(in: document))

        let clock = ContinuousClock()
        let state = State(aligner: aligner, text: document.text, audioName: audio.lastPathComponent)
        state.started = clock.now

        try await backend.start(
            inputFormat: format,
            onText: { segment, recognized, isFinal in
                state.heard(segment: segment, text: recognized, isFinal: isFinal, seconds: (clock.now - state.started).seconds)
            },
            onFailure: { problem in
                print("FAILED while listening: \(problem)")
            }
        )

        // Real time: 0.1 s buffers, then 3 s of silence.
        let chunk = AVAudioFrameCount(format.sampleRate / 10)
        state.started = clock.now
        let started = state.started
        var sent = 0.0
        while sent < duration + 3 {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
            if file.framePosition < file.length {
                try file.read(into: buffer, frameCount: chunk)
            } else {
                buffer.frameLength = chunk
                for channel in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                    if let data = channel.mData { memset(data, 0, Int(channel.mDataByteSize)) }
                }
            }
            backend.append(buffer)
            sent += Double(buffer.frameLength) / format.sampleRate
            try await clock.sleep(until: started.advanced(by: .seconds(sent)))
        }
        backend.stop()
        try state.lines.joined(separator: "\n").appending("\n").write(to: output, atomically: true, encoding: .utf8)

        let matches = state.matches
        let final = state.aligner.matchedWord
        print("")
        print(String(format: "Audio %.1f s. Matched %d times, last at %.1f s: #%d \"%@\" of %d words.",
                     duration, matches.count, matches.last?.seconds ?? 0, final ?? -1,
                     final.map(state.word) ?? "-", state.aligner.words.count))
        let backwards = zip(matches, matches.dropFirst()).filter { $1.word < $0.word }.count
        print("Backward moves: \(backwards)")
        print("Results for -voiceReplay: \(output.path(percentEncoded: false))")
    }
}

/// What the harness has heard and matched (the recogniser reports on the main actor).
@MainActor
final class State {
    var aligner: VoiceAligner
    var transcript = SpeechTranscript()
    var lines: [String]
    var matches: [(seconds: Double, word: Int)] = []
    var started = ContinuousClock().now
    private let text: NSString

    init(aligner: VoiceAligner, text: String, audioName: String) {
        self.aligner = aligner
        self.text = text as NSString
        lines = ["# Recorded by scripts/voice-check.sh: SpeechAnalyzer results for \(audioName)"]
    }

    func word(_ index: Int) -> String {
        let range = aligner.words[index].range
        return text.substring(with: NSRange(location: range.lowerBound, length: range.count))
    }

    func heard(segment: Int, text recognized: String, isFinal: Bool, seconds: Double) {
        lines.append(String(format: "%.2f|%@|%@", seconds, isFinal ? "F" : "v", recognized))
        guard transcript.update(segment: segment, text: recognized, isFinal: isFinal) else { return }
        let before = aligner.matchedWord
        _ = aligner.advance(with: transcript.words)
        let tail = transcript.words.suffix(6).joined(separator: " ")
        if let now = aligner.matchedWord, now != before {
            matches.append((seconds, now))
            print(String(format: "%6.2f s  …%@  →  #%d \"%@\"", seconds, tail, now, word(now)))
        }
    }
}

extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
