import Foundation
import Testing
@testable import Prompter

/// Following a reader from recognised words (`VoiceAligner`). The script is the demo's first three paragraphs.
struct VoiceAlignerTests {
    let script = VoiceFixtures.rigTour

    // MARK: Helpers

    /// The script words as written, punctuation and case dropped ("Hey," → "hey").
    func scriptWords(_ aligner: VoiceAligner, in text: String) -> [String] {
        let string = text as NSString
        return aligner.words.map {
            string.substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count))
                .lowercased()
                .trimmingCharacters(in: .punctuationCharacters)
        }
    }

    /// The index of the `occurrence`-th script word reading `text` (in `source`, the text the aligner was made from).
    func index(of text: String, _ occurrence: Int = 1, in aligner: VoiceAligner, source: String = VoiceFixtures.rigTour) -> Int {
        let words = scriptWords(aligner, in: source)
        let matches = words.indices.filter { words[$0] == text }
        precondition(matches.count >= occurrence, "no \(occurrence). \(text)")
        return matches[occurrence - 1]
    }

    /// Hears `words` one at a time on top of `heard` (a growing partial result), returning the matched word after each.
    @discardableResult
    func say(_ words: String, to aligner: inout VoiceAligner, heard: inout [String]) -> [Int?] {
        var matched: [Int?] = []
        for word in words.split(separator: " ") {
            heard.append(String(word))
            _ = aligner.advance(with: heard)
            matched.append(aligner.matchedWord)
        }
        return matched
    }

    // MARK: Reading

    @Test func paragraphReadStraightThrough() {
        var aligner = VoiceAligner(text: script)
        let written = script.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        #expect(written.count == aligner.words.count)
        var heard: [String] = []
        for (index, word) in written.enumerated() {
            heard.append(word)
            let result = aligner.advance(with: heard)
            #expect(result == index, "after \(word)")
            #expect(aligner.matchedWord == index, "after \(word)")
        }
        #expect(aligner.isAtEnd)
        #expect(aligner.nextWord == nil)
    }

    /// The real thing: every volatile and final result SpeechTranscriber gave for a read-through, through the same
    /// transcript bookkeeping the app uses. The text must keep up and never go back.
    @Test func realRecognizerResultsFollowTheReading() {
        var aligner = VoiceAligner(text: script)
        var transcript = SpeechTranscript()
        var segment = 0
        var previous = -1
        var checkpoints: [String: Int] = [:]
        for update in VoiceFixtures.analyzerUpdates {
            transcript.update(segment: segment, text: update.text, isFinal: update.isFinal)
            if update.isFinal { segment += 1 }
            _ = aligner.advance(with: transcript.words)
            let matched = aligner.matchedWord ?? -1
            #expect(matched >= previous, "went back at \(update.text)")
            previous = matched
            if update.text.hasSuffix("down the lens") { checkpoints["lens"] = matched }
            if update.text.hasSuffix("cradle I printed") { checkpoints["printed"] = matched }
            if update.text.hasSuffix("at 45 degrees") { checkpoints["degrees"] = matched }
            if update.text.hasSuffix("the app mirrors the text") { checkpoints["text"] = matched }
        }
        #expect(checkpoints["lens"] == index(of: "lens", in: aligner))
        #expect(checkpoints["printed"] == index(of: "printed", in: aligner))
        #expect(checkpoints["degrees"] == index(of: "degrees", in: aligner))
        #expect(checkpoints["text"] == index(of: "text", in: aligner))
        #expect(aligner.isAtEnd)
    }

    // MARK: Review focus: ad-libs, repeats, skips

    @Test func adLibHoldsPosition() {
        var aligner = VoiceAligner(text: script)
        var heard: [String] = []
        say("Hey welcome back today I'm showing you the setup I use to talk straight down the lens", to: &aligner, heard: &heard)
        let lens = index(of: "lens", in: aligner)
        #expect(aligner.matchedWord == lens)

        let adLib = say("hold on a second the light is off sorry about that where was I", to: &aligner, heard: &heard)
        #expect(adLib.allSatisfy { $0 == lens }, "moved during the ad-lib: \(adLib)")

        say("without memorizing a single line", to: &aligner, heard: &heard)
        #expect(aligner.matchedWord == index(of: "line", in: aligner))
    }

    @Test func repeatedWordDoesNotJumpBack() {
        var aligner = VoiceAligner(text: script)
        var heard: [String] = []
        say(Self.prefix(of: script, through: "flat on the desk,"), to: &aligner, heard: &heard)
        let desk = index(of: "desk", in: aligner)
        #expect(aligner.matchedWord == desk)

        // "the" is everywhere behind (one just before "desk"); a stammered "the the" must not pull the text back.
        let stammer = say("the the the", to: &aligner, heard: &heard)
        #expect(stammer.allSatisfy { $0 == desk })

        say("screen up in a little cradle I printed. Above it sits a sheet of clear acrylic at forty-five degrees.", to: &aligner, heard: &heard)
        say("The camera films through the acrylic, and I read the reflection.", to: &aligner, heard: &heard)

        say("because the reflection flips everything the app mirrors", to: &aligner, heard: &heard)
        let mirrors = index(of: "mirrors", in: aligner)
        #expect(aligner.matchedWord == mirrors)
        // Saying a word from a moment ago again ("reflection") doesn't go back to it.
        let repeated = say("reflection", to: &aligner, heard: &heard)
        #expect(repeated == [mirrors])
    }

    @Test func skipAheadWithinWindow() {
        var aligner = VoiceAligner(text: script)
        var heard: [String] = []
        say(Self.prefix(of: script, through: "a single line."), to: &aligner, heard: &heard)
        let line = index(of: "line", in: aligner)
        #expect(aligner.matchedWord == line)

        // Skips "It's simpler than it looks. My phone … I printed." (21 tokens) and goes on at "Above it sits".
        let matched = say("above it sits", to: &aligner, heard: &heard)
        #expect(matched == [line, line, index(of: "sits", in: aligner)])  // one or two words ahead aren't enough
        say("a sheet of clear acrylic", to: &aligner, heard: &heard)
        #expect(aligner.matchedWord == index(of: "acrylic", 1, in: aligner))
    }

    @Test func skipBeyondTheWindowIsNotFollowedUntilResynced() {
        let full = VoiceFixtures.rigTourFull
        var aligner = VoiceAligner(text: full)
        var heard: [String] = []
        say(Self.prefix(of: full, through: "a single line."), to: &aligner, heard: &heard)
        let line = index(of: "line", in: aligner, source: full)

        // The fifth paragraph starts well over 60 tokens on.
        let far = say("The best part is the remote. I start, pause and slow down the script", to: &aligner, heard: &heard)
        #expect(far.allSatisfy { $0 == line })

        // A step by hand to that paragraph: the aligner picks up there (and the controller drops what was heard before).
        let paragraph = (full as NSString).range(of: "The best part").location
        aligner.resync(toCharacterIndex: paragraph)
        #expect(aligner.matchedWord == index(of: "ignore", in: aligner, source: full))   // everything before counts as read
        heard = []
        say("the best part is the remote", to: &aligner, heard: &heard)
        #expect(aligner.matchedWord == index(of: "remote", in: aligner, source: full))
    }

    // MARK: Speech as it really comes out

    @Test func stutterKeepsUp() {
        var aligner = VoiceAligner(text: script)
        var heard: [String] = []
        say("Hey welcome back today I'm showing you the setup I use", to: &aligner, heard: &heard)
        let matched = say("to to to talk st straight down the the lens", to: &aligner, heard: &heard)
        let lens = index(of: "lens", in: aligner)
        #expect(aligner.matchedWord == lens)
        var previous = -1
        for value in matched.compactMap({ $0 }) {
            #expect(value >= previous && value <= lens)
            previous = value
        }
    }

    @Test func mispronunciationsStillFollow() {
        var aligner = VoiceAligner(text: script)
        var heard: [String] = []
        say("Hey welcome back today I'm showing you the setup I use to talk straight down the lens", to: &aligner, heard: &heard)
        say("without memorising a single line", to: &aligner, heard: &heard)        // British spelling
        #expect(aligner.matchedWord == index(of: "line", in: aligner))
        say("it's simpler than it looks my phone lies flat on the desk screen up in a little cradel I printed", to: &aligner, heard: &heard)
        #expect(aligner.matchedWord == index(of: "printed", in: aligner))          // "cradel" didn't match, the rest did
        say("above it sits a sheet of clear acrillic at", to: &aligner, heard: &heard)
        #expect(aligner.matchedWord == index(of: "at", in: aligner))
    }

    @Test func numbersMatchWhicheverWayTheyAreWritten() {
        var aligner = VoiceAligner(text: script)
        var heard: [String] = []
        say(Self.prefix(of: script, through: "clear acrylic"), to: &aligner, heard: &heard)
        say("at 45 degrees", to: &aligner, heard: &heard)
        #expect(aligner.matchedWord == index(of: "degrees", in: aligner))

        var digits = VoiceAligner(text: "It only needs to be 30 to 60 seconds, no more.")
        var spoken: [String] = []
        for word in "it only needs to be thirty to sixty seconds".split(separator: " ") {
            spoken.append(String(word))
            _ = digits.advance(with: spoken)
        }
        #expect(digits.matchedWord == 8)   // "seconds,"
    }

    /// Recognisers revise the newest words: fragments get completed, words change, and now and then the last words are
    /// taken back for a moment. None of that may move the text backwards.
    @Test func partialRewritesNeverJumpBackwards() {
        var aligner = VoiceAligner(text: script)
        let lens = index(of: "lens", in: aligner)
        let updates = [
            "Hey welcome back today I'm showing you the set",
            "Hey welcome back today I'm showing you the setup I use to",
            "Hey welcome back today I'm showing you the set up I used to talk",
            "Hey welcome back today I'm showing you the set up I use to talk straight down the l",
            "Hey welcome back today I'm showing you the setup I use to talk straight down the lens",
            "Hey welcome back today I'm showing you the setup I use to talk straight down",   // taken back
            "Hey welcome back today I'm showing you the setup I use to talk straight down the lens with",
            "Hey welcome back today I'm showing you the setup I use to talk straight down the lens without memo",
        ]
        var matched: [Int?] = []
        for update in updates {
            _ = aligner.advance(with: update.split(separator: " ").map(String.init))
            matched.append(aligner.matchedWord)
        }
        #expect(matched[0] == index(of: "the", 1, in: aligner))
        #expect(matched[1] == index(of: "to", 1, in: aligner))
        #expect(matched[2] == index(of: "talk", in: aligner))
        #expect(matched[4] == lens)
        #expect(matched[5] == lens)                                    // not back to "down"
        #expect(matched[6] == lens)                                    // "with" is not "without"
        #expect(matched[7] == index(of: "without", in: aligner))
        let values = matched.compactMap { $0 }
        #expect(values == values.sorted())
    }

    @Test func reReadingAPhraseGoesBackThenOn() {
        var aligner = VoiceAligner(text: script)
        var heard: [String] = []
        say(Self.prefix(of: script, through: "flat on the desk,"), to: &aligner, heard: &heard)
        let desk = index(of: "desk", in: aligner)
        #expect(aligner.matchedWord == desk)

        // A fumble: back to "phone lies flat on …". Three words in a row behind is a candidate, the fourth confirms.
        let reRead = say("phone lies flat on", to: &aligner, heard: &heard)
        #expect(reRead == [desk, desk, desk, index(of: "on", 1, in: aligner)])
        say("the desk screen up", to: &aligner, heard: &heard)
        #expect(aligner.matchedWord == index(of: "up", in: aligner))
    }

    // MARK: Edges

    @Test func endOfScript() {
        var aligner = VoiceAligner(text: script)
        var heard: [String] = []
        say(script, to: &aligner, heard: &heard)
        let last = aligner.words.count - 1
        #expect(aligner.matchedWord == last)
        #expect(aligner.isAtEnd)
        #expect(aligner.nextWord == nil)

        let outro = say("thanks for watching see you next time", to: &aligner, heard: &heard)
        #expect(outro.allSatisfy { $0 == last })
    }

    @Test func theSameWordsAgainAreNothingNew() {
        var aligner = VoiceAligner(text: script)
        let heard = ["Hey", "welcome", "back"]
        #expect(aligner.advance(with: heard) == 2)
        #expect(aligner.advance(with: heard) == nil)
        #expect(aligner.advance(with: heard + ["."]) == nil)    // punctuation alone changes nothing
        #expect(aligner.matchedWord == 2)
    }

    @Test func nothingHeardYet() {
        var aligner = VoiceAligner(text: script)
        #expect(aligner.matchedWord == nil)
        #expect(aligner.nextWord == 0)
        #expect(aligner.advance(with: []) == nil)
        #expect(aligner.advance(with: ["um"]) == nil)
        #expect(aligner.matchedWord == nil)
    }

    @Test func startingFurtherInNeedsMoreThanOneWord() {
        var aligner = VoiceAligner(text: script)
        var heard: [String] = []
        // Starts 8 tokens in: "the", "setup" and "I" alone could be anything; with "use" it is clear.
        let matched = say("the setup I use", to: &aligner, heard: &heard)
        #expect(matched == [nil, nil, nil, index(of: "use", in: aligner)])
    }

    @Test func startingAtTheSecondSentenceIsCloseEnough() {
        var aligner = VoiceAligner(text: script)
        var heard: [String] = []
        let matched = say("today I'm showing", to: &aligner, heard: &heard)
        #expect(matched == [index(of: "today", in: aligner), index(of: "i'm", in: aligner), index(of: "showing", in: aligner)])
    }

    @Test func emptyScriptNeverMatches() {
        var aligner = VoiceAligner(text: "")
        #expect(aligner.words.isEmpty)
        #expect(aligner.advance(with: ["hello"]) == nil)
        #expect(aligner.nextWord == nil)
        #expect(!aligner.isAtEnd)
    }

    // MARK: Script words

    @Test func onlyTimedTextIsAlignable() {
        let document = PrompterDocument(body: "// a note to self\nHello there\n[pause 2]\nCafé 👋 time — now")
        let aligner = VoiceAligner(document: document)
        let text = document.text as NSString
        let words = aligner.words.map { text.substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count)) }
        #expect(words == ["Hello", "there", "Café", "time", "now"])
        #expect(words.count == document.timedWordCount)
    }

    @Test func wordRangesAreUTF16() {
        let text = "👋🏽 naïve 🇷🇴 test"
        let ranges = VoiceAligner.wordRanges(in: text)
        #expect(ranges.map(\.1) == ["naïve", "test"])
        let string = text as NSString
        for (range, word) in ranges {
            #expect(string.substring(with: NSRange(location: range.lowerBound, length: range.count)) == word)
        }
    }

    // MARK: Fixtures

    /// `text` up to and including the first occurrence of `end`.
    static func prefix(of text: String, through end: String) -> String {
        let range = text.range(of: end)!
        return String(text[..<range.upperBound])
    }
}
