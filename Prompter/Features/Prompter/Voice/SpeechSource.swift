import Foundation
import NaturalLanguage

/// Where voice-follow gets the words it hears. The app uses `LiveSpeechSource` (microphone or, in debug builds, an audio
/// file, recognised on the device); tests use a fake that "hears" whatever the test says.
///
/// The microphone is on only between `start()` and `stop()`.
@MainActor
protocol SpeechSource: AnyObject {
    /// Everything heard since `start()`, newest last, each time it changes (recognisers keep revising the newest words).
    var onWords: (([String]) -> Void)? { get set }
    /// Listening stopped by itself and can't go on (the microphone or the recogniser failed for good).
    var onFailure: ((VoiceProblem) -> Void)? { get set }
    /// Asks for permission if it hasn't been asked yet and gets the recogniser ready (on first use this may download the
    /// speech model). nil when it can listen; otherwise why not.
    func prepare() async -> VoiceProblem?
    /// Turns the microphone on and starts recognising. Call only after `prepare()` returned nil.
    func start()
    /// Turns the microphone off and forgets what was heard. Safe to call at any time.
    func stop()
    /// Keeps listening, but what was heard so far no longer counts (the text was moved by hand): `onWords` reports only
    /// what is heard from now on.
    func forgetHeard()
}

/// Which recogniser language to listen in: the script's own language (so an English script is followed in English even
/// on a phone set to another language), in the device's region where that variant exists.
enum VoiceLocale {
    /// The dominant language of `text` (nil if it can't tell, e.g. very short text).
    static func language(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(4_000)))
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return language.rawValue
    }

    /// The locale to ask a recogniser for: the script's language with the current region ("en" + "GB" → en_GB), or the
    /// current locale if the language can't be told.
    static func preferred(forScript text: String, current: Locale = .current) -> Locale {
        guard let language = language(of: text) else { return current }
        if let region = current.region?.identifier {
            return Locale(identifier: "\(language)_\(region)")
        }
        return Locale(identifier: language)
    }

    /// The best of `supported` for `wanted`: the same identifier, else the same language and region, else the same
    /// language in its main variant (en_US, fr_FR, …), else the first with the same language. nil if none speaks it.
    static func best(for wanted: Locale, among supported: [Locale]) -> Locale? {
        let wantedID = normalized(wanted.identifier)
        if let exact = supported.first(where: { normalized($0.identifier) == wantedID }) { return exact }
        guard let language = wanted.language.languageCode?.identifier else { return nil }
        let sameLanguage = supported.filter { $0.language.languageCode?.identifier == language }
        if let region = wanted.region?.identifier,
           let match = sameLanguage.first(where: { $0.region?.identifier == region }) {
            return match
        }
        let main = normalized("\(language)_\(mainRegions[language] ?? language.uppercased())")
        if let match = sameLanguage.first(where: { normalized($0.identifier) == main }) { return match }
        return sameLanguage.min { $0.identifier < $1.identifier }
    }

    private static let mainRegions = ["en": "US", "es": "ES", "pt": "BR", "zh": "CN", "ar": "SA"]

    private static func normalized(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "-", with: "_").lowercased()
    }
}

/// The script's own words, to bias the recogniser towards them (names, jargon): the longer distinct words first.
enum VoiceVocabulary {
    static func words(in document: PrompterDocument, limit: Int = 100) -> [String] {
        var seen = Set<String>()
        var words: [String] = []
        for paragraph in document.paragraphs where paragraph.kind == .text {
            for (_, raw) in VoiceAligner.wordRanges(in: paragraph.text) {
                let word = raw.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
                guard word.count >= 4, seen.insert(word.lowercased()).inserted else { continue }
                words.append(word)
            }
        }
        // Stable: longest first, then script order.
        let ranked = words.enumerated().sorted { lhs, rhs in
            lhs.element.count != rhs.element.count ? lhs.element.count > rhs.element.count : lhs.offset < rhs.offset
        }
        return ranked.prefix(limit).map(\.element)
    }
}
