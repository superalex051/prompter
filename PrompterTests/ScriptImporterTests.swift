import Foundation
import Testing
import UIKit
@testable import Prompter

final class ScriptImporterTests {
    let directory: URL

    init() throws {
        directory = try makeTemporaryDirectory()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ data: Data, named name: String) throws -> URL {
        let url = directory.appending(path: name)
        try data.write(to: url)
        return url
    }

    private func write(_ text: String, named name: String) throws -> URL {
        try write(Data(text.utf8), named: name)
    }

    private func rtfData(_ text: String) throws -> Data {
        let attributed = NSAttributedString(string: text)
        return try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    // MARK: Files

    @Test func importsUTF8Text() throws {
        let url = try write("Hello world.\nSecond line, café.", named: "Notes.txt")
        let imported = try ScriptImporter.importFile(at: url)
        #expect(imported == ImportedScript(title: "Notes", body: "Hello world.\nSecond line, café."))
    }

    @Test func titleComesFromTheFileName() throws {
        let url = try write("Some words", named: "My Talk.txt")
        #expect(try ScriptImporter.importFile(at: url).title == "My Talk")
    }

    @Test func blankFileNameFallsBackToTheFirstLine() throws {
        let url = try write("\n\nOpening line\nMore", named: "   .txt")
        #expect(try ScriptImporter.importFile(at: url).title == "Opening line")
    }

    @Test func decodesWindows1252() throws {
        // "café — “quoted”" as Windows-1252 bytes (é = E9, em dash = 97, curly quotes = 93/94).
        let bytes: [UInt8] = [0x63, 0x61, 0x66, 0xE9, 0x20, 0x97, 0x20, 0x93, 0x71, 0x75, 0x6F, 0x74, 0x65, 0x64, 0x94]
        #expect(ScriptImporter.decodeText(Data(bytes)) == "café — “quoted”")

        let url = try write(Data(bytes), named: "Legacy.txt")
        #expect(try ScriptImporter.importFile(at: url).body == "café — “quoted”")
    }

    @Test func decodesMacRomanWhenWindows1252Fails() {
        // 0x81 is undefined in Windows-1252; in Mac Roman it is "Å".
        let decoded = ScriptImporter.decodeText(Data([0x81, 0x20, 0x41]))
        #expect(decoded != nil)
        #expect(decoded?.hasSuffix(" A") == true)
    }

    @Test func decodesUTF16WithBOM() throws {
        let text = "Hello — “world”\nSecond line"
        let littleEndian = Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!
        let bigEndian = Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!
        #expect(ScriptImporter.decodeText(littleEndian) == text)
        #expect(ScriptImporter.decodeText(bigEndian) == text)

        let url = try write(littleEndian, named: "Word export.txt")
        #expect(try ScriptImporter.importFile(at: url).body == text)
    }

    @Test func decodesUTF8WithBOM() {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("Hi there".utf8)
        #expect(ScriptImporter.decodeText(data) == "Hi there")
    }

    @Test func normalizesCRLFAndBOM() throws {
        let raw = "\u{FEFF}Line one\r\nLine two\rLine three\u{2028}four\u{2029}five"
        #expect(ScriptImporter.normalize(raw) == "Line one\nLine two\nLine three\nfour\nfive")

        let url = try write(Data([0xEF, 0xBB, 0xBF]) + Data("First\r\nSecond\r\n\r\nThird\r\n".utf8), named: "Windows.txt")
        let body = try ScriptImporter.importFile(at: url).body
        #expect(body == "First\nSecond\n\nThird")
        #expect(!body.unicodeScalars.contains("\r"))
        #expect(!body.unicodeScalars.contains("\u{FEFF}"))
    }

    @Test func normalizeTidiesWhitespace() {
        let raw = "\n\n  \nTitle   \n\n\n\n\nBody\u{00A0}text \t\nNext\n\n\n  \n"
        #expect(ScriptImporter.normalize(raw) == "Title\n\nBody text\nNext")
        #expect(ScriptImporter.normalize("") == "")
        #expect(ScriptImporter.normalize(" \n\t\n") == "")
    }

    @Test func importsRTFAsPlainText() throws {
        let url = try write(try rtfData("Hello from RTF.\nSecond line — with a dash."), named: "Talk.rtf")
        let imported = try ScriptImporter.importFile(at: url)
        #expect(imported == ImportedScript(title: "Talk", body: "Hello from RTF.\nSecond line — with a dash."))
    }

    @Test func rtfWithOnlyAnAttachmentIsEmpty() throws {
        let url = try write(try rtfData("\u{FFFC}\n  \n"), named: "Picture.rtf")
        #expect(throws: ScriptImportError.empty) { try ScriptImporter.importFile(at: url) }
    }

    @Test func whitespaceOnlyFileIsEmpty() throws {
        let url = try write(" \n\t\r\n  \u{00A0}", named: "Blank.txt")
        #expect(throws: ScriptImportError.empty) { try ScriptImporter.importFile(at: url) }
    }

    @Test func unsupportedTypeReportsTheExtension() throws {
        let url = try write("PK", named: "Slides.docx")
        #expect(throws: ScriptImportError.unsupportedType("docx")) { try ScriptImporter.importFile(at: url) }
    }

    @Test func missingFileIsUnreadable() {
        let url = directory.appending(path: "Missing.txt")
        #expect(throws: ScriptImportError.unreadable) { try ScriptImporter.importFile(at: url) }
    }

    @Test func errorMessages() {
        #expect(ScriptImportError.unsupportedType("docx").message == "Prompter can import .txt, .md, .rtf and .pdf files.")
        #expect(ScriptImportError.unreadable.message == "The file couldn't be read.")
        #expect(ScriptImportError.empty.message == "The file has no text.")
        #expect(ScriptImportError.noTextInPDF.message == "This PDF has no text to import (it may be a scan).")
    }

    // MARK: PDF

    @Test func importsATwoPagePDFWithABlankLineBetweenPages() throws {
        let data = makePDFData(pages: [
            ["Welcome to the show.", "Today we talk about cameras."],
            ["Second page starts here."],
        ])
        let url = try write(data, named: "Episode 12.pdf")
        let imported = try ScriptImporter.importFile(at: url)
        #expect(imported.title == "Episode 12")
        #expect(imported.body == "Welcome to the show.\nToday we talk about cameras.\n\nSecond page starts here.")
    }

    @Test func pdfSkipsPagesWithoutText() throws {
        let data = makePDFData(pages: [["First page."], [], ["Third page."]])
        let url = try write(data, named: "Gaps.pdf")
        #expect(try ScriptImporter.importFile(at: url).body == "First page.\n\nThird page.")
    }

    @Test func pdfRejoinsWordsHyphenatedAcrossALineBreak() throws {
        let data = makePDFData(pages: [["This is an exam-", "ple of e-mail and well-known words."]])
        let url = try write(data, named: "Hyphens.pdf")
        #expect(try ScriptImporter.importFile(at: url).body == "This is an example of e-mail and well-known words.")
    }

    @Test func rejoinHyphenatedWordsOnlyTouchesLineEndBreaksBeforeALowercaseLetter() {
        #expect(ScriptImporter.rejoinHyphenatedWords(in: "an exam-\nple here") == "an example here")
        #expect(ScriptImporter.rejoinHyphenatedWords(in: "e-mail and well-known") == "e-mail and well-known")
        #expect(ScriptImporter.rejoinHyphenatedWords(in: "Smith-\nJones") == "Smith-\nJones")
        #expect(ScriptImporter.rejoinHyphenatedWords(in: "end-\n\nnext") == "end-\n\nnext")
        #expect(ScriptImporter.rejoinHyphenatedWords(in: "a dash -\nthen") == "a dash -\nthen")
        #expect(ScriptImporter.rejoinHyphenatedWords(in: "year 2024-\nlater") == "year 2024-\nlater")
        #expect(ScriptImporter.rejoinHyphenatedWords(in: "soft exam\u{00AD}\nple, caf\u{2010}\nés") == "soft example, cafés")
        #expect(ScriptImporter.rejoinHyphenatedWords(in: "in-\nter-\nnational") == "international")
    }

    @Test func pdfWithoutTextIsEmpty() throws {
        let data = makePDFData(pages: [["Scanned words that are only pixels."], ["More pixels."]], scanned: true)
        let url = try write(data, named: "Scan.pdf")
        #expect(throws: ScriptImportError.noTextInPDF) { try ScriptImporter.importFile(at: url) }

        let blank = try write(makePDFData(pages: [[], []]), named: "Blank.pdf")
        #expect(throws: ScriptImportError.noTextInPDF) { try ScriptImporter.importFile(at: blank) }
    }

    @Test func garbageNamedPDFIsUnreadable() throws {
        let url = try write(Data([0x00, 0x13, 0x37, 0xFF, 0xFE, 0x42]), named: "Broken.pdf")
        #expect(throws: ScriptImportError.unreadable) { try ScriptImporter.importFile(at: url) }

        let text = try write("Definitely not a PDF, just words.", named: "Notes.pdf")
        #expect(throws: ScriptImportError.unreadable) { try ScriptImporter.importFile(at: text) }
    }

    @Test func missingPDFIsUnreadable() {
        let url = directory.appending(path: "Missing.pdf")
        #expect(throws: ScriptImportError.unreadable) { try ScriptImporter.importFile(at: url) }
    }

    @Test func passwordProtectedPDFIsUnreadable() throws {
        let data = makePDFData(pages: [["Secret words."]], userPassword: "hunter2")
        let url = try write(data, named: "Locked.pdf")
        #expect(throws: ScriptImportError.unreadable) { try ScriptImporter.importFile(at: url) }
    }

    // MARK: Plain text and titles

    @Test func fromPlainTextUsesTheFirstLineAsTitleAndKeepsIt() throws {
        let imported = try ScriptImporter.fromPlainText("\r\n\r\nBig news\r\nWe launched today.\r\n")
        #expect(imported == ImportedScript(title: "Big news", body: "Big news\nWe launched today."))
    }

    @Test func fromPlainTextRejectsTextWithoutWords() {
        #expect(throws: ScriptImportError.empty) { try ScriptImporter.fromPlainText("") }
        #expect(throws: ScriptImportError.empty) { try ScriptImporter.fromPlainText("  \n\t ") }
        #expect(throws: ScriptImportError.empty) { try ScriptImporter.fromPlainText("— - •") }
    }

    @Test func longFirstLineIsCutAtAWordBoundary() {
        let line = "This opening line is deliberately far too long to fit in a library title without being cut"
        let title = ScriptImporter.title(fromFirstLineOf: line + "\nSecond line")
        #expect(title.hasSuffix("…"))
        #expect(title.count <= 61)

        let head = String(title.dropLast())
        #expect(line.hasPrefix(head))
        #expect(line[line.index(line.startIndex, offsetBy: head.count)] == " ")
    }

    @Test func titleEdgeCases() {
        #expect(ScriptImporter.title(fromFirstLineOf: "\n \n  Short  \nNext") == "Short")
        #expect(ScriptImporter.title(fromFirstLineOf: " \n ") == "")
        #expect(ScriptImporter.title(fromFirstLineOf: "Exactly ten", maxLength: 11) == "Exactly ten")
        #expect(ScriptImporter.title(fromFirstLineOf: "Hello, wonderful world", maxLength: 12) == "Hello…")

        let oneLongWord = String(repeating: "a", count: 80)
        #expect(ScriptImporter.title(fromFirstLineOf: oneLongWord) == String(repeating: "a", count: 60) + "…")
    }
}
