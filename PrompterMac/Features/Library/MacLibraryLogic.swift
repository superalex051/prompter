import Foundation
import UniformTypeIdentifiers

/// Which dropped or picked files Prompter can turn into scripts: .txt (and other plain text), .md, .rtf and .pdf, the
/// same types as the iPhone's importer.
enum ImportableFiles {
    static let contentTypes: [UTType] = ScriptImporter.importableTypes

    /// True for a file URL whose extension is plain text, Markdown, RTF or PDF.
    static func accepts(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let fileExtension = url.pathExtension.lowercased()
        if ScriptImporter.markdownExtensions.contains(fileExtension) { return true }
        guard let type = UTType(filenameExtension: fileExtension) else { return false }
        return contentTypes.contains { type.conforms(to: $0) }
    }

    /// The files to import and a failure line for each file that can't be (so a mixed drop still imports what it can).
    static func split(_ urls: [URL]) -> (accepted: [URL], rejected: [ImportFailure]) {
        var accepted: [URL] = []
        var rejected: [ImportFailure] = []
        for url in urls where url.isFileURL {
            if accepts(url) {
                accepted.append(url)
            } else {
                rejected.append(ImportFailure(
                    filename: url.lastPathComponent,
                    message: ScriptImportError.unsupportedType(url.pathExtension).message
                ))
            }
        }
        return (accepted, rejected)
    }
}

/// The sidebar search: every word of the query has to appear in the title or the text, ignoring case and accents.
enum ScriptSearch {
    static func filter(_ scripts: [Script], query: String) -> [Script] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return scripts }
        return scripts.filter { script in
            words.allSatisfy { word in
                script.title.localizedStandardContains(word) || script.body.localizedStandardContains(word)
            }
        }
    }
}

enum MacScriptStats {
    /// "412 words · 2:56" ("1,204 words" from a thousand up), the read time at the words-per-minute setting.
    /// `markdown`: counted as the prompter shows the script with Markdown formatting on.
    static func summary(of script: Script, wordsPerMinute: Double, markdown: Bool = false) -> String {
        summary(ofBody: script.body, wordsPerMinute: wordsPerMinute, markdown: markdown)
    }

    static func summary(ofBody body: String, wordsPerMinute: Double, markdown: Bool = false) -> String {
        let stats = ReadingStats(text: body, markdown: markdown)
        let words = stats.wordCount
        let time = TimeFormatting.clock(stats.readingSeconds(atWPM: wordsPerMinute))
        return "\(words.formatted()) \(words == 1 ? "word" : "words") · \(time)"
    }

    /// The sidebar row's last line: "412 words · 2:56 · edited 5 minutes ago".
    static func rowDetail(
        of script: Script, wordsPerMinute: Double, markdown: Bool = false, now: Date = .now,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        // A clock a little behind the saved time would read "in 1 second"; a script is never edited in the future.
        let edited = min(script.updatedAt, now)
        let when = formatter.localizedString(for: edited, relativeTo: now)
        return "\(summary(of: script, wordsPerMinute: wordsPerMinute, markdown: markdown)) · edited \(when)"
    }

    /// The editor footer: "412 words · 2:56 at 140 wpm".
    static func footer(ofBody body: String, wordsPerMinute: Double, markdown: Bool = false) -> String {
        "\(summary(ofBody: body, wordsPerMinute: wordsPerMinute, markdown: markdown)) at \(Int(wordsPerMinute.rounded())) wpm"
    }
}

/// The one-line hint under the word count: how to write a note or a pause (and, with Markdown formatting on, bold and
/// headings). Shown only while the script has no notes or pauses.
enum MacEditorTip {
    static let text = "Tip: start a line with // for a note, or write [pause 2] to hold."
    static let markdownText = "Tip: start a line with // for a note, or write [pause 2] to hold. Markdown works too: "
        + "**bold** shows in amber, # starts a heading."

    static func text(markdown: Bool) -> String {
        markdown ? markdownText : text
    }

    static func isShown(for body: String) -> Bool {
        ScriptMarkup.lines(of: body).allSatisfy { $0.kind == .text }
    }
}

/// How wide the writing column is, and the margin that centers it in a window of a given width.
enum MacEditorLayout {
    static let columnWidth: Double = 720
    static let minimumMargin: Double = 32

    static func horizontalMargin(forWidth width: Double) -> Double {
        guard width.isFinite else { return minimumMargin }
        return max(minimumMargin, ((width - columnWidth) / 2).rounded())
    }
}

/// Where the notes and pause cues are in a script, to colour them in the editor, and with Markdown formatting on where
/// its headings, rules, styled words and markers are (the markers stay in the text, dimmed).
enum ScriptHighlight {
    enum Kind: Equatable, Sendable {
        case note
        case pause
        /// A whole Markdown heading line.
        case heading(level: Int)
        /// A Markdown rule line.
        case rule
        /// Markdown markers: `**`, `#`, `- `, `>`, a link's `](…)`. Dimmed.
        case marker
        /// Text with inline Markdown styles.
        case styled(MarkdownStyle)
    }

    struct Span: Equatable, Sendable {
        var range: NSRange
        var kind: Kind
    }

    /// Line spans first (notes, cues, headings, rules), then each line's styled text and markers, in order.
    static func spans(in body: String, markdown: Bool = false) -> [Span] {
        var spans: [Span] = []
        for line in ScriptMarkup.lines(of: body, markdown: markdown) {
            let lineRange = NSRange(line.range, in: body)
            switch line.kind {
            case .note: spans.append(Span(range: lineRange, kind: .note))
            case .pause: spans.append(Span(range: lineRange, kind: .pause))
            case .rule: spans.append(Span(range: lineRange, kind: .rule))
            case .heading(let level): spans.append(Span(range: lineRange, kind: .heading(level: level)))
            case .text: break
            }
            // Inline Markdown on text and heading lines (a rule is all marker; notes and cues stay as they are).
            switch line.kind {
            case .text, .heading: guard markdown else { continue }
            case .note, .pause, .rule: continue
            }
            let parsed = ScriptMarkdown.parse(body[line.range])
            for run in parsed.sourceRuns {
                spans.append(Span(range: NSRange(location: lineRange.location + run.range.lowerBound,
                                                 length: run.range.count), kind: .styled(run.style)))
            }
            for marker in parsed.markers {
                spans.append(Span(range: NSRange(location: lineRange.location + marker.lowerBound,
                                                 length: marker.count), kind: .marker))
            }
        }
        return spans
    }
}
