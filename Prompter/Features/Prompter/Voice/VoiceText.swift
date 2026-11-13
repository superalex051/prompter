import Foundation

/// How voice-follow compares what was said with what is written: both sides are turned into the same normalised tokens,
/// then compared loosely. Pure; English rules for numbers, contractions and common words (other languages still work,
/// they just get no number spelling and every word counts the same).
///
/// - Lowercased, accents and full-width forms folded ("Café" → "cafe"), curly apostrophes made straight.
/// - Punctuation dropped; hyphens, slashes and dashes split words ("forty-five" → "forty", "five").
/// - Digits spelled out, so "45", "forty-five" and "forty five" all become "forty", "five": "1,000" → "one thousand",
///   "2.5" → "two point five", "9:41" → "nine forty one", "3rd" → "third", "a7c" → "a", "seven", "c".
/// - Contractions expanded, so "don't" and "do not" agree: "won't" → "will not", "it's" → "it is", "we'll" → "we will".
///   A possessive keeps its letters ("Sam's" → "sams").
enum VoiceText {
    /// The tokens of a whole text: split on whitespace, then `tokens(of:)` for each piece.
    static func tokens(ofText text: some StringProtocol) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).flatMap { tokens(of: $0) }
    }

    /// The tokens of one written or recognised word (whitespace-free): none for pure punctuation, several for compounds,
    /// numbers and contractions.
    static func tokens(of word: some StringProtocol) -> [String] {
        let folded = String(word)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: posix)
            .lowercased()
        var result: [String] = []
        for piece in pieces(of: folded) {
            result.append(contentsOf: tokens(ofPiece: piece))
        }
        return result
    }

    // MARK: Comparing

    /// True when two tokens are the same word as far as following the script goes: equal, or (both at least 4 letters
    /// long) at most a quarter of their letters different ("memorising"/"memorizing", "samuels"/"samuel").
    static func matches(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let a = Array(a.unicodeScalars)
        let b = Array(b.unicodeScalars)
        guard min(a.count, b.count) >= 4 else { return false }
        let longest = max(a.count, b.count)
        // Cheap reject: the length difference alone is already too many edits.
        guard Double(longest - min(a.count, b.count)) <= Double(longest) * (1 - similarityThreshold) else { return false }
        return 1 - Double(editDistance(a, b)) / Double(longest) >= similarityThreshold
    }

    /// 1 − edit distance / longer length; 1 for two empty strings.
    static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a.unicodeScalars)
        let b = Array(b.unicodeScalars)
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 1 }
        return 1 - Double(editDistance(a, b)) / Double(longest)
    }

    /// The fuzzy-match bar: 1 edit in 4 letters, 2 in 8.
    static let similarityThreshold = 0.75

    /// How much a matched token tells about where the reader is: little for the common little words that occur
    /// everywhere ("the", "and", "it"), 1 for everything else.
    static func weight(of token: String) -> Double {
        commonWords.contains(token) ? commonWordWeight : 1
    }

    static let commonWordWeight = 0.35

    // MARK: Numbers

    /// "forty five" style words for a whole number (no "and"); digit by digit beyond the millions.
    static func numberWords(_ value: Int) -> [String] {
        guard value >= 0 else {
            // Negating Int.min traps; it is far past the millions anyway, so it goes digit by digit.
            return ["minus"] + (value == .min ? digitWords(String(value.magnitude)) : numberWords(-value))
        }
        guard value < 1_000_000_000 else { return digitWords(String(value)) }
        if value < 20 { return [ones[value]] }
        if value < 100 {
            let rest = value % 10
            return [tens[value / 10]] + (rest > 0 ? [ones[rest]] : [])
        }
        if value < 1_000 {
            let rest = value % 100
            return [ones[value / 100], "hundred"] + (rest > 0 ? numberWords(rest) : [])
        }
        if value < 1_000_000 {
            let rest = value % 1_000
            return numberWords(value / 1_000) + ["thousand"] + (rest > 0 ? numberWords(rest) : [])
        }
        let rest = value % 1_000_000
        return numberWords(value / 1_000_000) + ["million"] + (rest > 0 ? numberWords(rest) : [])
    }

    /// "twenty first" style words for an ordinal.
    static func ordinalWords(_ value: Int) -> [String] {
        var words = numberWords(value)
        guard let last = words.popLast() else { return [] }
        let ordinal: String = switch last {
        case "one": "first"
        case "two": "second"
        case "three": "third"
        case "five": "fifth"
        case "eight": "eighth"
        case "nine": "ninth"
        case "twelve": "twelfth"
        default: last.hasSuffix("y") ? String(last.dropLast()) + "ieth" : last + "th"
        }
        return words + [ordinal]
    }

    /// The value of a decimal digit 0…9 in any script ("7", "٧", "७"), or nil. Other characters Unicode calls numbers
    /// aren't digits here: "万" (10 000), "⑳" (20), "½" have no single digit's word, so they stay part of a word.
    static func digitValue(_ character: Character) -> Int? {
        guard let value = character.wholeNumberValue, (0...9).contains(value) else { return nil }
        return value
    }

    // MARK: Private

    private static let posix = Locale(identifier: "en_US_POSIX")

    private static func isDigit(_ character: Character) -> Bool {
        digitValue(character) != nil
    }

    /// "zero", "one", … for each decimal digit in `text` (anything else is skipped).
    private static func digitWords(_ text: some StringProtocol) -> [String] {
        text.compactMap { digitValue($0).map { ones[$0] } }
    }

    private static let ones = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
    ]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    private static let commonWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "if", "to", "of", "in", "on", "at", "by", "for", "with", "from",
        "up", "as", "it", "its", "is", "are", "was", "be", "i", "you", "he", "she", "we", "they", "me", "my", "your",
        "our", "this", "that", "do", "not", "will", "would", "have", "has", "had", "am", "just", "all", "can", "there",
        "here", "what", "um", "uh",
    ]

    /// "'s" after these is "is" (or "us" after "let"); after anything else it is a possessive.
    private static let isContractions: Set<String> = [
        "it", "that", "there", "here", "what", "who", "he", "she", "where", "how", "when", "why", "this",
    ]

    /// Splits a folded word into pieces of letters, digits and apostrophes. "." "," and ":" stay only between two
    /// digits (2.5, 1,000, 9:41); every other character separates pieces. "&" and "%" become words of their own.
    private static func pieces(of text: String) -> [String] {
        let characters = Array(text)
        var pieces: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { pieces.append(current) }
            current = ""
        }
        for (index, character) in characters.enumerated() {
            if character.isLetter || character.isNumber || character == "'" {
                current.append(character)
            } else if character == "’" || character == "‘" || character == "ʼ" {
                current.append("'")
            } else if character == "." || character == "," || character == ":",
                      index > 0, isDigit(characters[index - 1]),
                      index + 1 < characters.count, isDigit(characters[index + 1]) {
                current.append(character)
            } else {
                flush()
                if character == "&" { pieces.append("and") }
                if character == "%" { pieces.append("percent") }
            }
        }
        flush()
        return pieces
    }

    private static func tokens(ofPiece piece: String) -> [String] {
        var piece = Substring(piece)
        while piece.first == "'" { piece = piece.dropFirst() }
        while piece.last == "'" { piece = piece.dropLast() }
        guard !piece.isEmpty else { return [] }
        if piece.contains(where: isDigit) {
            return numberTokens(String(piece))
        }
        return contractionTokens(String(piece))
    }

    /// A piece with digits in it: numbers spelled out, everything else around them (letters, and number characters that
    /// aren't digits 0…9, like "万" or "⑳") kept as tokens of their own.
    private static func numberTokens(_ piece: String) -> [String] {
        // An ordinal: digits then st/nd/rd/th.
        for suffix in ["st", "nd", "rd", "th"] where piece.hasSuffix(suffix) {
            let digits = piece.dropLast(2)
            if !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(digits) {
                return ordinalWords(value)
            }
        }
        // A clock time or other colon-joined numbers: each part on its own ("9:41" → nine forty one).
        if piece.contains(":") {
            return piece.split(separator: ":").flatMap { numberTokens(String($0)) }
        }
        // Runs of letters and runs of number characters.
        var tokens: [String] = []
        var run = ""
        var runIsNumber = false
        func flush() {
            guard !run.isEmpty else { return }
            tokens.append(contentsOf: runIsNumber ? spelledNumber(run) : contractionTokens(run))
            run = ""
        }
        for character in piece {
            let isNumberPart = isDigit(character) || character == "." || character == ","
            if character == "'" { continue }
            if !run.isEmpty, isNumberPart != runIsNumber { flush() }
            runIsNumber = isNumberPart
            run.append(character)
        }
        flush()
        return tokens
    }

    /// "1,000" → one thousand, "2.5" → two point five, "007" → zero zero seven.
    private static func spelledNumber(_ text: String) -> [String] {
        let plain = text.filter { $0 != "," }
        let parts = plain.split(separator: ".", omittingEmptySubsequences: false)
        guard let whole = parts.first else { return [] }
        var tokens = wholeNumber(whole)
        if parts.count > 1 {
            for fraction in parts.dropFirst() where !fraction.isEmpty {
                tokens.append("point")
                tokens.append(contentsOf: digitWords(fraction))
            }
        }
        return tokens
    }

    /// Up to nine digits as one number ("1234" → one thousand two hundred thirty four); a leading zero or more digits
    /// than that, digit by digit.
    private static func wholeNumber(_ digits: Substring) -> [String] {
        let values = digits.compactMap(digitValue)
        guard !values.isEmpty else { return [] }
        if values.count > 1, values[0] == 0 { return values.map { ones[$0] } }
        guard values.count <= 9 else { return values.map { ones[$0] } }
        var value = 0
        for digit in values {
            // Nine digits always fit; checked anyway, so no input can trap.
            let (shifted, overflowed) = value.multipliedReportingOverflow(by: 10)
            let (sum, overflowedAgain) = shifted.addingReportingOverflow(digit)
            guard !overflowed, !overflowedAgain else { return values.map { ones[$0] } }
            value = sum
        }
        return numberWords(value)
    }

    /// Letters (and maybe an apostrophe): contractions expanded, other apostrophes removed.
    private static func contractionTokens(_ word: String) -> [String] {
        if word == "cannot" { return ["can", "not"] }
        guard word.contains("'") else { return [word] }
        let special: [String: [String]] = [
            "won't": ["will", "not"], "can't": ["can", "not"], "shan't": ["shall", "not"], "ain't": ["is", "not"],
            "let's": ["let", "us"], "y'all": ["you", "all"],
        ]
        if let expanded = special[word] { return expanded }
        if word.hasSuffix("n't") { return [String(word.dropLast(3)), "not"] }
        let endings: [(String, String)] = [("'re", "are"), ("'ve", "have"), ("'ll", "will"), ("'m", "am"), ("'d", "would")]
        for (ending, expansion) in endings where word.hasSuffix(ending) {
            let stem = word.dropLast(ending.count)
            if !stem.isEmpty { return [stem.replacingOccurrences(of: "'", with: ""), expansion] }
        }
        if word.hasSuffix("'s") {
            let stem = String(word.dropLast(2))
            if isContractions.contains(stem) { return [stem, "is"] }
        }
        return [word.replacingOccurrences(of: "'", with: "")]
    }

    /// Levenshtein distance between two scalar arrays.
    private static func editDistance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
