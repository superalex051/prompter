import Foundation
import Observation
import QuartzCore

/// The prompter's state machine: countdown, scrolling in three modes, steps, scrubbing and time remaining.
///
/// Driven entirely by explicit calls: the text view's display link calls `tick(now:)` every frame while `needsFrames`,
/// and touch, keys and (in M3) the watch call the commands. No timers, no UI; time comes from `tick(now:)` and the
/// injected `now` clock (same timebase as `CACurrentMediaTime()` / `CADisplayLink.targetTimestamp`).
///
/// `position` is the y offset into the laid-out text that sits at the reading line (0 = top of the first line at the
/// reading line, `maxPosition` = all text has passed it). See "Engine semantics" in docs/superpowers/plans/2026-10-07-m2-prompter.md.
///
/// Holds (`[pause N]` cues, `layout.holds`): while playing, when the position reaches a cue's line (or playing starts, or
/// a step lands, right on it) the text stands still for N seconds with the state still `.playing` (`isHolding`,
/// `holdSecondsLeft`), then scrolls on. A cue holds once per visit: pausing or dragging during a hold ends it and resuming
/// scrolls straight on; a step, a drag or back to top re-arms it. Time remaining counts the holds still to come; in finish
/// in the holds are part of the chosen time, so the scrolling gets what is left after them (`ScrollTiming.shareBudget`).
///
/// Voice mode (`scrollMode == .voice`): start counts down as usual, then the text stands still and waits for the reader.
/// `VoiceFollowController` listens while `wantsVoiceInput` and calls `followVoice(_:)` with the line the reader has reached;
/// the text eases there (accelerating gently, never faster than 4 lines per second, never jumping). With no new match for
/// 2 s it rests where it is and `isAwaitingVoice` is true (the HUD says "Listening…"). `[pause N]` holds don't apply (the
/// speaker sets the pace), speed steps do nothing, time remaining is the rest of the text at the WPM setting. If voice
/// can't listen (`voiceProblem`), the mode times and scrolls exactly like WPM until the problem is cleared.
@MainActor @Observable
final class ScrollEngine {
    /// Where speech says the reader is.
    enum VoiceTarget: Equatable, Sendable {
        /// The line containing this character (UTF-16 offset) goes to the reading line.
        case character(Int)
        /// The last word was heard: all text passes the reading line, which finishes the take.
        case end
    }

    enum Event: Equatable, Sendable {
        /// A countdown digit appeared (the first one on `start()`).
        case countdownTick(Int)
        /// Scrolling started (end of the countdown, or `start()` with no countdown).
        case go
        /// Playing → paused (pause, toggle, or a drag while playing).
        case paused
        /// Paused → playing.
        case resumed
        /// Reached the end while playing.
        case finished
        /// A step, jump back or back to top moved the text (not fired for drags or relayout).
        case jumped
    }

    /// Mode, speed, WPM, finish-in time and countdown. Assignments are clamped; speed steps write back here.
    var settings: PrompterSettings {
        get { currentSettings }
        set { apply(newValue) }
    }
    private(set) var state: PlaybackState = .idle
    private(set) var layout: PrompterLayout = .empty
    /// Read every frame by the text view; not observed.
    @ObservationIgnored private(set) var position: Double = 0
    /// 0…1, rounded to 0.001 so observers hear about it at most a thousand times per script.
    private(set) var progress: Double = 0
    /// Whole seconds, rounded up (what the HUD and the watch show). `preciseRemainingSeconds` has the exact value.
    private(set) var remainingSeconds: Double = 0
    /// "Speed 3.0", "140 wpm", "Finish in 5:00" or "Voice" (the WPM label while voice can't listen).
    private(set) var speedLabel: String = ""
    /// While a `[pause N]` cue holds the text: the whole seconds left, rounded up (the HUD shows "Pause 3"). nil otherwise.
    /// The state stays `.playing` during a hold.
    private(set) var holdSecondsLeft: Int?
    @ObservationIgnored var onEvent: ((Event) -> Void)?
    /// `start()` was called before there was any text laid out; it starts as soon as a non-empty layout arrives.
    @ObservationIgnored private(set) var isWaitingForLayout = false
    /// Voice mode: why voice can't listen right now (the text then scrolls at the WPM pace); nil when it can. Set by
    /// `VoiceFollowController` through `setVoiceProblem(_:)`.
    private(set) var voiceProblem: VoiceProblem?
    /// Voice mode, playing, and nothing new heard for `ScrollTiming.voiceListeningDelay` (or nothing yet): the HUD says
    /// "Listening…".
    private(set) var isAwaitingVoice = false
    /// Called whenever `isVoiceMode` or `wantsVoiceInput` changes (the voice controller turns the microphone on or off).
    @ObservationIgnored var onVoiceChange: (() -> Void)?
    /// Bumped whenever the text is moved by hand (step, jump back, drag, back to top, restart from the top), so voice-follow
    /// knows to pick up from the new place.
    @ObservationIgnored private(set) var manualMoveCount = 0

    private var currentSettings: PrompterSettings
    private let now: () -> TimeInterval
    /// Finish-in seconds left (meaningful from `start()` on; while idle the effective budget is derived, see `effectiveBudget`).
    @ObservationIgnored private var budget: Double = 0
    @ObservationIgnored private var lastTick: TimeInterval = 0
    @ObservationIgnored private var countdownEnd: TimeInterval = 0
    /// From `start()` until the countdown's first frame: when the countdown began (the `now` clock), so a first frame
    /// that comes much later can tell nobody saw it (see `tick(now:)`).
    @ObservationIgnored private var countdownAwaitingFirstFrame: TimeInterval?
    /// The place to restore when a non-empty layout returns after an empty one.
    @ObservationIgnored private var heldAnchor: PrompterLayout.Anchor?
    /// The cue holding the text right now (its character index) and the seconds it has left.
    @ObservationIgnored private var activeHold: (characterIndex: Int, remaining: Double)?
    /// The cue (character index) whose hold already ran, or was cut short by a pause or a drag, while the text sat at it.
    /// It doesn't hold again until the text is moved some other way than by playing on (a step, a drag, back to top).
    @ObservationIgnored private var spentHold: Int?
    /// Voice mode: where the text is easing to (nil: stay put) and how fast it is moving now (points per second).
    @ObservationIgnored private var voiceTarget: VoiceTarget?
    @ObservationIgnored private var voiceVelocity = 0.0
    /// Voice mode: when speech last matched the script (the clock of `tick(now:)`).
    @ObservationIgnored private var lastVoiceMatch: TimeInterval = 0
    /// What `onVoiceChange` last reported, so it fires only on a change.
    @ObservationIgnored private var reportedVoice = (mode: false, input: false)

    init(settings: PrompterSettings, now: @escaping () -> TimeInterval = { CACurrentMediaTime() }) {
        currentSettings = settings.clamped()
        self.now = now
        reportedVoice = (currentSettings.scrollMode == .voice, false)
        refreshLabel()
        refreshDerived()
    }

    // MARK: Derived values

    /// The end: all text has passed the reading line.
    var maxPosition: Double { max(layout.contentHeight, 0) }

    /// True while counting down or playing; the view pauses its display link otherwise.
    var needsFrames: Bool {
        switch state {
        case .countdown, .playing: true
        case .idle, .paused, .finished: false
        }
    }

    /// Current scrolling speed in points per second, per the active mode (also during a hold, when the text stands still).
    /// Voice mode: the WPM-equivalent pace its time estimate uses (the text itself follows the reader).
    var pointsPerSecond: Double {
        ScrollTiming.pointsPerSecond(
            settings: timingSettings, layout: layout, remainingDistance: remainingDistance, budget: effectiveBudget,
            holdSeconds: pendingHoldSeconds
        )
    }

    /// Exact seconds left at the current speed, holds included (≥ 0). `remainingSeconds` is this rounded up. Voice mode:
    /// the rest of the text at the WPM setting, no holds.
    var preciseRemainingSeconds: Double {
        ScrollTiming.remainingSeconds(
            settings: timingSettings, layout: layout, remainingDistance: remainingDistance, budget: effectiveBudget,
            holdSeconds: pendingHoldSeconds
        )
    }

    /// The scroll mode is voice (whether or not it can listen).
    var isVoiceMode: Bool { settings.scrollMode == .voice }

    /// Voice mode and voice can listen: the text follows the reader instead of scrolling by itself.
    var isFollowingVoice: Bool { isVoiceMode && voiceProblem == nil }

    /// Voice mode and playing: the microphone should be on. Also true while voice has a problem, so the voice controller
    /// can try again (a permission granted in the Settings app meanwhile).
    var wantsVoiceInput: Bool { isVoiceMode && state == .playing }

    /// The first character of the line at the reading line (where voice-follow picks up after a move by hand).
    var readingCharacterIndex: Int { layout.characterIndex(at: position) }

    /// The settings the timing follows: voice mode that can't listen scrolls and times like WPM.
    private var timingSettings: PrompterSettings {
        guard isVoiceMode, voiceProblem != nil else { return settings }
        var fallback = settings
        fallback.scrollMode = .wpm
        return fallback
    }

    /// A `[pause N]` cue is holding the text at the reading line (the state is `.playing`).
    var isHolding: Bool { activeHold != nil }

    /// The hold time still to come: what is left of the current hold, plus every cue ahead of the position, plus a cue
    /// right at the position that hasn't held there yet (playing on from it will hold first).
    var pendingHoldSeconds: Double {
        var total = activeHold.map { max($0.remaining, 0) } ?? 0
        for hold in layout.holds where hold.characterIndex != activeHold?.characterIndex {
            if hold.y > position + ScrollTiming.holdTolerance {
                total += max(hold.seconds, 0)
            } else if hold.y >= position - ScrollTiming.holdTolerance, hold.characterIndex != spentHold {
                total += max(hold.seconds, 0)
            }
        }
        return total
    }

    private var remainingDistance: Double { max(maxPosition - position, 0) }

    /// The finish-in budget the speed and the time remaining follow. Idle: the one `start()` would set (so the HUD shows
    /// it before starting). Counting down or paused: the one playing will start (again) with, see `readableBudget`.
    /// Playing or finished: the running budget.
    private var effectiveBudget: Double {
        switch state {
        case .idle: shareBudget
        case .countdown, .paused: readableBudget
        case .playing, .finished: budget
        }
    }

    /// The rest's share of the finish-in time (see `ScrollTiming.shareBudget`).
    private var shareBudget: Double {
        ScrollTiming.shareBudget(
            settings: settings, layout: layout, remainingDistance: remainingDistance, holdSeconds: pendingHoldSeconds
        )
    }

    /// `budget`, or a readable one if it can't be met at a readable pace (see `ScrollTiming.readableBudget`).
    private var readableBudget: Double {
        ScrollTiming.readableBudget(
            budget, settings: settings, layout: layout, remainingDistance: remainingDistance,
            holdSeconds: pendingHoldSeconds
        )
    }

    // MARK: Layout

    /// How `updateLayout` keeps the place when the text is laid out again.
    enum RelayoutAnchor: Sendable {
        /// The first character of the line at the reading line, plus how far through that line's span the position is
        /// (`PrompterLayout.anchor`). What the iPhone, the iPad and the Mac have always used.
        case lineStart
        /// The exact character at the reading line (`PrompterLayout.readingPoint`), which does not drift when a fold
        /// sends the canvas through several widths in a row. Falls back to `lineStart` where a layout can't give one.
        case readingPoint
    }

    /// New text layout (first layout, pinch, rotation, a fold, settings change). Keeps the text at the reading line on the
    /// same place in the script (see `RelayoutAnchor`); the state doesn't change, so a take that is playing plays on at the
    /// same pace (WPM and finish-in recompute their speed from the new layout). Starts a waiting `start()`.
    func updateLayout(_ newLayout: PrompterLayout, anchoring: RelayoutAnchor = .lineStart) {
        guard newLayout != layout else { return }
        let anchor = layout.lines.isEmpty ? heldAnchor : layout.anchor(at: position)
        let readingPoint = anchoring == .readingPoint && !layout.lines.isEmpty ? layout.readingPoint(at: position) : nil
        layout = newLayout
        if newLayout.lines.isEmpty {
            heldAnchor = anchor
            position = 0
        } else {
            heldAnchor = nil
            if let readingPoint, let mapped = newLayout.position(ofReadingPoint: readingPoint) {
                position = mapped
            } else if let anchor {
                position = newLayout.position(of: anchor)
            }
            position = clampedPosition(position)
            if state == .finished { position = maxPosition }
            // A hold in progress stays on its cue (the anchor already put the position on the cue's line).
            if let hold = activeHold {
                if let cue = newLayout.holds.first(where: { $0.characterIndex == hold.characterIndex }) {
                    position = clampedPosition(cue.y)
                } else {
                    activeHold = nil
                }
            }
        }
        refreshDerived()
        if isWaitingForLayout, maxPosition > 0 { start() }
    }

    // MARK: Play / pause

    /// idle: countdown (or play at once if the countdown is off); paused: resume; finished: back to top, then as idle.
    /// Waits for a layout if there is no text yet. Starting idle at the very end starts from the top.
    func start() {
        switch state {
        case .countdown, .playing:
            return
        case .paused:
            resume()
            return
        case .finished:
            position = 0
            heldAnchor = nil
            clearHolds()
            noteManualMove()
            setState(.idle)
        case .idle:
            break
        }
        guard maxPosition > 0 else {
            isWaitingForLayout = true
            refreshDerived()
            return
        }
        isWaitingForLayout = false
        if position >= maxPosition {
            position = 0
            clearHolds()
            noteManualMove()
        }
        budget = shareBudget
        let seconds = settings.countdownSeconds
        if seconds > 0 {
            let started = now()
            countdownEnd = started + Double(seconds)
            countdownAwaitingFirstFrame = started
            setState(.countdown(seconds))
            refreshDerived()
            emit(.countdownTick(seconds))
        } else {
            beginPlaying(at: now())
            refreshDerived()
            emit(.go)
        }
    }

    /// playing → paused; countdown → cancelled (idle); otherwise nothing (also cancels a start waiting for layout).
    /// Pausing during a hold ends the hold: the presenter has taken over the timing, so resuming scrolls straight on.
    func pause() {
        switch state {
        case .countdown:
            setState(.idle)
            refreshDerived()
        case .playing:
            interruptHold()
            setState(.paused)
            refreshDerived()
            emit(.paused)
        case .idle:
            isWaitingForLayout = false
        case .paused, .finished:
            break
        }
    }

    /// paused → playing; idle or finished → `start()`; otherwise nothing.
    func resume() {
        switch state {
        case .idle, .finished:
            start()
        case .paused:
            beginPlaying(at: now())
            refreshDerived()
            emit(.resumed)
        case .countdown, .playing:
            break
        }
    }

    func togglePlay() {
        switch state {
        case .idle, .finished: start()
        case .countdown, .playing: pause()
        case .paused: resume()
        }
    }

    /// Any state → idle at the top, with a fresh finish-in budget.
    func backToTop() {
        let moved = position != 0
        isWaitingForLayout = false
        heldAnchor = nil
        position = 0
        clearHolds()
        noteManualMove()
        budget = settings.finishInSeconds
        setState(.idle)
        refreshDerived()
        if moved { emit(.jumped) }
    }

    // MARK: Steps

    /// +1: to the first line starting more than half a point below the position (or the end); -1: to the last line
    /// starting more than half a point above it (or the top). Larger counts repeat. Keeps playing; from finished → paused.
    func stepLine(_ direction: Int) {
        step(direction, paragraphsOnly: false)
    }

    /// Like `stepLine`, but only lines that start a paragraph count.
    func stepParagraph(_ direction: Int) {
        step(direction, paragraphsOnly: true)
    }

    /// To the last paragraph start at least half a line above the position (so pressing it just after a paragraph
    /// began goes to the previous one), or the top.
    func jumpBack() {
        let limit = position - ScrollTiming.jumpBackGraceLines * layout.averageLinePitch
        let target = layout.lines.last { $0.startsParagraph && $0.y <= limit }?.y ?? 0
        move(to: target)
    }

    // MARK: Speed

    /// The Crown sends ±1 per detent, buttons and keys ±5. Speed: level ± 0.1·n; WPM: ± 2·n; finish in: ∓ 5·n seconds
    /// (plus = faster = shorter, and the remaining budget scales with it). Clamped to the settings ranges. Voice mode:
    /// nothing (the reader sets the pace), unless voice can't listen, when it steps the WPM pace it falls back to.
    func speedStep(_ n: Int) {
        guard n != 0, !isFollowingVoice else { return }
        var stepped = ScrollTiming.settings(timingSettings, steppedBy: n)
        stepped.scrollMode = settings.scrollMode
        settings = stepped
    }

    /// Sets the active mode's value (level, WPM or seconds), clamped. Non-finite values are ignored. Voice mode: like
    /// `speedStep(_:)`.
    func setSpeed(_ value: Double) {
        guard !isFollowingVoice else { return }
        var updated = ScrollTiming.settings(timingSettings, withSpeed: value)
        updated.scrollMode = settings.scrollMode
        settings = updated
    }

    // MARK: Voice

    /// Voice mode, playing: speech says the reader has reached `target`. The text eases there (see the type's notes) and
    /// the "Listening…" wait ends. Ignored in any other mode or state, and while voice can't listen.
    func followVoice(_ target: VoiceTarget) {
        guard isFollowingVoice, state == .playing else { return }
        voiceTarget = target
        lastVoiceMatch = max(now(), lastTick)
        if isAwaitingVoice { isAwaitingVoice = false }
    }

    /// Voice can't listen (`problem`), or can again (nil). While there is a problem, voice mode scrolls and times like
    /// WPM from wherever the text is; when it clears, the text stops and waits for the reader again.
    func setVoiceProblem(_ problem: VoiceProblem?) {
        guard problem != voiceProblem else { return }
        let wasFollowing = isFollowingVoice
        voiceProblem = problem
        voiceModeChanged(wasFollowing: wasFollowing)
        refreshLabel()
        refreshDerived()
        reportVoiceChange()
    }

    // MARK: Scrubbing

    /// A drag began: countdown → cancelled (idle); playing → paused (ending a hold, like `pause()`); finished → paused.
    func scrubBegan() {
        switch state {
        case .countdown:
            setState(.idle)
            refreshDerived()
        case .playing:
            interruptHold()
            setState(.paused)
            refreshDerived()
            emit(.paused)
        case .finished:
            setState(.paused)
            refreshDerived()
        case .idle, .paused:
            break
        }
    }

    /// Moves by `delta` points (positive = further into the script), clamped; same state changes as `scrubBegan()`.
    func scrub(by delta: Double) {
        scrubBegan()
        guard delta.isFinite else { return }
        let target = clampedPosition(position + delta)
        guard target != position else { return }
        position = target
        heldAnchor = nil
        clearHolds()
        noteManualMove()
        refreshDerived()
    }

    // MARK: Ticks

    /// Advances the countdown or the scroll to `time`. Gaps longer than 0.1 s count as 0.1 s.
    ///
    /// A countdown whose first frame comes more than `ScrollTiming.lateCountdownFrame` after `start()` was never on
    /// screen (started while the app was in the background, say, where the display link doesn't run): it starts again
    /// from this frame, so "go" never fires the moment the prompter is seen again.
    func tick(now time: TimeInterval) {
        guard time.isFinite else { return }
        switch state {
        case .countdown(let shown):
            if let started = countdownAwaitingFirstFrame {
                countdownAwaitingFirstFrame = nil
                if time - started > ScrollTiming.lateCountdownFrame {
                    // No frame yet, so the first digit still shows: count all of it down again, from now.
                    countdownEnd = time + Double(shown)
                    emit(.countdownTick(shown))
                    return
                }
            }
            if time >= countdownEnd {
                beginPlaying(at: countdownEnd)
                refreshDerived()
                emit(.go)
                if state == .playing { advance(to: time) }
            } else {
                let digit = min(ScrollTiming.countdownDigit(secondsLeft: countdownEnd - time), shown)
                if digit != shown {
                    setState(.countdown(digit))
                    emit(.countdownTick(digit))
                }
            }
        case .playing:
            advance(to: time)
        case .idle, .paused, .finished:
            break
        }
    }

    // MARK: Private

    /// Starting or resuming: a finish-in budget the rest can't be read in (the deadline passed, or a scrub went back late)
    /// is replaced by a readable one first, so the text never sets off at an unreadable speed. Voice mode: the text
    /// stands still and waits for the reader.
    private func beginPlaying(at time: TimeInterval) {
        budget = readableBudget
        lastTick = time
        if isFollowingVoice { waitForVoice(at: time) }
        setState(.playing)
        holdIfAtCue()
    }

    /// Voice mode, (re)starting to play: stay put, moving nowhere until speech matches, and say "Listening…" at once.
    private func waitForVoice(at time: TimeInterval) {
        voiceTarget = nil
        voiceVelocity = 0
        lastVoiceMatch = time - ScrollTiming.voiceListeningDelay
        if !isAwaitingVoice { isAwaitingVoice = true }
    }

    /// The mode changed between following voice and scrolling by itself (a settings change, or voice gaining or losing
    /// its problem). While playing: a hold in progress ends when voice takes over; voice letting go hands the text to the
    /// new mode right where it is.
    private func voiceModeChanged(wasFollowing: Bool) {
        let isFollowing = isFollowingVoice
        guard isFollowing != wasFollowing else { return }
        voiceTarget = nil
        voiceVelocity = 0
        if isFollowing {
            activeHold = nil
            if state == .playing { waitForVoice(at: max(lastTick, now())) }
        } else {
            if isAwaitingVoice { isAwaitingVoice = false }
            if state == .playing { holdIfAtCue() }
        }
    }

    /// Plays `dt` seconds: holds at a cue it is sitting on or reaches (the rest of the tick goes into the hold, and a hold
    /// that ends mid-tick scrolls on for what is left), otherwise scrolls. Time passes during a hold, so a finish-in budget
    /// keeps running down; the hold time is part of it (see `ScrollTiming.pointsPerSecond`). Voice mode follows the reader
    /// instead (`advanceFollowingVoice(to:)`).
    private func advance(to time: TimeInterval) {
        if isFollowingVoice {
            advanceFollowingVoice(to: time)
            return
        }
        let dt = ScrollTiming.tickInterval(from: lastTick, to: time)
        lastTick = max(lastTick, time)
        guard dt > 0, maxPosition > 0 else { return }
        var timeLeft = dt
        // Each round either spends time holding, starts a hold, or scrolls; a tick crosses at most a few cues.
        for _ in 0...(2 * layout.holds.count + 1) {
            guard timeLeft > 0 else { break }
            if let hold = activeHold {
                let held = min(hold.remaining, timeLeft)
                timeLeft -= held
                spendBudget(held)
                if hold.remaining - held > ScrollTiming.holdTolerance {
                    activeHold = (hold.characterIndex, hold.remaining - held)
                    break
                }
                activeHold = nil
                spentHold = hold.characterIndex
                continue
            }
            let cue = nextHold()
            if let cue, cue.y <= position + ScrollTiming.holdTolerance {
                beginHold(cue)
                continue
            }
            let speed = pointsPerSecond
            guard speed > 0, speed.isFinite else { break }
            let target = min(position + speed * timeLeft, maxPosition)
            if let cue, cue.y <= target {
                // Reaches the cue during this tick: scroll exactly to it, then hold for the rest of the tick.
                let needed = min(max((cue.y - position) / speed, 0), timeLeft)
                position = cue.y
                timeLeft -= needed
                spendBudget(needed)
                beginHold(cue)
                continue
            }
            position = target
            spendBudget(timeLeft)
            timeLeft = 0
        }
        if position >= maxPosition {
            finish()
        } else {
            refreshDerived()
        }
    }

    /// Voice mode: eases toward the voice target (`ScrollTiming.voiceStep`) and notes when nothing new has been heard for
    /// a while. Reaching the end (the last word heard) finishes, as in the other modes.
    private func advanceFollowingVoice(to time: TimeInterval) {
        let dt = ScrollTiming.tickInterval(from: lastTick, to: time)
        lastTick = max(lastTick, time)
        let awaiting = lastTick - lastVoiceMatch >= ScrollTiming.voiceListeningDelay
        if awaiting != isAwaitingVoice { isAwaitingVoice = awaiting }
        guard dt > 0, maxPosition > 0 else { return }
        let target = voiceTargetPosition ?? position
        let step = ScrollTiming.voiceStep(
            position: position, velocity: voiceVelocity, target: target, dt: dt, linePitch: layout.averageLinePitch
        )
        position = clampedPosition(step.position)
        voiceVelocity = step.velocity
        if position >= maxPosition {
            finish()
        } else {
            refreshDerived()
        }
    }

    /// Where the voice target is in the current layout (it is kept as a character, so it survives a relayout).
    private var voiceTargetPosition: Double? {
        switch voiceTarget {
        case .character(let index)?: clampedPosition(layout.position(ofCharacterIndex: index))
        case .end?: maxPosition
        case nil: nil
        }
    }

    /// The text was moved by hand: voice-follow picks up from here, and the text stays here until speech says otherwise.
    private func noteManualMove() {
        manualMoveCount &+= 1
        voiceTarget = nil
        voiceVelocity = 0
    }

    private func reportVoiceChange() {
        let current = (mode: isVoiceMode, input: wantsVoiceInput)
        guard current != reportedVoice else { return }
        reportedVoice = current
        onVoiceChange?()
    }

    private func spendBudget(_ seconds: Double) {
        if settings.scrollMode == .finishIn { budget = max(budget - seconds, 0) }
    }

    /// The next cue that will hold: at the position if it hasn't held there yet, otherwise the first one ahead.
    private func nextHold() -> PrompterLayout.Hold? {
        layout.holds.first { hold in
            guard hold.seconds > 0 else { return false }
            if hold.y > position + ScrollTiming.holdTolerance { return true }
            return hold.y >= position - ScrollTiming.holdTolerance && hold.characterIndex != spentHold
        }
    }

    /// Playing (re)starts or lands on a cue that hasn't held there yet: hold now, so the HUD says so from the first frame.
    /// Never while following voice (the speaker sets the pace).
    private func holdIfAtCue() {
        guard !isFollowingVoice, activeHold == nil, let cue = nextHold(), cue.y <= position + ScrollTiming.holdTolerance
        else { return }
        beginHold(cue)
    }

    private func beginHold(_ cue: PrompterLayout.Hold) {
        position = clampedPosition(cue.y)
        spentHold = nil
        activeHold = (cue.characterIndex, cue.seconds)
    }

    /// A pause or a drag during a hold ends it, and the cue counts as done (resuming doesn't hold there again).
    private func interruptHold() {
        guard let hold = activeHold else { return }
        activeHold = nil
        spentHold = hold.characterIndex
    }

    /// The text moved by other means than playing: any cue may hold again when playing reaches it.
    private func clearHolds() {
        activeHold = nil
        spentHold = nil
    }

    private func finish() {
        position = maxPosition
        activeHold = nil
        setState(.finished)
        refreshDerived()
        emit(.finished)
    }

    private func step(_ count: Int, paragraphsOnly: Bool) {
        guard count != 0 else { return }
        // More repeats than lines can't move further; also keeps Int.min/Int.max cheap.
        let repeats = min(Int(clamping: count.magnitude), layout.lines.count + 1)
        var target = position
        for _ in 0..<repeats {
            target = count > 0
                ? nextLineStart(after: target, paragraphsOnly: paragraphsOnly)
                : previousLineStart(before: target, paragraphsOnly: paragraphsOnly)
        }
        move(to: target)
    }

    private func nextLineStart(after position: Double, paragraphsOnly: Bool) -> Double {
        let limit = position + ScrollTiming.stepTolerance
        return layout.lines.first { (!paragraphsOnly || $0.startsParagraph) && $0.y > limit }?.y ?? maxPosition
    }

    private func previousLineStart(before position: Double, paragraphsOnly: Bool) -> Double {
        let limit = position - ScrollTiming.stepTolerance
        return layout.lines.last { (!paragraphsOnly || $0.startsParagraph) && $0.y < limit }?.y ?? 0
    }

    /// A discrete move (step, jump back). Finished → paused if it moved back; playing at the end → finished.
    private func move(to target: Double) {
        let target = clampedPosition(target)
        guard target != position else { return }
        position = target
        heldAnchor = nil
        noteManualMove()
        // Landing right on a cue while playing holds there, like playing into it.
        clearHolds()
        if state == .playing { holdIfAtCue() }
        if state == .finished, position < maxPosition { setState(.paused) }
        refreshDerived()
        emit(.jumped)
        if state == .playing, position >= maxPosition { finish() }
    }

    private func clampedPosition(_ value: Double) -> Double {
        guard !value.isNaN else { return min(max(position, 0), maxPosition) }
        return min(max(value, 0), maxPosition)
    }

    private func apply(_ newValue: PrompterSettings) {
        let new = newValue.clamped()
        let old = currentSettings
        guard new != old else { return }
        let wasFollowing = isFollowingVoice
        if state != .idle, new.scrollMode == .finishIn {
            let holds = pendingHoldSeconds
            if old.scrollMode != .finishIn {
                // Switched to finish-in mid-take: the rest of the script gets its share of the new duration.
                budget = ScrollTiming.shareBudget(
                    settings: new, layout: layout, remainingDistance: remainingDistance, holdSeconds: holds
                )
            } else if new.finishInSeconds != old.finishInSeconds, old.finishInSeconds > 0 {
                // The scrolling part scales with the scrolling part of the duration; the holds keep their length. So at
                // the top of the script the time remaining is exactly the new finish-in time.
                let total = layout.totalHoldSeconds
                let oldScrolling = old.finishInSeconds - total
                let newScrolling = max(new.finishInSeconds - total, 0)
                if oldScrolling > 0 {
                    budget = holds + max(budget - holds, 0) * newScrolling / oldScrolling
                } else {
                    budget = ScrollTiming.shareBudget(
                        settings: new, layout: layout, remainingDistance: remainingDistance, holdSeconds: holds
                    )
                }
            }
        }
        currentSettings = new
        voiceModeChanged(wasFollowing: wasFollowing)
        refreshLabel()
        refreshDerived()
        reportVoiceChange()
    }

    private func setState(_ newState: PlaybackState) {
        if newState != state { state = newState }
        if newState != .playing, isAwaitingVoice { isAwaitingVoice = false }
        reportVoiceChange()
    }

    /// Assigns the observed HUD values only when they change, so a frame that moves the text a fraction of a point
    /// doesn't re-render SwiftUI.
    private func refreshDerived() {
        let newProgress = ScrollTiming.progress(position: position, maxPosition: maxPosition)
        if newProgress != progress { progress = newProgress }
        let newRemaining = ScrollTiming.wholeSeconds(preciseRemainingSeconds)
        if newRemaining != remainingSeconds { remainingSeconds = newRemaining }
        let newHold = activeHold.map { max(Int(ScrollTiming.wholeSeconds($0.remaining)), 1) }
        if newHold != holdSecondsLeft { holdSecondsLeft = newHold }
    }

    private func refreshLabel() {
        let label = ScrollTiming.speedLabel(for: timingSettings)
        if label != speedLabel { speedLabel = label }
    }

    private func emit(_ event: Event) {
        onEvent?(event)
    }
}

/// The scroll engine's timing math as pure functions.
enum ScrollTiming {
    /// The longest step one tick may take (display-link hitches, coming back from the background).
    static let maxTickInterval: TimeInterval = 0.1
    /// A countdown whose first frame comes later than this after `start()` was never on screen, and starts again.
    /// The display link's first frame normally follows within a frame or two.
    static let lateCountdownFrame: TimeInterval = 1
    /// WPM and voice mode on a script with no words to read (only notes and cues): this many lines per second, speed
    /// level 3's pace (the default), instead of a pace worked out from no words at all.
    static let untimedLinesPerSecond = 0.75
    /// Speed mode: lines per second per level, so levels 1…10 are 0.25…2.5 lines per second at any font size.
    static let linesPerSecondPerLevel = 0.25
    /// Finish-in mode never scrolls faster than this, however little time is left: the fastest speed-mode level
    /// (10 × 0.25), about as fast as anyone reads aloud.
    static let maxFinishInLinesPerSecond = 2.5
    static let minimumBudget = 0.001
    /// A line or paragraph start this close to the position counts as "here" for steps.
    static let stepTolerance = 0.5
    /// `jumpBack()` skips a paragraph that began less than this many lines ago.
    static let jumpBackGraceLines = 0.5
    /// Per speed-step unit (the Crown sends ±1, buttons and keys ±5).
    static let levelStep = 0.1
    static let wpmStep = 2.0
    static let finishInStep = 5.0

    // Voice mode
    /// The text never follows the voice faster than this.
    static let voiceMaxLinesPerSecond = 4.0
    /// How quickly it gets up to speed and slows down again, in lines per second per second: a one-line move glides in
    /// about half a second, accelerating then braking, never at full speed from a standstill.
    static let voiceAccelerationLinesPerSecondSquared = 16.0
    /// Closer than this (points) counts as there.
    static let voiceArrivalDistance = 0.5
    /// No new match for this long: the HUD says "Listening…".
    static let voiceListeningDelay = 2.0

    /// Seconds between two ticks, 0…0.1 (0 if time went backwards or isn't finite).
    static func tickInterval(from last: TimeInterval, to now: TimeInterval) -> TimeInterval {
        let dt = now - last
        guard dt.isFinite, dt > 0 else { return 0 }
        return min(dt, maxTickInterval)
    }

    static func maxFinishInSpeed(for layout: PrompterLayout) -> Double {
        maxFinishInLinesPerSecond * layout.averageLinePitch
    }

    /// Points per second. Speed: level × 0.25 × pitch. WPM: wpm / 60 × timedHeight / words (`wpmPointsPerSecond`).
    /// Finish in: remaining distance / (budget − the `holdSeconds` still to come), capped at 2.5 lines per second; the
    /// finish-in time includes the `[pause N]` holds, so the scrolling gets what is left of it after them. Voice: the WPM
    /// pace (only for estimates; the text follows the reader).
    static func pointsPerSecond(
        settings: PrompterSettings,
        layout: PrompterLayout,
        remainingDistance: Double,
        budget: Double,
        holdSeconds: Double = 0
    ) -> Double {
        switch settings.scrollMode {
        case .speed:
            return settings.speedLevel * linesPerSecondPerLevel * layout.averageLinePitch
        case .wpm, .voice:
            return wpmPointsPerSecond(wordsPerMinute: settings.wordsPerMinute, layout: layout)
        case .finishIn:
            let distance = max(remainingDistance, 0)
            let scrolling = budget - max(holdSeconds, 0)
            return min(distance / max(scrolling, minimumBudget), maxFinishInSpeed(for: layout))
        }
    }

    /// The WPM pace in points per second: the words are spread over the text lines only (`layout.timedHeight`), so a
    /// spoken line takes the same time whether or not notes and cues sit between the lines; those scroll past at the same
    /// speed, and the time remaining (distance / speed) counts them too. A script with no words to read (only notes and
    /// cues) scrolls at `untimedLinesPerSecond` instead of racing through in a moment.
    static func wpmPointsPerSecond(wordsPerMinute: Double, layout: PrompterLayout) -> Double {
        let timedHeight = layout.timedHeight
        guard layout.wordCount > 0, timedHeight.isFinite, timedHeight > 0 else {
            return untimedLinesPerSecond * layout.averageLinePitch
        }
        return wordsPerMinute / 60 * timedHeight / Double(layout.wordCount)
    }

    /// The rest's share of the finish-in time, `remainingDistance` from the end with `holdSeconds` of holds still to
    /// come: the scrolling part of the chosen duration (`finishInSeconds` minus every hold in the script) in proportion
    /// to the distance, plus those holds. At the top that is exactly `finishInSeconds`.
    static func shareBudget(
        settings: PrompterSettings,
        layout: PrompterLayout,
        remainingDistance: Double,
        holdSeconds: Double = 0
    ) -> Double {
        guard layout.contentHeight > 0 else { return 0 }
        let scrolling = max(settings.finishInSeconds - layout.totalHoldSeconds, 0)
        return scrolling * max(remainingDistance, 0) / layout.contentHeight + max(holdSeconds, 0)
    }

    /// The finish-in budget to play on with, given `remainingDistance` still to go and `holdSeconds` of holds. `budget`
    /// itself if the rest can be scrolled in what it leaves after the holds at the capped speed or slower. If it can't
    /// (the deadline already passed, or a scrub back left too little time), the rest's share of the chosen duration
    /// (`shareBudget`), which is the pace the take was set up for; but never less than the rest takes at the cap. So
    /// finish in never resumes at an unreadable speed, and the time remaining stays the time it will really take.
    static func readableBudget(
        _ budget: Double,
        settings: PrompterSettings,
        layout: PrompterLayout,
        remainingDistance: Double,
        holdSeconds: Double = 0
    ) -> Double {
        let distance = max(remainingDistance, 0)
        let holds = max(holdSeconds, 0)
        let atCap = distance / maxFinishInSpeed(for: layout)
        if budget - holds >= atCap - budgetTolerance { return budget }
        let share = shareBudget(settings: settings, layout: layout, remainingDistance: distance)
        return max(share, atCap) + holds
    }

    /// A budget this close to what the rest takes at the cap still counts as readable (floating-point slack).
    static let budgetTolerance = 1e-6

    /// A cue this close to the position counts as at the reading line (floating-point slack after a relayout).
    static let holdTolerance = 1e-6

    /// Seconds left (≥ 0), `holdSeconds` of holds included. Speed/WPM: distance / speed + holds. Finish in: the budget
    /// (holds are part of it), or longer if the speed cap can't make it. Voice: the rest of the text at the WPM pace
    /// (holds don't apply; the speaker sets the pace).
    static func remainingSeconds(
        settings: PrompterSettings,
        layout: PrompterLayout,
        remainingDistance: Double,
        budget: Double,
        holdSeconds: Double = 0
    ) -> Double {
        guard remainingDistance > 0 else { return 0 }
        let holds = max(holdSeconds, 0)
        switch settings.scrollMode {
        case .speed, .wpm:
            let speed = pointsPerSecond(settings: settings, layout: layout, remainingDistance: remainingDistance, budget: budget)
            return speed > 0 ? remainingDistance / speed + holds : 0
        case .finishIn:
            return max(budget, remainingDistance / maxFinishInSpeed(for: layout) + holds)
        case .voice:
            let speed = pointsPerSecond(settings: settings, layout: layout, remainingDistance: remainingDistance, budget: budget)
            return speed > 0 ? remainingDistance / speed : 0
        }
    }

    /// Voice mode, one tick of `dt` seconds: the next position and velocity (points, points per second) of text easing from
    /// `position` toward `target`. It speeds up by at most `voiceAccelerationLinesPerSecondSquared`, never goes faster than
    /// `voiceMaxLinesPerSecond`, brakes in time to stop on the target (never past it), and turns round smoothly if the
    /// target moves behind it. Within `voiceArrivalDistance` it is there, at rest.
    static func voiceStep(
        position: Double,
        velocity: Double,
        target: Double,
        dt: Double,
        linePitch: Double
    ) -> (position: Double, velocity: Double) {
        guard position.isFinite, target.isFinite else { return (position, 0) }
        let gap = target - position
        if abs(gap) <= voiceArrivalDistance { return (target, 0) }
        guard dt.isFinite, dt > 0 else { return (position, velocity.isFinite ? velocity : 0) }
        let pitch = linePitch.isFinite && linePitch > 0 ? linePitch : 1
        let cap = voiceMaxLinesPerSecond * pitch
        let acceleration = voiceAccelerationLinesPerSecondSquared * pitch
        let direction: Double = gap > 0 ? 1 : -1
        // The fastest it may go and still brake to a stop on the target: v² = 2·a·d.
        let desired = direction * min(cap, (2 * acceleration * abs(gap)).squareRoot())
        let current = velocity.isFinite ? min(max(velocity, -cap), cap) : 0
        let change = min(max(desired - current, -acceleration * dt), acceleration * dt)
        let newVelocity = current + change
        let next = position + newVelocity * dt
        if (gap > 0 && next >= target) || (gap < 0 && next <= target) { return (target, 0) }
        return (next, newVelocity)
    }

    /// The digit to show with `secondsLeft` to go: rounded up, at least 1.
    static func countdownDigit(secondsLeft: Double) -> Int {
        guard secondsLeft.isFinite else { return 1 }
        return max(Int(min(secondsLeft, 1_000_000).rounded(.up)), 1)
    }

    /// position / maxPosition, clamped to 0…1 and rounded to 0.001; 0 when there is no text.
    static func progress(position: Double, maxPosition: Double) -> Double {
        guard maxPosition > 0, position.isFinite else { return 0 }
        let fraction = min(max(position / maxPosition, 0), 1)
        return (fraction * 1_000).rounded() / 1_000
    }

    /// Rounded up to whole seconds, ignoring the last millisecond (so 60.000000001 shows as 1:00, not 1:01).
    static func wholeSeconds(_ seconds: Double) -> Double {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let whole = (seconds - 0.001).rounded(.up)
        return whole > 0 ? whole : 0
    }

    /// "Speed 3.0", "140 wpm", "Finish in 5:00" or "Voice".
    static func speedLabel(for settings: PrompterSettings) -> String {
        let settings = settings.clamped()
        switch settings.scrollMode {
        case .speed:
            let tenths = Int((settings.speedLevel * 10).rounded())
            return "Speed \(tenths / 10).\(tenths % 10)"
        case .wpm:
            return "\(Int(settings.wordsPerMinute.rounded())) wpm"
        case .finishIn:
            return "Finish in \(TimeFormatting.clock(settings.finishInSeconds))"
        case .voice:
            return "Voice"
        }
    }

    /// `settings` after `n` speed steps in its active mode, clamped.
    static func settings(_ settings: PrompterSettings, steppedBy n: Int) -> PrompterSettings {
        var stepped = settings
        let steps = Double(n)
        switch settings.scrollMode {
        case .speed:
            // Work in whole tenths (divide, don't multiply by 0.1) so repeated steps land exactly on 3.1, 3.2, …
            let tenthsPerLevel = (1 / levelStep).rounded()
            stepped.speedLevel = ((settings.speedLevel * tenthsPerLevel).rounded() + steps) / tenthsPerLevel
        case .wpm:
            stepped.wordsPerMinute = settings.wordsPerMinute.rounded() + wpmStep * steps
        case .finishIn:
            stepped.finishInSeconds = settings.finishInSeconds - finishInStep * steps
        case .voice:
            break
        }
        return stepped.clamped()
    }

    /// `settings` with the active mode's value set to `value`, clamped. Non-finite values change nothing.
    static func settings(_ settings: PrompterSettings, withSpeed value: Double) -> PrompterSettings {
        guard value.isFinite else { return settings }
        var updated = settings
        switch settings.scrollMode {
        case .speed: updated.speedLevel = value
        case .wpm: updated.wordsPerMinute = value
        case .finishIn: updated.finishInSeconds = value
        case .voice: break
        }
        return updated.clamped()
    }
}
