import AppKit
import CoreText
import Foundation
import Testing
@testable import PrompterMac

// The shared core (Core/) compiled for macOS: storage, import, the text builder, TextKit 2 layout and the engine.

/// A fresh temp directory per test, removed afterwards.
private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "PrompterMacTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A clock that moves only when a test moves it.
private final class ManualClock: @unchecked Sendable {
    var now: TimeInterval = 1_000
}

@MainActor
struct ScriptStoreOnMacTests {
    @Test func libraryRoundTripsThroughTheJSONFile() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = ManualClock()
        let store = ScriptStore(
            directory: directory, now: { Date(timeIntervalSince1970: 1_800_000_000 + clock.now) }, initialScripts: { _ in [] }
        )
        #expect(store.scripts.isEmpty)
        #expect(store.isWaitingForProtectedData == false)

        let first = store.create(title: "Intro", body: "Hello from the Mac.")
        clock.now += 60
        let pasted = store.createFromText("Second take\n\nMore words here.")
        #expect(pasted != nil)
        let second = pasted!
        clock.now += 60
        store.update(first.id, body: "Hello again from the Mac.")
        #expect(store.lastError == nil)

        let reloaded = ScriptStore(directory: directory, initialScripts: { _ in [] })
        #expect(reloaded.scripts == store.scripts)
        #expect(reloaded.scripts.map(\.id) == [first.id, second.id])   // newest edit first
        #expect(reloaded.script(id: first.id)?.body == "Hello again from the Mac.")
        #expect(reloaded.script(id: second.id)?.title == "Second take")
    }

    @Test func firstLaunchSeedsTheInitialScripts() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScriptStore(directory: directory, initialScripts: { DemoData.scripts(now: $0) })
        #expect(store.scripts.count == 4)
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path(percentEncoded: false)))
    }

    @Test func defaultDirectoryIsApplicationSupportPrompter() {
        let url = ScriptStore.defaultDirectory
        #expect(url.lastPathComponent == "Prompter")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Application Support")
    }

    @Test func messagesSayMac() {
        #expect(ScriptStore.saveFailedMessage.contains("Mac"))
        #expect(ScriptStore.corruptFileMessage.contains("Mac"))
    }

    @Test func settingsRoundTripThroughUserDefaults() throws {
        // One fixed suite (the Mac tests aren't sandboxed, so each suite is a plist in ~/Library/Preferences), emptied
        // before and after.
        let suite = "PrompterMacTests"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        #expect(store.isWaitingForProtectedData == false)
        store.settings.fontSize = 96
        store.settings.scrollMode = .speed
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.settings.fontSize == 96)
        #expect(reloaded.settings.scrollMode == .speed)
    }
}

struct ScriptImporterOnMacTests {
    @Test func importsRTF() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = NSAttributedString(string: "Hello, Mac.\nSecond line with **bold** words.", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 14),
        ])
        let data = try source.data(
            from: NSRange(location: 0, length: source.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let url = directory.appending(path: "Rich Notes.rtf")
        try data.write(to: url)

        let imported = try ScriptImporter.importFile(at: url)
        #expect(imported.title == "Rich Notes")
        #expect(imported.body == "Hello, Mac.\nSecond line with **bold** words.")
    }

    @Test func importsAPDFPageByPage() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Episode 12.pdf")
        try makePDF(pages: ["First page words.", "Second page words."], at: url)

        let imported = try ScriptImporter.importFile(at: url)
        #expect(imported.title == "Episode 12")
        #expect(imported.body == "First page words.\n\nSecond page words.")
    }

    @Test func plainTextAndPaste() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "notes.txt")
        try Data("Line one\r\nLine two\r\n".utf8).write(to: url)
        #expect(try ScriptImporter.importFile(at: url) == ImportedScript(title: "notes", body: "Line one\nLine two"))
        #expect(try ScriptImporter.fromPlainText("  Pasted title\nbody") == ImportedScript(title: "Pasted title", body: "  Pasted title\nbody"))
    }

    /// A text PDF drawn with Core Text, one string per page.
    private func makePDF(pages: [String], at url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        for text in pages {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ]))
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
    }
}

@MainActor
struct PrompterTextOnMacTests {
    private let canvas = CGSize(width: 1440, height: 900)

    @Test func builderUsesAppKitFontsAndColours() throws {
        let document = PrompterDocument(body: "Read this line.\n// a note\n[pause 2]\nAnd this one.")
        let style = PrompterTextStyle(settings: PrompterSettings(), canvasSize: canvas, isPad: false)
        let string = PrompterText.attributedString(document, style: style)
        #expect(string.string == document.text)

        let textFont = try #require(string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(textFont.pointSize == 72)
        #expect((string.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) == .white)

        let noteIndex = (document.text as NSString).range(of: "a note").location
        let noteFont = try #require(string.attribute(.font, at: noteIndex, effectiveRange: nil) as? NSFont)
        #expect(noteFont.fontDescriptor.symbolicTraits.contains(.italic))
        #expect(abs(noteFont.pointSize - 72 * PrompterText.noteScale) < 0.01, "\(noteFont.pointSize)")

        let cueIndex = (document.text as NSString).range(of: "PAUSE 2s").location
        let cueColour = try #require(string.attribute(.foregroundColor, at: cueIndex, effectiveRange: nil) as? NSColor)
        #expect(cueColour == PrompterSettings.Scheme.whiteOnBlack.cueColor)
        #expect(PrompterSettings.Scheme.blackOnWhite.backgroundColor == .white)
    }

    @Test func lineSpacingUsesTheFontsLineHeight() {
        var settings = PrompterSettings()
        settings.lineSpacing = 2
        let style = PrompterTextStyle(settings: settings, canvasSize: canvas, isPad: false)
        let font = NSFont.systemFont(ofSize: 72, weight: .heavy)
        #expect(font.prompterLineHeight > 72)
        #expect(style.lineSpacing(for: font) == font.prompterLineHeight)
        #expect(style.textWidth == canvas.width * (1 - 2 * settings.sideMargin))
    }

    @Test func viewlessLayoutExtractionProducesLines() {
        let document = PrompterDocument(body: SampleScript.body)
        let style = PrompterTextStyle(settings: PrompterSettings(), canvasSize: canvas, isPad: false)
        let layout = PrompterLayoutExtractor.layout(of: document, style: style)

        #expect(layout.lines.count > document.paragraphs.count)   // long paragraphs wrap at 72 pt
        #expect(layout.lines.first?.y == 0)
        #expect(layout.lines.first?.startsParagraph == true)
        #expect(zip(layout.lines, layout.lines.dropFirst()).allSatisfy { $0.y < $1.y })
        #expect(layout.contentHeight > layout.lines.last!.y)
        #expect(layout.wordCount == document.timedWordCount)
        #expect(layout.holds.count == 1)
        #expect(layout.holds.first?.seconds == 2)
        #expect(layout.timedHeight > 0 && layout.timedHeight < layout.contentHeight)   // the note and the cue aren't timed
    }

    @Test func narrowerTextWrapsIntoMoreLines() {
        let document = PrompterDocument(body: SampleScript.body)
        var settings = PrompterSettings()
        let wide = PrompterLayoutExtractor.layout(of: document, style: PrompterTextStyle(settings: settings, canvasSize: canvas, isPad: false))
        settings.sideMargin = 0.25
        let narrow = PrompterLayoutExtractor.layout(of: document, style: PrompterTextStyle(settings: settings, canvasSize: canvas, isPad: false))
        #expect(narrow.lines.count > wide.lines.count)
    }

    @Test func emptyDocumentHasAnEmptyLayout() {
        let style = PrompterTextStyle(settings: PrompterSettings(), canvasSize: canvas, isPad: false)
        #expect(PrompterLayoutExtractor.layout(of: PrompterDocument.empty, style: style) == .empty)
    }

    @Test func canvasTransformMirrors() {
        let transform = PrompterCanvasTransform.make(rotation: .none, mirror: true, flip: false, canvasSize: canvas)
        let point = CGPoint(x: 100, y: 50).applying(transform)
        #expect(point == CGPoint(x: canvas.width - 100, y: 50))
    }
}

@MainActor
struct ScrollEngineOnMacTests {
    @Test func countsDownThenScrolls() {
        let clock = ManualClock()
        var settings = PrompterSettings()
        settings.countdownSeconds = 3
        settings.scrollMode = .speed
        let engine = ScrollEngine(settings: settings, now: { clock.now })
        let style = PrompterTextStyle(settings: settings, canvasSize: CGSize(width: 1440, height: 900), isPad: false)
        let layout = PrompterLayoutExtractor.layout(of: PrompterDocument(body: SampleScript.body), style: style)
        engine.updateLayout(layout)
        var events: [ScrollEngine.Event] = []
        engine.onEvent = { events.append($0) }

        engine.start()
        #expect(engine.state == .countdown(3))
        #expect(engine.needsFrames)

        // 4 s of frames at 60 Hz: 3 s of countdown, then a second of scrolling.
        for _ in 0..<240 {
            clock.now += 1.0 / 60
            engine.tick(now: clock.now)
        }
        #expect(engine.state == .playing)
        #expect(events.contains(.go))
        #expect(engine.position > 0)
        #expect(engine.progress > 0)
        #expect(engine.remainingSeconds > 0)

        engine.togglePlay()
        #expect(engine.state == .paused)
        engine.backToTop()
        #expect(engine.position == 0)
    }
}

struct MacKeyMapTests {
    @Test func mapsKeyCodesLikeTheIPhone() {
        #expect(MacKeyMap.action(forKeyCode: MacKeyMap.KeyCode.space, shift: false) == .togglePlay)
        #expect(MacKeyMap.action(forKeyCode: MacKeyMap.KeyCode.returnKey, shift: false) == .togglePlay)
        #expect(MacKeyMap.action(forKeyCode: MacKeyMap.KeyCode.downArrow, shift: false) == .stepLine(1))
        #expect(MacKeyMap.action(forKeyCode: MacKeyMap.KeyCode.upArrow, shift: true) == .stepParagraph(-1))
        #expect(MacKeyMap.action(forKeyCode: MacKeyMap.KeyCode.pageDown, shift: false) == .stepLine(1))
        #expect(MacKeyMap.action(forKeyCode: MacKeyMap.KeyCode.equal, shift: true) == .speedStep(5))
        #expect(MacKeyMap.action(forKeyCode: MacKeyMap.KeyCode.keypadMinus, shift: false) == .speedStep(-5))
        #expect(MacKeyMap.action(forKeyCode: MacKeyMap.KeyCode.zero, shift: false) == .backToTop)
        #expect(MacKeyMap.action(forKeyCode: MacKeyMap.KeyCode.escape, shift: false) == .exit)
        #expect(MacKeyMap.action(forKeyCode: 0, shift: false) == nil)   // "a"
    }
}

struct MacLaunchOptionsTests {
    @Test func readsDemoDataInBothSpellings() {
        #expect(MacLaunchOptions(arguments: ["Prompter", "-demoData"], environment: [:]).demoData)
        #expect(MacLaunchOptions(arguments: ["Prompter", "demoData", "true"], environment: [:]).demoData)
        #expect(!MacLaunchOptions(arguments: ["Prompter", "-demoData", "NO"], environment: [:]).demoData)
        #expect(!MacLaunchOptions(arguments: ["Prompter"], environment: [:]).usesThrowawayStorage)
    }

    @Test func theTestHostNeverUsesTheRealLibrary() {
        let options = MacLaunchOptions(arguments: ["Prompter"], environment: ["XCTestConfigurationFilePath": "/tmp/x"])
        #expect(options.isRunningTests)
        #expect(options.usesThrowawayStorage)
    }
}

struct MacLaunchOptionsSnapshotTests {
    @Test func readsSnapshotAndQuitAfter() {
        let options = MacLaunchOptions(arguments: ["Prompter", "-snapshot", "/tmp/shots", "-quitAfter", "2.5"], environment: [:])
        #expect(options.snapshotDirectory?.path(percentEncoded: false) == "/tmp/shots/")
        #expect(options.quitAfter == 2.5)
        #expect(MacLaunchOptions(arguments: ["Prompter", "-quitAfter", "soon"], environment: [:]).quitAfter == nil)
    }
}
