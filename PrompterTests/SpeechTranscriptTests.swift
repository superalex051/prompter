import Testing
@testable import Prompter

/// Bookkeeping of what a recogniser has heard so far (`SpeechTranscript`).
struct SpeechTranscriptTests {
    @Test func volatileResultsReplaceEachOtherUntilFinal() {
        var transcript = SpeechTranscript()
        #expect(transcript.isEmpty)
        let changed1 = transcript.update(segment: 0, text: "Hey", isFinal: false)
        #expect(changed1)
        let changed2 = transcript.update(segment: 0, text: "Hey, welcome", isFinal: false)
        #expect(changed2)
        #expect(transcript.words == ["Hey,", "welcome"])
        let changed3 = transcript.update(segment: 0, text: "Hey, welcome back.", isFinal: true)
        #expect(changed3)
        let changed4 = transcript.update(segment: 1, text: "Today I", isFinal: false)
        #expect(changed4)
        #expect(transcript.words == ["Hey,", "welcome", "back.", "Today", "I"])
        #expect(!transcript.isEmpty)
    }

    @Test func aFinalSegmentNeverChangesAgain() {
        var transcript = SpeechTranscript()
        transcript.update(segment: 0, text: "one two", isFinal: true)
        let changed5 = transcript.update(segment: 0, text: "one two three", isFinal: false)
        #expect(!changed5)
        #expect(transcript.words == ["one", "two"])
    }

    @Test func unchangedTextReportsNoChange() {
        var transcript = SpeechTranscript()
        transcript.update(segment: 0, text: "one two", isFinal: false)
        let changed6 = transcript.update(segment: 0, text: "one  two", isFinal: false)
        #expect(!changed6)
    }

    /// SFSpeechRecognizer: a new task (segment 2) may report before the old one's final (segment 1) arrives.
    @Test func lateFinalOfAnOlderSegmentStaysInOrder() {
        var transcript = SpeechTranscript()
        transcript.update(segment: 1, text: "the camera films", isFinal: false)
        transcript.update(segment: 2, text: "and I read", isFinal: false)
        transcript.update(segment: 1, text: "the camera films through the acrylic", isFinal: true)
        #expect(transcript.words == ["the", "camera", "films", "through", "the", "acrylic", "and", "I", "read"])
    }

    @Test func keepsOnlyTheNewestWords() {
        var transcript = SpeechTranscript()
        for segment in 0..<20 {
            transcript.update(segment: segment, text: "w\(segment)a w\(segment)b w\(segment)c w\(segment)d w\(segment)e", isFinal: true)
        }
        transcript.update(segment: 20, text: "now", isFinal: false)
        let words = transcript.words
        #expect(words.count >= SpeechTranscript.keptWords)
        #expect(words.count < SpeechTranscript.keptWords + 6)
        #expect(words.last == "now")
        #expect(words.dropLast().last == "w19e")
    }

    @Test func resetForgetsEverything() {
        var transcript = SpeechTranscript()
        transcript.update(segment: 0, text: "hello", isFinal: true)
        transcript.reset()
        #expect(transcript.isEmpty)
        #expect(transcript.words.isEmpty)
    }
}
