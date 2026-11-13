import Foundation

/// Follows a reader through the script from what the speech recogniser hears. Pure and synchronous.
///
/// The script side is every word on the timed text lines (notes and `[pause]` cues are never read, so they are not
/// here), each with its UTF-16 range in the prompter text, broken into normalised tokens (`VoiceText`). The cursor is the
/// last token the reader has been heard saying.
///
/// `advance(with:)` takes the words heard so far (the recogniser keeps revising the last few) and aligns the newest
/// `tailLength` tokens against a window of the script around the cursor, `windowBehind` tokens back to `windowAhead`
/// tokens ahead, with a local alignment (Smith–Waterman): a fuzzy match scores the script token's weight (common little
/// words count for less), a wrong word, a word that isn't in the script (an ad-lib, a filler, a half-heard fragment) and
/// a script word that wasn't heard each cost a little. The best alignment that reaches the newest heard words wins.
///
/// When to move (`Rules`):
/// - **Nothing new:** the same tail as last time, or the newest two heard tokens didn't match anything → nil, the cursor
///   stays (an ad-lib holds the text still).
/// - **Forward, reading on:** the new match follows straight on from text already read in the same alignment (no stray
///   heard word in between, at most one script word missed): accepted, however small the word ("the", "a").
/// - **Forward, close by** (at most `nearSkip` script tokens unheard before the new match): accepted when the new part
///   carries at least one ordinary word's weight, so a lone "a" after an ad-lib doesn't move the text.
/// - **Forward, far** (a skipped sentence or paragraph, up to the window): at least `farMatches` heard tokens matched ahead,
///   weighing at least `farWeight`, the last two of them in a row. So one common word ahead never drags the text away.
/// - **Backward:** never, unless the newest `backRun` tokens match the script in a row (with at least one ordinary word)
///   further back, and the next update agrees. So repeating a word never jumps back, a recogniser taking back its last
///   words for a moment doesn't either, but re-reading a phrase does.
struct VoiceAligner: Sendable {
    /// A script word: its UTF-16 range in the prompter text.
    struct Word: Equatable, Sendable {
        var range: Range<Int>
    }

    /// A normalised token of a script word.
    struct Token: Equatable, Sendable {
        var text: String
        /// Index into `words`.
        var word: Int
        var weight: Double
    }

    /// Tuning, in tokens and score units. The defaults are what the app uses.
    struct Rules: Equatable, Sendable {
        var tailLength = 6
        var windowBehind = 5
        var windowAhead = 60
        /// A script token that wasn't heard (skipped, or missed by the recogniser).
        var skipPenalty = 0.4
        /// A heard token that isn't in the script here (ad-lib, filler, fragment).
        var insertionPenalty = 0.5
        /// A heard token aligned to a different script token.
        var mismatchPenalty = 0.6
        /// Up to this many unheard script tokens before a forward match still counts as "close by".
        var nearSkip = 3
        var nearWeight = 1.0
        var farMatches = 3
        var farWeight = 2.0
        var backRun = 3
        var backWeight = 1.5
    }

    let words: [Word]
    let tokens: [Token]
    let rules: Rules
    /// Index into `tokens` of the last token the reader was heard saying; -1 before the first.
    private(set) var cursor = -1
    /// The tail aligned last time; the same tail again means nothing new was heard.
    private var lastTail: [String] = []
    /// A backward move that one update asked for; it happens if the next one agrees.
    private var pendingBack: Int?

    /// The timed words of a prompter document (text paragraphs only), with their offsets in `document.text`.
    init(document: PrompterDocument, rules: Rules = Rules()) {
        var words: [Word] = []
        var offset = 0
        var wordTexts: [String] = []
        for paragraph in document.paragraphs {
            if paragraph.kind == .text {
                for (range, text) in Self.wordRanges(in: paragraph.text) {
                    words.append(Word(range: (offset + range.lowerBound)..<(offset + range.upperBound)))
                    wordTexts.append(text)
                }
            }
            offset += paragraph.text.utf16.count + 1
        }
        self.init(words: words, texts: wordTexts, rules: rules)
    }

    /// All of `text` as timed script (for tests and tools).
    init(text: String, rules: Rules = Rules()) {
        let pairs = Self.wordRanges(in: text)
        self.init(words: pairs.map { Word(range: $0.0) }, texts: pairs.map(\.1), rules: rules)
    }

    private init(words: [Word], texts: [String], rules: Rules) {
        self.words = words
        self.rules = rules
        var tokens: [Token] = []
        for (index, text) in texts.enumerated() {
            for token in VoiceText.tokens(of: text) {
                tokens.append(Token(text: token, word: index, weight: VoiceText.weight(of: token)))
            }
        }
        self.tokens = tokens
    }

    // MARK: Position

    /// The script word the reader was last heard saying; nil before the first.
    var matchedWord: Int? {
        cursor >= 0 && cursor < tokens.count ? tokens[cursor].word : nil
    }

    /// The word to read next: the one after `matchedWord` (the first word before anything was heard); nil once the
    /// last word has been heard.
    var nextWord: Int? {
        guard !tokens.isEmpty else { return nil }
        let next = (matchedWord ?? -1) + 1
        return next < words.count ? next : nil
    }

    /// The reader was heard saying the last word of the script.
    var isAtEnd: Bool {
        !tokens.isEmpty && cursor == tokens.count - 1
    }

    /// The text was moved by hand (a step, a drag, back to top): everything before the character at `index` counts as
    /// read, nothing after it. Forgets the last tail, so the next words heard are aligned afresh.
    mutating func resync(toCharacterIndex index: Int) {
        cursor = (tokens.lastIndex { words[$0.word].range.lowerBound < index }) ?? -1
        lastTail = []
        pendingBack = nil
    }

    // MARK: Following

    /// Aligns the newest heard words (`recognizedWords`: everything heard so far, newest last, as the recogniser
    /// currently has it) and moves the cursor if the rules allow. Returns the index into `words` of the word the reader
    /// is now at, or nil when this gives no confident new match (see the type's notes).
    mutating func advance(with recognizedWords: [String]) -> Int? {
        guard !tokens.isEmpty else { return nil }
        var tail: [String] = []
        for word in recognizedWords.reversed() {
            tail.insert(contentsOf: VoiceText.tokens(of: word), at: 0)
            if tail.count >= rules.tailLength { break }
        }
        tail = Array(tail.suffix(rules.tailLength))
        guard !tail.isEmpty, tail != lastTail else { return nil }
        lastTail = tail

        guard let alignment = bestAlignment(of: tail),
              let last = alignment.matches.last,
              last.heard >= tail.count - 2
        else { return nil }

        let target = last.script
        if target < cursor {
            guard acceptsBackward(alignment) else { return nil }
            guard let pending = pendingBack, target >= pending else {
                pendingBack = target
                return nil
            }
        } else if target > cursor {
            guard acceptsForward(alignment) else { return nil }
        }
        pendingBack = nil
        cursor = target
        return tokens[cursor].word
    }

    // MARK: Alignment

    struct Pair: Equatable {
        /// Index into the heard tail.
        var heard: Int
        /// Index into `tokens`.
        var script: Int
    }

    struct Alignment {
        var score: Double
        /// Matched pairs, oldest first.
        var matches: [Pair]
    }

    /// The best local alignment of `tail` within the window that reaches the newest heard token (matched, or passed over
    /// as an insertion). Ties go to the end nearest the token after the cursor.
    private func bestAlignment(of tail: [String]) -> Alignment? {
        let low = max(0, cursor - rules.windowBehind)
        let high = min(tokens.count - 1, cursor + rules.windowAhead)
        guard low <= high else { return nil }
        let rows = tail.count
        let columns = high - low + 1

        enum Step: UInt8 { case start, match, mismatch, insertion, skip }
        var score = [Double](repeating: 0, count: (rows + 1) * (columns + 1))
        var step = [Step](repeating: .start, count: (rows + 1) * (columns + 1))
        func cell(_ i: Int, _ j: Int) -> Int { i * (columns + 1) + j }

        for i in 1...rows {
            for j in 1...columns {
                let token = tokens[low + j - 1]
                let isMatch = VoiceText.matches(tail[i - 1], token.text)
                var best = 0.0
                var bestStep = Step.start
                let diagonal = score[cell(i - 1, j - 1)] + (isMatch ? token.weight : -rules.mismatchPenalty)
                if diagonal > best { best = diagonal; bestStep = isMatch ? .match : .mismatch }
                let insertion = score[cell(i - 1, j)] - rules.insertionPenalty
                if insertion > best { best = insertion; bestStep = .insertion }
                let skip = score[cell(i, j - 1)] - rules.skipPenalty
                if skip > best { best = skip; bestStep = .skip }
                score[cell(i, j)] = best
                step[cell(i, j)] = bestStep
            }
        }

        let expected = cursor + 1
        var bestColumn: Int?
        for j in 1...columns where score[cell(rows, j)] > 0 {
            guard let current = bestColumn else { bestColumn = j; continue }
            let candidate = score[cell(rows, j)]
            let incumbent = score[cell(rows, current)]
            if candidate > incumbent + 1e-9
                || (abs(candidate - incumbent) <= 1e-9 && abs(low + j - 1 - expected) < abs(low + current - 1 - expected)) {
                bestColumn = j
            }
        }
        guard let endColumn = bestColumn else { return nil }

        var matches: [Pair] = []
        var i = rows
        var j = endColumn
        while i > 0, j > 0, score[cell(i, j)] > 0 {
            switch step[cell(i, j)] {
            case .match:
                matches.append(Pair(heard: i - 1, script: low + j - 1))
                i -= 1
                j -= 1
            case .mismatch:
                i -= 1
                j -= 1
            case .insertion:
                i -= 1
            case .skip:
                j -= 1
            case .start:
                i = 0
            }
        }
        return Alignment(score: score[cell(rows, endColumn)], matches: matches.reversed())
    }

    private func acceptsForward(_ alignment: Alignment) -> Bool {
        guard let firstAhead = alignment.matches.firstIndex(where: { $0.script > cursor }) else { return false }
        let ahead = alignment.matches[firstAhead...]
        let first = alignment.matches[firstAhead]
        if firstAhead > 0 {
            let read = alignment.matches[firstAhead - 1]
            if first.heard == read.heard + 1, first.script - read.script <= 2 { return true }
        }
        let skipped = first.script - cursor - 1
        let weight = ahead.reduce(0) { $0 + tokens[$1.script].weight }
        if skipped <= rules.nearSkip {
            return weight >= rules.nearWeight - 1e-9
        }
        return ahead.count >= rules.farMatches
            && weight >= rules.farWeight - 1e-9
            && trailingRun(alignment.matches) >= 2
    }

    private func acceptsBackward(_ alignment: Alignment) -> Bool {
        let run = trailingRun(alignment.matches)
        guard run >= rules.backRun else { return false }
        let weight = alignment.matches.suffix(run).reduce(0) { $0 + tokens[$1.script].weight }
        return weight >= rules.backWeight - 1e-9
    }

    /// How many of the last matches are consecutive in both the heard tail and the script.
    private func trailingRun(_ matches: [Pair]) -> Int {
        guard var previous = matches.last else { return 0 }
        var run = 1
        for pair in matches.dropLast().reversed() {
            guard pair.heard == previous.heard - 1, pair.script == previous.script - 1 else { break }
            run += 1
            previous = pair
        }
        return run
    }

    // MARK: Script words

    /// Whitespace-separated runs that contain a letter or digit (the same words `ReadingStats` counts), with their
    /// UTF-16 ranges in `text`.
    static func wordRanges(in text: String) -> [(Range<Int>, String)] {
        var result: [(Range<Int>, String)] = []
        var offset = 0
        var start: Int?
        var current = ""
        var hasLetterOrDigit = false
        func flush(at end: Int) {
            if let start, hasLetterOrDigit { result.append((start..<end, current)) }
            start = nil
            current = ""
            hasLetterOrDigit = false
        }
        for scalar in text.unicodeScalars {
            let properties = scalar.properties
            if properties.isWhitespace {
                flush(at: offset)
            } else {
                if start == nil { start = offset }
                current.unicodeScalars.append(scalar)
                if properties.isAlphabetic || properties.numericType != nil { hasLetterOrDigit = true }
            }
            offset += scalar.utf16.count
        }
        flush(at: offset)
        return result
    }
}
