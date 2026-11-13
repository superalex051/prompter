import Foundation

/// How long a script takes to read: the words on its text lines and the seconds of its timed `[pause N]` cues.
/// Notes (`// …`) and cue lines are not words (see `ScriptMarkup`). With Markdown on, the words are the ones the prompter
/// shows (no `**`, `#` or link addresses), and headings and rules are not words either.
struct ReadingStats: Equatable, Sendable {
    /// Words on text lines only.
    let wordCount: Int
    /// The total of every `[pause N]` cue (the prompter holds that long at each one).
    let holdSeconds: Double

    /// `markdown`: count as the prompter shows the script with Settings → Markdown formatting on (the same words as
    /// `PrompterDocument(body:markdown:).timedWordCount`).
    init(text: String, markdown: Bool = false) {
        var words = 0
        var holds = 0
        for line in ScriptMarkup.lines(of: text, markdown: markdown) {
            switch line.kind {
            case .text:
                words += markdown
                    ? Self.wordCount(of: ScriptMarkdown.parse(text[line.range]).text)
                    : Self.wordCount(of: text[line.range])
            case .pause(let seconds?): holds += seconds
            case .note, .pause(.none), .heading, .rule: break
            }
        }
        wordCount = words
        holdSeconds = Double(holds)
    }

    /// A word = a whitespace-separated token containing at least one letter or digit ("—", "-", "•" don't count).
    /// Counts every token in `text`, markup or not; `init(text:)` applies the markup.
    static func wordCount(of text: some StringProtocol) -> Int {
        var count = 0
        var tokenHasLetterOrDigit = false
        for scalar in text.unicodeScalars {
            let properties = scalar.properties
            if properties.isWhitespace {
                if tokenHasLetterOrDigit { count += 1 }
                tokenHasLetterOrDigit = false
            } else if !tokenHasLetterOrDigit, properties.isAlphabetic || properties.numericType != nil {
                tokenHasLetterOrDigit = true
            }
        }
        return tokenHasLetterOrDigit ? count + 1 : count
    }

    /// wordCount / wpm * 60, plus the timed pauses (the prompter holds at those, so a take really lasts that long).
    /// wpm <= 0 or non-finite → 0.
    func readingSeconds(atWPM wpm: Double) -> Double {
        guard wpm.isFinite, wpm > 0 else { return 0 }
        return Double(wordCount) / wpm * 60 + holdSeconds
    }
}
