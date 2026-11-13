import SwiftUI

/// One open prompter: the script, its scroll engine, and the link to the text view that draws it.
///
/// `PrompterScreen` creates it when the prompter opens. It owns `engine.onEvent` (sounds + waking the display link);
/// anything else that drives the engine from outside the view (the watch in M3) just calls the engine's commands: state
/// changes wake the display link through the canvas, and paused steps fire `.jumped`, which wakes it here.
@MainActor
final class PrompterController {
    let scriptTitle: String
    /// The script as shown (blank lines dropped, notes and pause cues marked, Markdown applied if it's on), read once
    /// when the prompter opens and rebuilt only when Markdown formatting is switched (`showMarkdown(_:)`).
    private(set) var document: PrompterDocument
    /// The script's text as written.
    private let body: String
    private var showsMarkdown: Bool
    let engine: ScrollEngine
    /// Listens in voice mode and moves the text with the reader (idle in the other modes).
    let voice: VoiceFollowController
    /// Set by the canvas when it creates the text view.
    weak var textView: PrompterTextView?

    /// `makeSpeechSource` is where voice mode hears from: the microphone in the app, a fake in tests.
    init(
        scriptTitle: String,
        body: String,
        settings: PrompterSettings,
        makeSpeechSource: (PrompterDocument) -> SpeechSource = { LiveSpeechSource.make(for: $0) }
    ) {
        self.scriptTitle = scriptTitle
        self.body = body
        showsMarkdown = settings.markdown
        document = PrompterDocument(body: body, markdown: settings.markdown)
        engine = ScrollEngine(settings: settings)
        voice = VoiceFollowController(engine: engine, document: document, source: makeSpeechSource(document))
        engine.onEvent = { [weak self] event in self?.handle(event) }
    }

    /// The prompter is going away: the microphone goes off and the take stops.
    func close() {
        voice.close()
        engine.pause()
    }

    /// Settings → Markdown formatting, switched while the prompter is open (from its settings): the document is rebuilt.
    /// The text view lays the new one out and hands the engine the new layout, which keeps the reading line on the same
    /// place; voice-follow picks up the new words.
    func showMarkdown(_ markdown: Bool) {
        guard markdown != showsMarkdown else { return }
        showsMarkdown = markdown
        document = PrompterDocument(body: body, markdown: markdown)
        voice.documentChanged(document)
    }

    /// The text TextKit lays out.
    var text: String { document.text }

    var isEmpty: Bool { document.isEmpty }

    /// Hardware keys go to the text view again (after the settings sheet closes).
    func focusKeys() {
        textView?.focusKeys()
    }

    /// The scene's phase changed. Any phase but `.active` (a phone call, Siri, Control Center, the side button) stops the
    /// take where it is: a countdown is cancelled and playback pauses, so the text never scrolls on unseen and no
    /// countdown fires "go" on the way back. Coming back changes nothing; the take waits for Start.
    /// Returns true when the phase interrupts the take (the screen then tells the watch straight away).
    @discardableResult
    func sceneChanged(to phase: ScenePhase) -> Bool {
        guard phase != .active else { return false }
        engine.pause()
        return true
    }

    private func handle(_ event: ScrollEngine.Event) {
        PrompterFeedback.play(for: event, settings: engine.settings)
        textView?.wakeDisplayLink()
    }
}
