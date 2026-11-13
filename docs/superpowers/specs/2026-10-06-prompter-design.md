# Prompter: design spec

Date: 2026-10-06 · Owner: project owner · Status: approved direction (SwiftUI iPhone app + Apple Watch companion), details open to
the build session's judgement where marked.

## 1. Purpose
A free, native teleprompter for the owner's beam-splitter rig: an iPhone 17 Pro lying flat (landscape, screen up) under 45° clear acrylic,
reflected toward the presenter, with a Sony a7C filming through the glass. An Apple Watch is the remote. Success means the owner can:
1. Pick a script on the phone, set it in the cradle, and walk to the camera.
2. Tap **Start** on the watch, see a big mirrored 3-2-1 in the glass, then the script scrolls at a trusted speed.
3. Pause, resume, change speed and jump back from the watch, and see time remaining on the wrist.
4. Read comfortably despite plain-acrylic ghosting (big, heavy, spaced white text on black by default).

## 2. Platforms and project
- iOS 26.0+, iPhone and iPad (universal; iPad is phase 2 but layouts must not break). watchOS companion app (deployment target
  in `project.yml`; aim for the oldest Xcode 27 supports, because the owner's watch is a Series 6–8 or SE).
- Bundle IDs: `<prefix>.prompter`, `<prefix>.prompter.watchkitapp`. Display name "Prompter".
- XcodeGen `project.yml`, Swift 6, Apple frameworks only. See `AGENTS.md` for commands and rules.

## 3. iPhone app

### 3.1 Library (home screen)
- List of scripts: title, first line, word count, estimated read time at the current WPM, last edited. Newest edited on top.
- Actions: **New**, **Paste as new script** (clipboard text, title from the first line), **Import** (`.fileImporter` for
  `.txt`, `.rtf`; `.pdf` in Milestone 4), swipe to **Delete** with undo, context menu **Duplicate** and **Rename**.
- Tap a script to open the editor. A big **Prompt** button opens the prompter directly.
- First launch seeds one sample script that explains the controls, so the app isn't empty.

### 3.2 Editor
- Title field + full-height text editor. Live word count and read time. A **Prompt** button in the toolbar. Autosaves.

### 3.3 Prompter screen (the core)
- Full screen, status bar and home indicator hidden, `isIdleTimerDisabled = true` while open.
- **Text rendering:** a non-editable TextKit view (UIKit `UITextView`/TextKit 2 in a `UIViewRepresentable`) is recommended, so
  scrolling is pixel-smooth at 120 Hz via `CADisplayLink` and line/paragraph rects are available for jumps and voice-follow.
  A pure-SwiftUI approach is acceptable if it is equally smooth.
- **Geometry:** mirror horizontally (default ON), flip vertically (default OFF), rotate 0/90/180/270 so the text runs
  correctly even if iOS reports portrait while the phone lies flat. Apply the transform to the whole prompter canvas, including the HUD.
- **Typography defaults (ghost-friendly):** system font, weight Heavy, size ~72 pt equivalent on iPhone, line spacing 1.6×,
  side margins 6%, white on pure black. Options: size, weight, spacing, margins, scheme (white/black, yellow/black, black/white).
- **Reading line:** a marker at ~1/3 from the top. Text above it is dimmed to ~35% so your eye lands on the next line.
- **HUD** (mirrored with the text, small, at the bottom edge): thin progress bar plus `time remaining` (m:ss).
- **Countdown:** Off, 3, 5, 10 or 15 s (default 5). Huge centred digits, optional beep per second (AudioServices system sound),
  then scrolling starts.
- **Scroll modes:**
  - *Speed*: points per second, fine steps (e.g. 1–10 scale mapped to calibrated pt/s, step 0.1).
  - *Finish in*: pick a duration; speed = remaining distance / remaining time, recalculated after scrubs.
  - *WPM*: words per minute (default 140); converted using the laid-out text's words per line.
  - Time remaining is consistent with the active mode.
- **Touch:** tap toggles pause/resume. Drag scrubs (and pauses). Pinch changes text size live and re-anchors on the current line.
  Long-press or a two-finger tap opens the settings sheet. A small, auto-hiding close button exits.
- **Hardware keys** (Bluetooth clickers, keyboards): Space/Return toggle play. Down/Right/PageDown step forward a line
  (Shift: a paragraph). Up/Left/PageUp step back. `+`/`-` change speed. `0` goes back to top. Esc exits.
- **End of script:** stops, shows "End" in the HUD, and sends `finished` to the watch.

### 3.4 Settings
- Per-prompter settings sheet (above), persisted globally in `UserDefaults` via a `PrompterSettings` Codable value.
- App settings: default countdown, beep on/off, default mode/WPM, the sample script.

## 4. Apple Watch app (companion)
One screen, designed for glancing from 1–2 m:
- **Top:** script title (one line) and state: "Open Prompter on iPhone" / Ready / 3-2-1 / Playing / Paused / Finished.
- **Centre:** large circular **Start/Pause/Resume** button inside a **progress ring**, time remaining in the middle.
- **Bottom row:** Back to top, Jump back a paragraph, Speed − / +. **Digital Crown** adjusts speed (with a haptic detent per step).
- **Haptics:** a click on each countdown second, a stronger tap at go, success at the end.
- If the phone isn't reachable: buttons disabled, with a short line "Open Prompter on your iPhone".

## 5. Watch ↔ phone protocol (`Shared/`)
- `RemoteCommand` (Codable enum): `start`, `pause`, `resume`, `togglePlay`, `speedStep(Int)`, `setSpeed(Double)`,
  `backToTop`, `jumpBack`, `requestStatus`.
- `PrompterStatus` (Codable struct): `scriptTitle`, `state` (`idle`, `countdown(seconds)`, `playing`, `paused`, `finished`),
  `progress` 0…1, `remainingSeconds`, `speedLabel`, `sequence` (monotonic, so stale updates are dropped).
- Transport: `WCSession`. Watch → phone via `sendMessage` (with reply for ack). Phone → watch via `sendMessage` while
  reachable and prompting, only when what the watch shows changes (state, title, speed, whole seconds left, progress by 0.5 %),
  with one message in flight: the watch acks each one and only the newest status waits for that (no queue, nothing while idle
  or paused). Plus `updateApplicationContext` on every state change, so a watch app opened later shows the current state
  immediately. The watch asks (`requestStatus`) when pushes go quiet while the text moves, and every few seconds otherwise.
- One `PrompterRemoteHub` on the phone owns the session and forwards commands to the active `ScrollEngine` on the main actor.

## 6. Core types (testable, no UI)
- `Script` (id, title, body, createdAt, updatedAt) + `ScriptStore` (@Observable, JSON in Application Support, atomic writes,
  import from `.txt`/`.rtf` via `NSAttributedString` → plain text).
- `ReadingStats`: word count, read time at a WPM.
- `ScrollEngine` (@Observable, @MainActor): state machine idle → countdown → playing ⇄ paused → finished. Position, speed,
  mode math, time remaining, step to line/paragraph, driven by an injected clock so tests don't need real time.
- `PrompterSettings` (Codable).
- `RemoteCommand` / `PrompterStatus` coding round-trips.

## 7. Milestones and acceptance
- **M0. Skeleton (done before the overnight run):** project generates, both targets build for the simulator, one passing test.
- **M1. Library + editor + storage:** create/edit/delete/duplicate/paste/import `.txt`/`.rtf`, sample script, stats.
  Tests for the store, import and stats. Screenshots of the library and editor.
- **M2. Prompter:** smooth mirrored scrolling, countdown, three modes, reading line, HUD, touch + hardware keys, settings,
  keep-awake. Tests for the engine (countdown, modes, time remaining, steps, finish). Screenshots: countdown, playing (mirrored),
  settings.
- **M3. Watch app + link:** watch UI, protocol, hub, Crown speed, haptics, reachability states. Protocol tests. The watchOS
  simulator runtime is installed and the watch sim is paired with the iPhone 17 Pro sim. Verified end to end on the simulators
  (start/pause/speed from the watch changes the phone; status shows on the watch). Screenshots of the watch states.
- **M4. Stretch:** voice-follow (on-device `SFSpeechRecognizer` + fuzzy word alignment to the script, pauses when you stop
  talking; mic and speech permission strings), `[pause]` / `// note` markup, PDF import, App Intents (Start/Pause Prompter),
  iPad layout polish.
- **Done means:** all milestones' tests green via `scripts/test.sh`, `scripts/build.sh` green, `docs/PROGRESS.md` complete with a
  "Needs the owner" section (signing, on-device checks), screenshots committed.

## 8. Out of scope
Video recording, captions, AI rewriting, cloud sync, accounts, subscriptions, Mac app, App Store release, ghost-cancelling shaders.
