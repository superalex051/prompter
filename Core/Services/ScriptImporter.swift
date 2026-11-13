import Foundation
import PDFKit
#if canImport(UIKit)
import UIKit  // NSAttributedString RTF reading
#elseif canImport(AppKit)
import AppKit  // NSAttributedString RTF reading
#endif
import UniformTypeIdentifiers

struct ImportedScript: Equatable, Sendable {
    var title: String
    var body: String
}

enum ScriptImportError: Error, Equatable, Sendable {
    case unsupportedType(String)   // file extension
    case unreadable
    case empty
    case noTextInPDF

    var message: String {
        switch self {
        case .unsupportedType: "Prompter can import .txt, .md, .rtf and .pdf files."
        case .unreadable: "The file couldn't be read."
        case .empty: "The file has no text."
        case .noTextInPDF: "This PDF has no text to import (it may be a scan)."
        }
    }
}

enum ScriptImporter {
    /// Markdown files: imported as plain text, the Markdown kept as written (the prompter shows it formatted while
    /// Settings → Markdown formatting is on). Listed by extension too, because only `.md` and `.markdown` are declared
    /// types on every system.
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]

    /// The declared Markdown type (`net.daringfireball.markdown`, plain text), for file pickers.
    static let markdownType = UTType("net.daringfireball.markdown") ?? UTType(filenameExtension: "md", conformingTo: .plainText)

    /// What the file pickers offer: plain text (Markdown included), RTF and PDF.
    static var importableTypes: [UTType] {
        [.plainText, markdownType, .rtf, .pdf].compactMap { $0 }
    }

    /// .rtf → NSAttributedString(.rtf).string (drop U+FFFC attachments); .pdf → pdfText (PDFKit); Markdown and any type
    /// conforming to public.plain-text → decodeText.
    /// Title = file name without extension (trimmed); falls back to title(fromFirstLineOf:) if that is blank.
    static func importFile(at url: URL) throws(ScriptImportError) -> ImportedScript {
        let fileExtension = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: fileExtension)

        let text: String
        if type?.conforms(to: .pdf) == true {
            text = try pdfText(from: readData(at: url))
        } else if type?.conforms(to: .rtf) == true {
            text = try rtfText(from: readData(at: url))
        } else if type?.conforms(to: .plainText) == true || markdownExtensions.contains(fileExtension) {
            guard let decoded = decodeText(try readData(at: url)) else { throw .unreadable }
            text = decoded
        } else {
            throw .unsupportedType(fileExtension)
        }

        let body = normalize(text)
        guard hasWords(body) else { throw type?.conforms(to: .pdf) == true ? .noTextInPDF : .empty }
        let fileTitle = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return ImportedScript(title: fileTitle.isEmpty ? title(fromFirstLineOf: body) : fileTitle, body: body)
    }

    /// For paste: title from the first non-blank line; body = the whole normalised text (first line kept).
    static func fromPlainText(_ text: String) throws(ScriptImportError) -> ImportedScript {
        let body = normalize(text)
        guard hasWords(body) else { throw .empty }
        return ImportedScript(title: title(fromFirstLineOf: body), body: body)
    }

    /// UTF-8 (with or without BOM) → UTF-16 with BOM → Windows-1252 → Mac Roman. nil if nothing decodes.
    static func decodeText(_ data: Data) -> String? {
        let utf16BOMs: [[UInt8]] = [[0xFF, 0xFE], [0xFE, 0xFF]]
        let decoded = String(data: data, encoding: .utf8)
            ?? (utf16BOMs.contains { data.starts(with: $0) } ? String(data: data, encoding: .utf16) : nil)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .macOSRoman)
        guard let decoded else { return nil }
        return decoded.hasPrefix("\u{FEFF}") ? String(decoded.dropFirst()) : decoded
    }

    /// Strip BOM; CRLF/CR/U+2028/U+2029 → "\n"; NBSP → space; trim trailing spaces on each line; collapse 3+ consecutive
    /// newlines to 2; trim leading/trailing blank lines.
    static func normalize(_ text: String) -> String {
        var unified = text
        // CRLF first so it becomes one newline, not two. VT, FF and NEL are line breaks in some Word exports.
        let replacements = [
            ("\r\n", "\n"), ("\r", "\n"), ("\u{2028}", "\n"), ("\u{2029}", "\n"),
            ("\u{0B}", "\n"), ("\u{0C}", "\n"), ("\u{85}", "\n"),
            ("\u{FEFF}", ""), ("\u{00A0}", " "),
        ]
        for (target, replacement) in replacements {
            unified = unified.replacingOccurrences(of: target, with: replacement, options: .literal)
        }

        var lines: [Substring] = []
        var blankLinePending = false
        for rawLine in unified.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let lastVisible = rawLine.lastIndex(where: { !$0.isWhitespace }) else {
                blankLinePending = !lines.isEmpty  // leading blank lines are dropped
                continue
            }
            if blankLinePending { lines.append("") }
            lines.append(rawLine[...lastVisible])
            blankLinePending = false
        }
        return lines.joined(separator: "\n")
    }

    /// First non-blank line, trimmed, cut at a word boundary to ≤ maxLength chars with "…" appended when cut. "" if none.
    static func title(fromFirstLineOf text: String, maxLength: Int = 60) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        guard line.count > maxLength else { return line }
        guard maxLength > 0 else { return "" }

        let cut = line.prefix(maxLength)
        var head = cut
        // If the cut lands inside a word, back up to the previous space.
        if !line[cut.endIndex].isWhitespace, let space = cut.lastIndex(where: \.isWhitespace) {
            head = cut[..<space]
        }
        let trailingJunk: Set<Character> = [",", ";", ":", "-", "–", "—"]
        while let last = head.last, last.isWhitespace || trailingJunk.contains(last) {
            head = head.dropLast()
        }
        return (head.isEmpty ? cut : head) + "…"
    }

    // MARK: Private

    private static func hasWords(_ text: String) -> Bool {
        ReadingStats.wordCount(of: text) > 0
    }

    private static func readData(at url: URL) throws(ScriptImportError) -> Data {
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw .unreadable
        }
    }

    /// Page strings (each with line-end hyphenation repaired) joined by a blank line. Throws `.unreadable` when PDFKit can't open the
    /// data or the document is still locked after trying the empty password. Image-only (scanned) pages contribute no text.
    private static func pdfText(from data: Data) throws(ScriptImportError) -> String {
        guard let document = PDFDocument(data: data) else { throw .unreadable }
        if document.isLocked, !document.unlock(withPassword: "") { throw .unreadable }

        var pages: [String] = []
        for index in 0..<document.pageCount {
            guard let pageText = document.page(at: index)?.string else { continue }
            let tidied = rejoinHyphenatedWords(in: normalize(pageText))
            if hasWords(tidied) { pages.append(tidied) }
        }
        return pages.joined(separator: "\n\n")
    }

    /// "exam-\nple" → "example": a letter, a hyphen (hyphen-minus, U+2010 or soft hyphen) at the end of a line, and a lowercase letter
    /// starting the next line. Hyphens inside a line ("e-mail") and before a capital ("Smith-\nJones") are kept. Expects normalised
    /// line endings (`normalize` first).
    static func rejoinHyphenatedWords(in text: String) -> String {
        text.replacingOccurrences(
            of: #"(?<=\p{L})[-\u2010\u00AD]\n(?=\p{Ll})"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func rtfText(from data: Data) throws(ScriptImportError) -> String {
        do {
            let attributed = try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
            return attributed.string.replacingOccurrences(of: "\u{FFFC}", with: "", options: .literal)
        } catch {
            throw .unreadable
        }
    }
}
