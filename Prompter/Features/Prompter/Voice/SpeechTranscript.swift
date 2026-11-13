import Foundation

/// The words heard in one listening session, as a recogniser reports and keeps revising them. Pure.
///
/// Recognisers report in segments: a segment's text is replaced again and again while it is still being heard (partial
/// or "volatile" results, whose last words change), then settles once (a final result). The next segment continues
/// after it. SpeechAnalyzer numbers its segments one after another; SFSpeechRecognizer gets a fresh segment per
/// recognition task, and an old task's final text may arrive after the new task has started, which is why segments are
/// kept by number rather than as one running string.
///
/// Only the newest `keptWords` or so are kept: the aligner looks at the last few anyway. `forgetHeard()` hides everything
/// heard so far (the text was moved by hand, so those words no longer say where the reader is).
struct SpeechTranscript: Equatable, Sendable {
    static let keptWords = 40

    private struct Segment: Equatable, Sendable {
        var id: Int
        var words: [String]
        var isFinal: Bool
    }

    /// id ascending.
    private var segments: [Segment] = []
    /// How many words pruning has dropped from the front, and how many (counted the same way) `forgetHeard()` hid.
    private var dropped = 0
    private var forgotten = 0

    /// Every kept word heard since the last `forgetHeard()`, oldest first.
    var words: [String] {
        let all = segments.flatMap(\.words)
        return Array(all.dropFirst(max(forgotten - dropped, 0)))
    }

    var isEmpty: Bool {
        words.isEmpty
    }

    /// Everything heard so far stops counting; only words that come after it are reported.
    mutating func forgetHeard() {
        forgotten = dropped + segments.reduce(0) { $0 + $1.words.count }
    }

    /// Replaces segment `id` with `text` (split on whitespace). A final segment is never changed again (a late partial for
    /// it is ignored). Returns true if the words changed.
    @discardableResult
    mutating func update(segment id: Int, text: String, isFinal: Bool) -> Bool {
        let before = words
        let newWords = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if let index = segments.firstIndex(where: { $0.id == id }) {
            guard !segments[index].isFinal else { return false }
            segments[index] = Segment(id: id, words: newWords, isFinal: isFinal)
        } else {
            let index = segments.firstIndex { $0.id > id } ?? segments.endIndex
            segments.insert(Segment(id: id, words: newWords, isFinal: isFinal), at: index)
        }
        prune()
        return words != before
    }

    mutating func reset() {
        segments = []
        dropped = 0
        forgotten = 0
    }

    /// Drops the oldest final segments while the others still hold `keptWords`.
    private mutating func prune() {
        var total = segments.reduce(0) { $0 + $1.words.count }
        while let first = segments.first, first.isFinal, segments.count > 1, total - first.words.count >= Self.keptWords {
            total -= first.words.count
            dropped += first.words.count
            segments.removeFirst()
        }
    }
}
