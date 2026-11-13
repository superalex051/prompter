import Foundation
import Testing
@testable import Prompter

/// A speech source that hears whatever the test says.
@MainActor
final class FakeSpeechSource: SpeechSource {
    var onWords: (([String]) -> Void)?
    var onFailure: ((VoiceProblem) -> Void)?
    /// What `prepare()` answers.
    var problem: VoiceProblem?
    private(set) var prepareCount = 0
    private(set) var startCount = 0
    private(set) var isListening = false
    private var heard: [String] = []

    func prepare() async -> VoiceProblem? {
        prepareCount += 1
        return problem
    }

    func start() {
        isListening = true
        startCount += 1
        heard = []
    }

    func stop() {
        isListening = false
        heard = []
    }

    /// The reader says `text`, delivered word by word like a growing partial result (only while listening).
    func say(_ text: String) {
        for word in text.split(separator: " ") where isListening {
            heard.append(String(word))
            onWords?(heard)
        }
    }

    func forgetHeard() {
        heard = []
    }

    func fail(_ problem: VoiceProblem) {
        isListening = false
        onFailure?(problem)
    }
}

/// Voice-follow end to end with a fake microphone: permission, listening only while playing, following, falling back.
@MainActor
struct VoiceFollowControllerTests {
    static let body = """
        Hello and welcome to the show.
        Today we talk about acrylic glass.
        It reflects the screen like a mirror.
        Thanks for watching and see you soon.
        """

    @MainActor
    struct Rig {
        let engine: ScrollEngine
        let clock: ManualClock
        let source: FakeSpeechSource
        let controller: VoiceFollowController
        let document: PrompterDocument

        /// Ticks at 120 Hz for `seconds`.
        func run(_ seconds: Double) {
            for _ in 0..<Int((seconds * 120).rounded()) {
                clock.now += 1.0 / 120
                engine.tick(now: clock.now)
            }
        }
    }

    /// One 100 pt line per paragraph, so paragraph n sits at y = 100·n.
    static func layout(for document: PrompterDocument) -> PrompterLayout {
        var lines: [PrompterLayout.Line] = []
        var offset = 0
        for (index, paragraph) in document.paragraphs.enumerated() {
            lines.append(PrompterLayout.Line(y: Double(index) * 100, height: 100, characterIndex: offset, startsParagraph: true))
            offset += paragraph.text.utf16.count + 1
        }
        return PrompterLayout(lines: lines, contentHeight: Double(lines.count) * 100, wordCount: document.timedWordCount)
    }

    func makeRig(
        mode: PrompterSettings.ScrollMode = .voice,
        problem: VoiceProblem? = nil
    ) async -> Rig {
        var settings = PrompterSettings()
        settings.countdownSeconds = 0
        settings.scrollMode = mode
        settings.wordsPerMinute = 140
        let clock = ManualClock()
        let engine = ScrollEngine(settings: settings, now: { clock.now })
        let document = PrompterDocument(body: Self.body)
        engine.updateLayout(Self.layout(for: document))
        let source = FakeSpeechSource()
        source.problem = problem
        let controller = VoiceFollowController(engine: engine, document: document, source: source, startDelay: .zero)
        await controller.preparation?.value
        return Rig(engine: engine, clock: clock, source: source, controller: controller, document: document)
    }

    // MARK: The aligner

    /// Most takes never use voice: the aligner (which breaks the whole script into tokens) is only built once the
    /// prompter is in voice mode.
    @Test func theAlignerIsBuiltOnlyInVoiceMode() async {
        let rig = await makeRig(mode: .wpm)
        #expect(rig.controller.aligner == nil)
        rig.engine.start()
        rig.run(1)
        #expect(rig.controller.aligner == nil)

        rig.engine.settings.scrollMode = .voice
        #expect(rig.controller.aligner != nil)
        #expect(rig.controller.aligner?.words.count == rig.document.timedWordCount)
    }

    /// A script with CJK numerals used to crash the prompter as it opened, in any mode (the aligner was built eagerly
    /// and its tokenizer indexed past the digit words). It opens, and voice mode builds its aligner, without trouble.
    @Test func aScriptWithCJKNumeralsOpensInEveryMode() async {
        let body = "売上は⑳％増の一千二百三十四万五千円、2.5万人。\nThanks for watching."
        for mode in PrompterSettings.ScrollMode.allCases {
            var settings = PrompterSettings()
            settings.scrollMode = mode
            let controller = PrompterController(
                scriptTitle: "CJK", body: body, settings: settings, makeSpeechSource: { _ in FakeSpeechSource() }
            )
            await controller.voice.preparation?.value
            #expect((controller.voice.aligner != nil) == (mode == .voice))
            controller.close()
        }
    }

    // MARK: Review focus: denied or unavailable

    @Test func deniedFallsBackToWPM() async {
        let rig = await makeRig(problem: .microphoneDenied)
        #expect(rig.source.prepareCount == 1)
        #expect(rig.engine.voiceProblem == .microphoneDenied)
        #expect(rig.engine.speedLabel == "140 wpm")
        #expect(PrompterHUD.notice(state: rig.engine.state, isVoiceMode: true, problem: rig.engine.voiceProblem)
            == "Voice needs microphone access. Scrolling at your set pace instead.")

        rig.engine.start()
        #expect(rig.engine.state == .playing)
        await rig.controller.preparation?.value   // one retry per take (still denied)
        #expect(rig.source.prepareCount == 2)
        #expect(rig.source.startCount == 0)       // the microphone never came on
        #expect(!rig.engine.isAwaitingVoice)
        let speed = rig.engine.pointsPerSecond
        rig.run(3)
        #expect(abs(rig.engine.position - 3 * speed) < 0.01)   // scrolling at 140 wpm, no crash, no silent nothing
        #expect(rig.engine.settings.scrollMode == .voice)       // the choice is kept for when access is granted
    }

    @Test(arguments: [VoiceProblem.speechDenied, .unsupported, .modelUnavailable])
    func everyProblemFallsBackToWPM(problem: VoiceProblem) async {
        let rig = await makeRig(problem: problem)
        #expect(rig.engine.voiceProblem == problem)
        #expect(rig.engine.speedLabel == "140 wpm")
        rig.engine.start()
        rig.run(1)
        #expect(rig.engine.position > 0)
        #expect(!problem.message.isEmpty && problem.message.hasSuffix("Scrolling at your set pace instead."))
    }

    @Test func accessGrantedLaterIsPickedUpAtTheNextStart() async {
        let rig = await makeRig(problem: .microphoneDenied)
        rig.source.problem = nil                  // turned on in the Settings app meanwhile
        rig.engine.start()
        await rig.controller.preparation?.value
        #expect(rig.engine.voiceProblem == nil)
        #expect(rig.engine.speedLabel == "Voice")
        #expect(rig.source.isListening)
        #expect(rig.engine.isAwaitingVoice)
    }

    @Test func aFailureWhileListeningFallsBackMidTake() async {
        let rig = await makeRig()
        rig.engine.start()
        #expect(rig.source.isListening)
        rig.source.fail(.failed)
        #expect(rig.engine.voiceProblem == .failed)
        #expect(rig.engine.speedLabel == "140 wpm")
        #expect(rig.engine.state == .playing)
        rig.run(1)
        #expect(rig.engine.position > 0)
    }

    // MARK: The microphone

    @Test func listensOnlyWhilePlaying() async {
        let rig = await makeRig()
        #expect(rig.source.prepareCount == 1)     // got ready as the prompter opened, before any start
        #expect(!rig.source.isListening)
        rig.engine.start()
        #expect(rig.source.isListening)
        #expect(rig.controller.isListening)
        rig.engine.pause()
        #expect(!rig.source.isListening)
        rig.engine.resume()
        #expect(rig.source.isListening)
        rig.engine.backToTop()
        #expect(!rig.source.isListening)
        rig.engine.start()
        #expect(rig.source.isListening)
        rig.controller.close()
        #expect(!rig.source.isListening)
        rig.engine.pause()
        rig.engine.resume()
        #expect(!rig.source.isListening)          // closed for good
    }

    @Test func otherModesNeverAskForTheMicrophone() async {
        let rig = await makeRig(mode: .wpm)
        rig.engine.start()
        rig.run(1)
        #expect(rig.source.prepareCount == 0)
        #expect(rig.source.startCount == 0)
        rig.engine.settings.scrollMode = .voice   // picked in the settings over the prompter, mid-take
        await rig.controller.preparation?.value
        #expect(rig.source.prepareCount == 1)
        #expect(rig.source.isListening)
        rig.engine.settings.scrollMode = .speed
        #expect(!rig.source.isListening)
    }

    @Test func thePrompterClosingTurnsTheMicrophoneOff() async {
        let source = FakeSpeechSource()
        var settings = PrompterSettings()
        settings.scrollMode = .voice
        settings.countdownSeconds = 0
        let controller = PrompterController(scriptTitle: "T", body: Self.body, settings: settings) { _ in source }
        await controller.voice.preparation?.value
        controller.engine.updateLayout(Self.layout(for: controller.document))
        controller.engine.start()
        #expect(controller.voice.isListening)
        #expect(!source.isListening)              // the microphone waits a moment after "go", so it never clips the sound
        try? await Task.sleep(for: .milliseconds(700))
        #expect(source.isListening)
        controller.close()
        #expect(!source.isListening)
        #expect(controller.engine.state == .paused)
    }

    // MARK: Following

    @Test func followsTheReaderLineByLine() async {
        let rig = await makeRig()
        rig.engine.start()
        rig.source.say("Hello and welcome to the")
        rig.run(1)
        #expect(rig.engine.position == 0)         // still on the first line
        rig.source.say("show.")
        #expect(!rig.engine.isAwaitingVoice)
        rig.run(1)
        #expect(rig.engine.position == 100)       // its last word heard: the next line comes up
        rig.source.say("Today we talk about acrylic glass. It reflects")
        rig.run(1)
        #expect(rig.engine.position == 200)
    }

    @Test func anAdLibHoldsTheTextAndSaysListening() async {
        let rig = await makeRig()
        rig.engine.start()
        rig.source.say("Hello and welcome to the show.")
        rig.run(1)
        #expect(rig.engine.position == 100)
        rig.source.say("oh hang on my phone is buzzing sorry")
        rig.run(2.5)
        #expect(rig.engine.position == 100)
        #expect(rig.engine.isAwaitingVoice)
        rig.source.say("today we talk about acrylic glass.")
        #expect(!rig.engine.isAwaitingVoice)
        rig.run(1)
        #expect(rig.engine.position == 200)
    }

    @Test func aStepByHandPicksUpFromTheNewPlace() async {
        let rig = await makeRig()
        rig.engine.start()
        rig.source.say("Hello and welcome")
        rig.engine.stepParagraph(2)               // to "It reflects the screen like a mirror."
        #expect(rig.engine.position == 200)
        rig.source.say("it reflects the screen like a mirror.")
        rig.run(1)
        #expect(rig.engine.position == 300)
    }

    /// Stepping back by hand to re-read: the words heard before the step (further on in the script) must not pull the
    /// text forward again.
    @Test func aStepBackByHandIsNotUndoneByWordsHeardBefore() async {
        let rig = await makeRig()
        rig.engine.start()
        rig.source.say("Hello and welcome to the show. Today we talk about acrylic glass.")
        rig.run(1.5)
        #expect(rig.engine.position == 200)
        rig.engine.stepParagraph(-2)              // back to the top to read it again
        #expect(rig.engine.position == 0)
        rig.source.say("Hello")                   // the first words after the step only re-sync
        rig.source.say("and welcome")
        rig.run(1)
        #expect(rig.engine.position == 0)
        rig.source.say("to the show.")
        rig.run(1)
        #expect(rig.engine.position == 100)
    }

    @Test func theLastWordFinishesTheTake() async {
        let rig = await makeRig()
        rig.engine.start()
        rig.source.say(Self.body.replacingOccurrences(of: "\n", with: " "))
        rig.run(3)
        #expect(rig.engine.state == .finished)
        #expect(!rig.source.isListening)
    }

    @Test func wordsHeardWhilePausedAreIgnored() async {
        let rig = await makeRig()
        rig.engine.start()
        rig.engine.pause()
        rig.source.start()                        // a late callback from the recogniser
        rig.source.say("Hello and welcome to the show.")
        rig.run(1)
        #expect(rig.engine.position == 0)
    }
}
