# M3: Apple Watch Remote + Link Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** From the Apple Watch, the owner can Start (with countdown), Pause/Resume, change speed (buttons + Digital Crown), go Back to top
and Jump back a paragraph, and sees the script title, state, progress ring and time remaining, with haptics on the countdown and at the end.

**Architecture:** A Codable protocol in `Shared/` (`RemoteCommand`, `PrompterStatus`, `RemoteMessageCoder`, `StatusGate`,
`RemoteDisplayModel`, `RemoteScript` debug-sequence parser) is unit tested on iOS. On the phone a `PrompterRemoteHub`
(`@MainActor @Observable`) owns `WCSession` through a `nonisolated` delegate object, applies incoming commands to the active
`ScrollEngine` (registered by `PrompterScreen`) and publishes status (sendMessage ~4 Hz while reachable and prompting, plus
`updateApplicationContext` on every state change). On the watch a `WatchRemote` (`@MainActor @Observable`) owns its `WCSession`,
sends commands with a reply handler (the reply carries the fresh status) and renders `RemoteView`.

**Tech Stack:** WatchConnectivity, SwiftUI (watchOS 10+: `digitalCrownRotation`, `Gauge`/custom ring), WatchKit haptics
(`WKInterfaceDevice.current().play`), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-06-prompter-design.md` §4, §5, §7-M3. **Builds on** M1/M2 plans in this folder
(`ScrollEngine`, `PlaybackState`, `PrompterScreen`, `TimeFormatting`).

## Global Constraints
- `Shared/` compiles for iOS 26 and watchOS 10: Foundation only (no UIKit, no WatchKit, no WatchConnectivity in protocol files).
- WCSession delegate callbacks are `nonisolated`; decode `[String: Any]` into Sendable values inside the callback, then hop to the
  main actor. Never send `[String: Any]` across actors.
- Swift 6 strict concurrency, Apple frameworks only, no hand edits to the `.xcodeproj` (WatchConnectivity is a system framework and
  links automatically via `import`).
- Watch copy: "Open Prompter on your iPhone", "Ready", "3"/"2"/"1", "Playing", "Paused", "Finished", "Start", "Pause", "Resume",
  "Back to top", "Jump back".

## Implementation notes from M2 (authoritative)
- The active engine lives in `PrompterController` (`Prompter/Features/Prompter/PrompterController.swift`). Attach to the hub in
  `PrompterScreen.open()` right after the controller is created (`controller.engine`, `controller.scriptTitle`); detach in
  `PrompterStage.disappear()`. Keep those edits to a few lines.
- Do NOT set `engine.onEvent`: the screen owns that single closure (sounds + display-link wake-up). Observe the engine through
  Observation (`state`, `progress`, `remainingSeconds`, `speedLabel`) or by sampling it on the hub's 4 Hz timer.
- Just call engine commands from the hub: state changes and `.jumped` already wake the display link and move the text; speed steps
  already persist to `SettingsStore` through the screen.
- `engine.remainingSeconds` is already whole seconds rounded up; `engine.preciseRemainingSeconds` has the exact value.

## Review Focus
1. **Phone app relaunched** (sequence numbers restart) → the watch must still accept new status. Sequence = max(last + 1,
   milliseconds since 2001), so it stays monotonic across launches. *Test:* `StatusGateTests.acceptsAfterPhoneRelaunch`.
2. **Out-of-order delivery** (a reply from an old command arrives after a newer 4 Hz status) → stale status dropped.
   *Test:* `StatusGateTests.dropsOlderSequence`.
3. **Watch opened while the phone is mid-take** → it shows the current state immediately from `receivedApplicationContext`,
   then live updates. *Test:* `RemoteMessageCoderTests.applicationContextRoundTrip`.
4. **No prompter open on the phone** (phone on the library) → commands are ignored safely and status says so (`hasPrompter = false`);
   the watch shows "Open a script on your iPhone" and disables controls. *Test:* `RemoteCommandRouterTests.noEngineReturnsNoPrompterStatus`.
5. **Unknown/garbled message** (older/newer app version) → ignored, never a crash. *Test:* `RemoteMessageCoderTests.garbageDecodesToNil`.

---

### Task 1: Protocol + phone hub (+ tests)  · model: Opus

**Files:**
- Create `Shared/RemoteProtocol.swift` (`RemoteCommand`, `PrompterStatus`), `Shared/RemoteMessageCoder.swift`, `Shared/StatusGate.swift`,
  `Shared/RemoteDisplayModel.swift`, `Shared/RemoteScript.swift`. Remove the placeholder `Shared/PrompterShared.swift` only if
  `SkeletonTests` is updated accordingly.
- Create `Prompter/Services/PrompterRemoteHub.swift` (+ `PhoneSessionDelegate` nonisolated NSObject), `Prompter/Services/RemoteCommandRouter.swift`.
- Modify `Prompter/App/PrompterApp.swift` (create the hub, inject via `.environment`, activate at launch) and
  `Prompter/Features/Prompter/PrompterScreen.swift` (register/unregister the engine + script title with the hub).
- Tests: `PrompterTests/RemoteProtocolTests.swift`, `RemoteMessageCoderTests.swift`, `StatusGateTests.swift`, `RemoteDisplayModelTests.swift`,
  `RemoteScriptTests.swift`, `RemoteCommandRouterTests.swift`.

**Interfaces:**
```swift
// Shared/RemoteProtocol.swift
enum RemoteCommand: Codable, Equatable, Hashable, Sendable {
    case start, pause, resume, togglePlay, speedStep(Int), setSpeed(Double), backToTop, jumpBack, requestStatus
}
struct PrompterStatus: Codable, Equatable, Sendable {
    var hasPrompter: Bool            // false when the phone isn't showing the prompter
    var scriptTitle: String
    var state: PlaybackState
    var progress: Double             // 0…1
    var remainingSeconds: Double
    var speedLabel: String
    var sequence: UInt64             // monotonic across phone launches (see Review Focus 1)
    static let noPrompter: PrompterStatus   // hasPrompter false, idle, zeros, sequence 0
}

// Shared/RemoteMessageCoder.swift  — WCSession dictionaries carry JSON Data under one key
enum RemoteMessageCoder {
    static let commandKey = "cmd", statusKey = "status"
    static func message(for command: RemoteCommand) -> [String: Any]
    static func command(from message: [String: Any]) -> RemoteCommand?
    static func message(for status: PrompterStatus) -> [String: Any]    // also used for application context and replies
    static func status(from message: [String: Any]) -> PrompterStatus?
}

// Shared/StatusGate.swift
struct StatusGate: Sendable {
    private(set) var latest: PrompterStatus?
    /// Accepts and stores the status if its sequence is greater than the latest accepted one. Returns whether it was accepted.
    mutating func accept(_ status: PrompterStatus) -> Bool
}
struct SequenceClock: Sendable {         // phone side
    private(set) var last: UInt64 = 0
    mutating func next(now: Date = Date()) -> UInt64   // max(last + 1, UInt64(now.timeIntervalSinceReferenceDate * 1000))
}

// Shared/RemoteDisplayModel.swift  — everything the watch shows, derived from (status, reachable)
struct RemoteDisplayModel: Equatable, Sendable {
    init(status: PrompterStatus?, isReachable: Bool)
    var title: String                 // script title, or "Prompter"
    var stateText: String             // "Open Prompter on your iPhone" (unreachable) / "Open a script on your iPhone" (no prompter) /
                                      // "Ready" / "3" / "Playing" / "Paused" / "Finished"
    var primaryButtonTitle: String    // "Start" (idle, finished) / "Cancel" (countdown) / "Pause" (playing) / "Resume" (paused)
    var primaryCommand: RemoteCommand // .start / .pause / .pause / .resume / .start
    var primarySymbol: String         // "play.fill" / "xmark" / "pause.fill" / "play.fill"
    var controlsEnabled: Bool         // reachable && hasPrompter
    var progress: Double
    var timeText: String              // TimeFormatting.clock(ceil(remainingSeconds)), "--:--" when no status
    var speedLabel: String
    var countdownDigit: Int?          // non-nil while counting down
}

// Shared/RemoteScript.swift  — debug-only automation for simulator end-to-end checks
struct RemoteScript: Equatable, Sendable {
    struct Step: Equatable, Sendable { var at: Double; var command: RemoteCommand }
    var steps: [Step]
    /// Parses "start@2,pause@12,speedStep:5@14,resume@16,backToTop@30" (seconds after launch). Invalid parts are skipped.
    init(_ text: String)
}

// Prompter/Services/RemoteCommandRouter.swift
@MainActor enum RemoteCommandRouter {
    /// Applies the command to the engine (nil engine → nothing happens). requestStatus does nothing.
    static func apply(_ command: RemoteCommand, to engine: ScrollEngine?)
    static func status(engine: ScrollEngine?, scriptTitle: String, sequence: UInt64) -> PrompterStatus
}

// Prompter/Services/PrompterRemoteHub.swift
@MainActor @Observable
final class PrompterRemoteHub {
    private(set) var isReachable: Bool
    private(set) var isPaired: Bool, isWatchAppInstalled: Bool
    init()                                             // does not activate (tests)
    func activate()                                    // WCSession.default if supported
    func attach(engine: ScrollEngine, scriptTitle: String)   // PrompterScreen on appear
    func detach(engine: ScrollEngine)                  // PrompterScreen on disappear → pushes noPrompter
    func handle(_ command: RemoteCommand) -> PrompterStatus  // apply + fresh status (used by the delegate's reply)
}
```

**Phone behaviour:** on a command message with a reply handler → hop to main, `handle`, reply with the status dictionary. Status push:
a main-actor `Task` loop every 0.25 s while `session.isReachable` and an engine is attached sends `sendMessage(status, replyHandler: nil)`
(errors ignored); `updateApplicationContext` whenever state, scriptTitle, speedLabel or hasPrompter changes (and on attach/detach).
Use `withObservationTracking` or compare-on-tick to detect changes. `sessionDidBecomeInactive`/`sessionDidDeactivate` → re-activate.

**Tests:** round trip every `RemoteCommand` case and a `PrompterStatus` through JSON and through `RemoteMessageCoder`; garbage
dictionaries (wrong key, wrong type, bad JSON) → nil; StatusGate accept/drop/relaunch cases; SequenceClock monotonic even when the clock
goes backwards; RemoteDisplayModel for every state × reachable × hasPrompter; RemoteScript parsing incl. invalid parts;
RemoteCommandRouter: start/pause/resume/speedStep/backToTop/jumpBack reach the engine (use a real `ScrollEngine` with a manual clock and a
hand-built `PrompterLayout`), nil engine → `hasPrompter == false`.

**Steps:** tests → implement → build + test green → commit "M3: remote protocol and phone hub".

---

### Task 2: Watch app UI + session  · model: Opus (WatchConnectivity) with a Sonnet-friendly view split · after Task 1

**Files:** create `PrompterWatch/Features/WatchRemote.swift` (`@MainActor @Observable`, owns WCSession via a nonisolated delegate,
`status` through `StatusGate`, `isReachable`, `send(_:)` with reply handler, `receivedApplicationContext` on activation, `.requestStatus`
when reachability turns on), `PrompterWatch/Features/RemoteView.swift`, `PrompterWatch/Features/Haptics.swift`; modify
`PrompterWatch/App/PrompterWatchApp.swift`. Delete `PrompterWatch/Features/.gitkeep`.

**UI (one screen, readable at a glance):** top: title (1 line, headline) + state text (footnote, accent when counting down).
Centre: a large circular primary button inside a progress ring (ring = `progress`, 6 pt stroke, amber); inside it the time remaining
(large monospaced digits) above the button symbol; during countdown the digit replaces the time. Bottom row: Back to top
(`arrow.up.to.line`), Jump back (`gobackward`), Speed − (`minus`), Speed + (`plus`), with the speed label tiny underneath.
Digital Crown: `.focusable()` + `.digitalCrownRotation(value, from: -1000, through: 1000, by: 1, sensitivity: .low, isContinuous: true,
isHapticFeedbackEnabled: true)`; each whole-step change sends `.speedStep(±1)` (coalesce: at most one message per 0.1 s carrying the summed
steps). Buttons send `.speedStep(±5)`. Controls disabled when `!controlsEnabled`.
**Haptics:** `.click` on each new countdown digit, `.start` when the state becomes playing from countdown, `.success` on finished.
**Debug automation:** if launched with `-remoteScript "<steps>"`, run the `RemoteScript` steps on a timer (used for simulator E2E checks).

**Steps:** implement → `scripts/build.sh` green (it builds the embedded watch app) → also build the watch scheme for a watch simulator →
commit "M3: watch remote".

---

### Task 3: End-to-end on paired simulators (orchestrator + agent)
- [ ] Create/boot a watchOS 27 simulator (e.g. Apple Watch Series 11 46 mm), `xcrun simctl pair <watch> <iPhone 17 Pro iOS 27>`,
      boot both, install `Prompter.app` on the phone and `PrompterWatch.app` on the watch.
- [ ] Launch phone with `-route prompter -demoData`; launch watch with `-remoteScript "start@3,pause@14,speedStep:5@15,resume@17"`.
      Verify with screenshots and `log stream` that the phone counts down, plays, pauses, speeds up, resumes, and that the watch shows
      Ready → 3-2-1 → Playing → Paused with the ring and time.
- [ ] Screenshots: `m3-watch-ready.png`, `m3-watch-countdown.png`, `m3-watch-playing.png`, `m3-watch-paused.png`, `m3-watch-unreachable.png`,
      `m3-phone-from-watch.png`.
- [ ] PROGRESS.md (+ "Needs the owner": on-device pairing, real Crown/haptics feel), shut down simulators, milestone commit.
