import SwiftUI

/// The small status strip at the bottom of the canvas (mirrored with the text): time remaining, the state word,
/// the speed, and a thin progress bar. Reads the engine's observed values, which change a few times per second at most.
/// In voice mode the state word is "Listening…" while the text waits for the reader, and when voice can't listen a
/// line above says why (except while the text is moving, when the speed label already says "140 wpm").
struct PrompterHUD: View {
    let engine: ScrollEngine
    let foreground: Color
    let background: Color
    /// The progress bar: the scheme's cue colour (`PrompterSettings.Scheme.cueUIColor`), so it shows on white too.
    var accent: Color = .accentColor
    let horizontalInset: Double
    let fontSize: Double

    var body: some View {
        let state = engine.state
        let remaining = engine.remainingSeconds
        let speedLabel = engine.speedLabel
        let hold = engine.holdSecondsLeft
        let isListening = engine.isAwaitingVoice
        let notice = Self.notice(state: state, isVoiceMode: engine.isVoiceMode, problem: engine.voiceProblem)

        VStack(spacing: 6) {
            if let notice {
                Text(notice)
                    .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(foreground.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .accessibilityIdentifier("prompter.voiceNotice")
            }
            ZStack {
                HStack {
                    Text(TimeFormatting.clock(remaining))
                    Spacer(minLength: 16)
                    Text(speedLabel)
                }
                if let word = Self.stateWord(for: state, holdSeconds: hold, isListening: isListening) {
                    Text(word)
                }
            }
            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(foreground.opacity(0.8))
            .lineLimit(1)

            ProgressBar(engine: engine, track: foreground.opacity(0.2), fill: accent)
        }
        .padding(.horizontal, horizontalInset)
        .padding(.top, Self.feather + 8)
        .padding(.bottom, 10)
        .background {
            // The text scrolls underneath: a short fade, then a fully opaque strip behind the labels and the bar, so not
            // a trace of a line shows through them.
            VStack(spacing: 0) {
                LinearGradient(colors: [background.opacity(0), background], startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.feather)
                Rectangle().fill(background)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(
            state: state, remainingSeconds: remaining, speedLabel: speedLabel, holdSeconds: hold,
            isListening: isListening, notice: notice
        ))
        .accessibilityIdentifier("prompter.hud")
    }

    /// The fade above the HUD's opaque strip, in points.
    static let feather = 16.0

    /// "Tap to start" (idle: what to do, where VoiceOver says "Ready"), "Paused" or "End"; "Pause 3" while a `[pause 3]`
    /// cue holds the text; "Listening…" while voice mode waits for the reader; nothing while counting down or scrolling.
    nonisolated static func stateWord(for state: PlaybackState, holdSeconds: Int? = nil, isListening: Bool = false) -> String? {
        switch state {
        case .idle: "Tap to start"
        case .paused: "Paused"
        case .finished: "End"
        case .playing: holdSeconds.map(holdWord) ?? (isListening ? "Listening…" : nil)
        case .countdown: nil
        }
    }

    /// "Pause 3": the cue's own word, with the whole seconds it still holds.
    nonisolated static func holdWord(_ seconds: Int) -> String {
        "Pause \(seconds)"
    }

    /// Voice mode that can't listen: why, and that WPM is used instead. Not while the text moves (the speed label says
    /// "140 wpm" then) and never in the other modes.
    nonisolated static func notice(state: PlaybackState, isVoiceMode: Bool, problem: VoiceProblem?) -> String? {
        guard isVoiceMode, let problem, state != .playing else { return nil }
        return problem.message
    }

    /// "Ready, 1:12 left, 140 wpm" (idle: the screen shows "Tap to start", but "Ready" is the state); "Pause 3, 1:12 left,
    /// 140 wpm" during a hold; "Listening…, 1:12 left, Voice"; a voice notice goes first.
    nonisolated static func accessibilityText(
        state: PlaybackState,
        remainingSeconds: Double,
        speedLabel: String,
        holdSeconds: Int? = nil,
        isListening: Bool = false,
        notice: String? = nil
    ) -> String {
        let word = switch state {
        case .idle: "Ready"
        case .countdown(let n): "Starting in \(n)"
        case .playing: holdSeconds.map(holdWord) ?? (isListening ? "Listening…" : "Playing")
        case .paused: "Paused"
        case .finished: "End"
        }
        let status = "\(word), \(TimeFormatting.clock(remainingSeconds)) left, \(speedLabel)"
        return notice.map { "\($0) \(status)" } ?? status
    }
}

/// Reads `engine.progress` in its own body, so only the bar re-renders when progress ticks (up to ~15 times a second
/// on a short script); the labels above it change about once a second.
private struct ProgressBar: View {
    let engine: ScrollEngine
    let track: Color
    let fill: Color

    var body: some View {
        let progress = engine.progress
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(fill)
                    .frame(width: proxy.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: 3)
    }
}
