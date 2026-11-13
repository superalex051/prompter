import Testing
@testable import Prompter

/// Written and recognised words become the same tokens (`VoiceText`).
struct VoiceTextTests {
    @Test(arguments: [
        ("Hello,", ["hello"]),
        ("WORLD!", ["world"]),
        ("“quoted”", ["quoted"]),
        ("Café", ["cafe"]),
        ("naïve", ["naive"]),
        ("Ｆｕｌｌ", ["full"]),
        ("—", []),
        ("...", []),
        ("forty-five", ["forty", "five"]),
        ("and/or", ["and", "or"]),
        ("well—known", ["well", "known"]),
        ("rock&roll", ["rock", "and", "roll"]),
    ])
    func foldsCaseAccentsAndPunctuation(word: String, expected: [String]) {
        #expect(VoiceText.tokens(of: word) == expected)
    }

    @Test(arguments: [
        ("45", ["forty", "five"]),
        ("45.", ["forty", "five"]),
        ("0", ["zero"]),
        ("7", ["seven"]),
        ("10", ["ten"]),
        ("19", ["nineteen"]),
        ("20", ["twenty"]),
        ("100", ["one", "hundred"]),
        ("105", ["one", "hundred", "five"]),
        ("1,000", ["one", "thousand"]),
        ("2026", ["two", "thousand", "twenty", "six"]),
        ("1,250,000", ["one", "million", "two", "hundred", "fifty", "thousand"]),
        ("2.5", ["two", "point", "five"]),
        ("9:41", ["nine", "forty", "one"]),
        ("007", ["zero", "zero", "seven"]),
        ("1st", ["first"]),
        ("2nd", ["second"]),
        ("3rd", ["third"]),
        ("12th", ["twelfth"]),
        ("21st", ["twenty", "first"]),
        ("40th", ["fortieth"]),
        ("a7c", ["a", "seven", "c"]),
        ("4K", ["four", "k"]),
        ("50%", ["fifty", "percent"]),
        ("$5", ["five"]),
    ])
    func spellsOutNumbers(word: String, expected: [String]) {
        #expect(VoiceText.tokens(of: word) == expected)
    }

    @Test(arguments: [
        ("don't", ["do", "not"]),
        ("Don’t", ["do", "not"]),
        ("isn't", ["is", "not"]),
        ("won't", ["will", "not"]),
        ("can't", ["can", "not"]),
        ("cannot", ["can", "not"]),
        ("I'm", ["i", "am"]),
        ("we're", ["we", "are"]),
        ("they've", ["they", "have"]),
        ("you'll", ["you", "will"]),
        ("she'd", ["she", "would"]),
        ("it's", ["it", "is"]),
        ("that's", ["that", "is"]),
        ("let's", ["let", "us"]),
        ("Sam's", ["sams"]),
        ("dogs'", ["dogs"]),
        ("o'clock", ["oclock"]),
        ("'cause", ["cause"]),
    ])
    func expandsContractions(word: String, expected: [String]) {
        #expect(VoiceText.tokens(of: word) == expected)
    }

    @Test func writtenAndSpokenFormsAgree() {
        // What a script says vs what a recogniser may write for the same speech.
        let pairs: [(String, String)] = [
            ("at forty-five degrees", "at 45 degrees"),
            ("Don't worry", "do not worry"),
            ("It's 9:41", "it is nine forty one"),
            ("the 1st time", "the first time"),
            ("thirty to sixty seconds", "30 to 60 seconds"),
        ]
        for (written, spoken) in pairs {
            #expect(VoiceText.tokens(ofText: written) == VoiceText.tokens(ofText: spoken), "\(written) / \(spoken)")
        }
    }

    @Test func fuzzyMatchingAllowsAQuarterOfTheLetters() {
        #expect(VoiceText.matches("memorising", "memorizing"))
        #expect(VoiceText.matches("memorising", "memoising"))       // a letter dropped by the recogniser
        #expect(VoiceText.matches("samuels", "samuel"))
        #expect(VoiceText.matches("acrylic", "acrylics"))
        #expect(!VoiceText.matches("memo", "memorising"))           // a half-heard fragment
        #expect(!VoiceText.matches("cat", "car"))                   // short words must be exact
        #expect(!VoiceText.matches("the", "then"))
        #expect(!VoiceText.matches("camera", "glass"))
        #expect(VoiceText.matches("the", "the"))
    }

    @Test func similarityIsOneMinusEditDistanceOverTheLongerWord() {
        #expect(VoiceText.similarity("kitten", "sitting") == 1 - 3.0 / 7.0)
        #expect(VoiceText.similarity("", "") == 1)
        #expect(VoiceText.similarity("abc", "") == 0)
    }

    @Test func commonWordsWeighLess() {
        #expect(VoiceText.weight(of: "the") < VoiceText.weight(of: "camera"))
        #expect(VoiceText.weight(of: "and") == VoiceText.commonWordWeight)
        #expect(VoiceText.weight(of: "acrylic") == 1)
    }

    /// Characters Unicode counts as numbers but that aren't one decimal digit (CJK numerals like 万 = 10 000, circled
    /// numbers like ⑳ = 20) used to index the digit words out of range and crash the prompter on open. Now only 0…9
    /// are digits; the others stay tokens of their own.
    @Test(arguments: [
        ("2.5万", ["two", "point", "five", "万"]),
        ("⑳", ["⑳"]),
        ("第⑳回", ["第⑳回"]),
        ("万", ["万"]),
        ("十", ["十"]),
        ("½", ["½"]),
        ("3½", ["three", "½"]),
        ("٣", ["three"]),                       // an Arabic-Indic digit is still a digit
    ])
    func numberCharactersThatAreNotDigitsDoNotCrash(word: String, expected: [String]) {
        #expect(VoiceText.tokens(of: word) == expected)
    }

    @Test func longCJKNumeralsDoNotCrash() {
        // 一 … 九 have digit values; 十 百 千 万 don't. Ten numeral characters and more.
        let tokens = VoiceText.tokens(of: "一千二百三十四万五千")
        #expect(tokens == ["one", "千", "two", "百", "three", "十", "four", "万", "five", "千"])
        let long = String(repeating: "九", count: 40) + "万"
        #expect(VoiceText.tokens(of: long).count == 41)
        // A whole script line of them through the tokenizer the aligner uses.
        #expect(!VoiceText.tokens(ofText: "今年は二〇二六年、売上は⑳％増の一千二百三十四万五千円。").isEmpty)
    }

    @Test(arguments: [
        ("12345678901234567890", 20),           // past Int: digit by digit, no overflow
        ("99999999999999999999th", 21),         // an ordinal too big for Int: twenty digits and "th", no trap
    ])
    func hugeNumbersAreSpelledDigitByDigit(word: String, count: Int) {
        let tokens = VoiceText.tokens(of: word)
        #expect(tokens.count == count)
    }

    @Test func digitValuesAreOnlyZeroToNine() {
        #expect(VoiceText.digitValue("7") == 7)
        #expect(VoiceText.digitValue("٣") == 3)
        #expect(VoiceText.digitValue("万") == nil)
        #expect(VoiceText.digitValue("⑳") == nil)
        #expect(VoiceText.digitValue("十") == nil)
        #expect(VoiceText.digitValue("a") == nil)
        #expect(VoiceText.numberWords(.min).first == "minus")
        #expect(VoiceText.numberWords(-45) == ["minus", "forty", "five"])
    }

    @Test func ordinalWords() {
        #expect(VoiceText.ordinalWords(1) == ["first"])
        #expect(VoiceText.ordinalWords(5) == ["fifth"])
        #expect(VoiceText.ordinalWords(8) == ["eighth"])
        #expect(VoiceText.ordinalWords(9) == ["ninth"])
        #expect(VoiceText.ordinalWords(20) == ["twentieth"])
        #expect(VoiceText.ordinalWords(100) == ["one", "hundredth"])
    }
}
