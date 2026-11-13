import Foundation
import Testing
import UIKit
@testable import Prompter

/// Markdown through the iPhone's prompter: the text view, voice-follow, the editor tip and the launch route.
@MainActor
struct MarkdownPrompterTests {
    private let size = CGSize(width: 874, height: 402)

    /// Voice-follow listens for the words the prompter shows: no `**`, no link address, no heading, no bullet.
    @Test func voiceWordIndexIgnoresMarkers() {
        let body = "# Intro\nSay **this** now.\n- Read [the site](https://example.com/page).\n// a *note*"
        let document = PrompterDocument(body: body, markdown: true)
        let aligner = VoiceAligner(document: document)
        let text = document.text as NSString
        let words = aligner.words.map { text.substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count)) }
        #expect(words == ["Say", "this", "now.", "Read", "the", "site."])
        #expect(aligner.tokens.map(\.text) == ["say", "this", "now", "read", "the", "site"])
        let vocabulary = VoiceVocabulary.words(in: document)
        #expect(!vocabulary.contains { $0.contains("*") || $0.contains("http") || $0 == "Intro" })
    }

    @Test func controllerFollowsTheSetting() {
        let body = "# Intro\nSay **this**."
        var settings = PrompterSettings()
        #expect(PrompterController(scriptTitle: "T", body: body, settings: settings).text == "Intro\nSay this.")
        settings.markdown = false
        #expect(PrompterController(scriptTitle: "T", body: body, settings: settings).text == body)
    }

    /// Switching Markdown formatting in the prompter's settings rebuilds the text, and the engine gets the new words.
    @Test func switchingMarkdownWhileOpenRelaysTheText() {
        let body = "# Intro\nSay **this** and that.\n" + String(repeating: "More words to read here. ", count: 40)
        let settings = PrompterSettings()
        let controller = PrompterController(scriptTitle: "T", body: body, settings: settings)
        let view = PrompterTextView(engine: controller.engine)
        controller.textView = view
        view.update(document: controller.document, settings: settings)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()
        let wordsOn = controller.engine.layout.wordCount
        #expect(wordsOn == controller.document.timedWordCount)

        var off = settings
        off.markdown = false
        controller.showMarkdown(off.markdown)
        view.update(document: controller.document, settings: off)
        #expect(controller.text.hasPrefix("# Intro\nSay **this**"))
        // Off, the heading's word is read and counted too.
        #expect(controller.engine.layout.wordCount == wordsOn + 1)
        #expect(controller.engine.layout.wordCount == ReadingStats(text: body).wordCount)
    }

    /// The view-less extraction (the Mac's) matches what the iPhone's text view lays out, for a Markdown script too.
    @Test func viewlessLayoutMatchesTheTextViewWithMarkdown() throws {
        let document = PrompterDocument(body: DemoData.markdownBody, markdown: true)
        let style = PrompterTextStyle(settings: PrompterSettings(), canvasSize: size, isPad: false)
        let textView = UITextView(usingTextLayoutManager: true)
        textView.frame = CGRect(origin: .zero, size: size)
        textView.textContainer.lineFragmentPadding = 0
        textView.attributedText = PrompterText.attributedString(document, style: style)
        textView.textContainerInset = style.textContainerInset
        textView.layoutIfNeeded()
        let manager = try #require(textView.textLayoutManager)
        let fromView = PrompterLayoutExtractor.layout(of: manager, document: document)
        let viewless = PrompterLayoutExtractor.layout(of: document, style: style)
        #expect(!viewless.lines.isEmpty)
        #expect(viewless == fromView)
    }

    @Test func editorTipMentionsMarkdownWhenItIsOn() {
        #expect(EditorTip.text(markdown: false) == EditorTip.text)
        #expect(EditorTip.text(markdown: true)
            == "Tip: start a line with // for a note, or write [pause 2] to hold. Markdown works too: **bold** shows in amber, # starts a heading.")
    }

    @Test func settingsFooterExplainsMarkdown() {
        #expect(PrompterSettingsSections.textFooter(markdown: true).contains("**bold** shows in amber"))
        #expect(PrompterSettingsSections.textFooter(markdown: false).contains("off"))
    }

    @Test func markdownLaunchRouteOpensTheMarkdownDemo() {
        #expect(LaunchOptions(arguments: ["-script", "markdown"]).script == .markdown)
        let scripts = DemoData.scripts(now: Date(timeIntervalSince1970: 1_800_000_000), includeMarkdown: true)
        #expect(scripts.count == 5)
        #expect(DemoData.scripts(now: Date(timeIntervalSince1970: 1_800_000_000)).count == 4)
        var route = LaunchRoute(route: .prompter, script: .markdown)
        #expect(route.next(isLoading: false, scripts: scripts) == .openPrompter(DemoData.markdownScriptID, autoStart: false))
    }
}
