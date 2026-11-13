# Progress

## M0. Skeleton: DONE (2026-10-06, set up before the overnight run)
- `project.yml` (XcodeGen 2.46): `Prompter` iOS app (iOS 26+, iPhone + iPad) embeds `PrompterWatch` (watchOS 10.0+, single-target
  watch app, `WKCompanionAppBundleIdentifier` = `<prefix>.prompter`), plus `PrompterTests` (Swift Testing).
- `scripts/build.sh`: green. The built `Prompter.app/Watch/PrompterWatch.app` is embedded, MinimumOSVersion 10.0.
- `scripts/test.sh`: green on the iPhone 17 Pro simulator (iOS 27).
- The watchOS 27.0 simulator runtime was installed at the start of the overnight run (`xcodebuild -downloadPlatform watchOS`, 3.8 GB).

## M1. Library + editor + storage: DONE (2026-10-07)
Plan: `docs/superpowers/plans/2026-10-06-m1-library-editor-storage.md`. Built by a multi-agent workflow: one Opus agent on the core
types, two Sonnet agents in parallel worktrees (library, editor), a merge agent, three independent reviewers whose findings were each
checked by a skeptic agent (8 confirmed, 1 refuted), and an Opus fix pass.

What works:
- **Library** (`Prompter/Features/Library`): scripts newest-edited first, each row showing title, first line, word count, read time at
  the current WPM and "edited … ago", plus a big amber **Prompt** button. The **+** menu offers New script, Paste as new script
  (title from the first line) and Import file… (`.txt`/`.rtf`, several at once, failures listed by file name). Swipe to Delete with an
  **Undo** banner (6 s; it stays put while VoiceOver is on). The context menu has Prompt, Duplicate, Rename and Delete. There is an
  empty state with the same three actions.
- **Editor** (`Prompter/Features/Editor`): title field and full-height text editor that autosave on every change, a live
  "412 words · 2:56 at 140 wpm" footer and a Prompt button. A new script left blank is removed when you leave it (and on the next
  launch if the app was killed first).
- **Storage** (`ScriptStore`): one JSON file `Application Support/Prompter/scripts.json` (`{"version":1,"scripts":[…]}`) with
  atomic writes. A file that won't decode is moved aside as `scripts-corrupt-<time>.json` and never overwritten, and a file that can't
  be read is left alone with saving switched off. Errors show once in an alert.
- **Import** (`ScriptImporter`): UTF-8/UTF-16/Windows-1252/Mac Roman text, RTF via `NSAttributedString`, line endings/BOM/NBSP cleanup.
- **Settings model** (`PrompterSettings` + `SettingsStore` in `UserDefaults`), including every M2 option, decoded tolerantly so
  future builds never reset it. Defaults: WPM mode at 140 wpm, 5 s countdown, mirror on.
- **First launch** seeds "Welcome to Prompter", a sample script that explains the controls. Deleting it doesn't bring it back.
- **Launch options** for screenshots: `-demoData` (throwaway library with 4 scripts) and `-route library|editor|prompter`.
- The Prompt button currently opens a placeholder screen; M2 replaces it with the real prompter.

Checks: `scripts/build.sh` green; `scripts/test.sh` green, **79 tests** passing (store, importer, stats, settings, launch options,
time formatting, banner timing) on the iPhone 17 Pro simulator, iOS 27.0.
Screenshots: `docs/screenshots/m1-library.png`, `docs/screenshots/m1-editor.png`.
Helper: `scripts/sim-shot.sh <name> [delay] -- <launch args>` installs the last build on the iPhone 17 Pro simulator and saves a screenshot.

## M2. Prompter: DONE (2026-10-07)
Plan: `docs/superpowers/plans/2026-10-07-m2-prompter.md`. Built with individual agents: Opus on the scroll engine and on the prompter
view, Sonnet on the settings UI, the app icons and the Maestro flows. Then an independent Opus review (0 must-fix, 5 should-fix,
all fixed with regression tests) and a Sonnet polish pass on the issues the Maestro screenshots showed.

What works:
- **Scrolling** (`Prompter/Features/Prompter`): a non-editable TextKit 2 text view moved by a `CADisplayLink` at up to 120 Hz
  (`CADisableMinimumFrameDurationOnPhone`). SwiftUI is not re-rendered per frame: about 7 screen re-evaluations in 10 s of playback.
  On the simulator it used 6–12 % CPU playing and 0 % idle, because the link sleeps when nothing moves.
- **Engine** (`Engine/ScrollEngine.swift`, pure and clock-injected): idle → countdown → playing ⇄ paused → finished. There are three modes:
  - **Speed:** levels 1–10 in 0.1 steps, in lines per second, so bigger text keeps the same pace.
  - **Finish in:** a time budget that survives pauses, scrubs and speed steps, capped at a readable 2.5 lines/s.
  - **WPM:** default 140.

  Time remaining matches the mode. Relayout (pinch, settings, rotation) keeps the same character at the reading line.
- **The glass rig:**
  - **Geometry:** mirror on by default, optional flip, and rotation 0/90/180/270 applied to the whole canvas (text, dimming,
    reading-line markers, HUD and countdown).
  - **Orientation:** landscape locked to one side per take, so picking the phone up never turns the text upside down.
  - **Text:** heavy 72 pt white on pure black with 1.6× spacing.
  - **Reading line:** a third of the way down; text above it is dimmed to 35 %.
- **Countdown:** off, 3, 5, 10 or 15 s, huge digits, a system beep per second and a distinct one at go.
- **HUD:** progress bar and time left on an opaque strip at the bottom edge, with "Ready", "Paused" or "End" plus the speed.
- **Control:**
  - **Touch:** tap to start or pause, drag to scrub, pinch for text size, long-press or two-finger tap for settings.
  - **Keys** (Bluetooth clicker or keyboard): Space/Return play, arrows and Page Up/Down step a line (Shift: a paragraph), +/- speed,
    0 back to top, Esc close.
  - **Close button:** auto-hides while playing.
- **Interruptions:** a call, Siri, Control Center or the app leaving the foreground pauses the take (or cancels the countdown).
- **Screen:** stays awake while prompting; status bar and home indicator are hidden.
- **Settings:** shown over the prompter (a popover in landscape so the text stays visible) and in app settings (the gear in the library):
  - mode and pace
  - countdown and beep
  - size, weight, spacing and margins
  - colours (white/black, yellow/black, black/white)
  - mirror, flip, rotation and landscape-only
  - reading line and dimming
  - "Restore sample script" and "Reset all settings"
- **App icon** for iPhone and watch (`scripts/make-icons.swift` draws it).
- **Maestro** (allowed by the owner on 7 Oct): `scripts/qa.sh` runs `qa/library.yaml`, `editor.yaml`, `settings.yaml` and `prompter.yaml`
  on the iPhone 17 Pro simulator, each leaving screenshots. `qa/README.md` lists the gotchas, including how to tap a landscape app on a
  portrait simulator.

Checks: `scripts/build.sh` green, `scripts/test.sh` green, all four Maestro flows green.
Screenshots: `docs/screenshots/m2-countdown.png`, `m2-playing-mirrored.png`, `m2-settings.png`.

## M3. Apple Watch remote + link: DONE (2026-10-07)
Plan: `docs/superpowers/plans/2026-10-07-m3-watch-remote.md`. Opus agents built the protocol and phone hub, then the watch app, and later
debugged a live-status bug found in the end-to-end run.

What works:
- **Protocol** (`Shared/`): `RemoteCommand` and `PrompterStatus` (Codable), one JSON payload per WatchConnectivity dictionary
  (`RemoteMessageCoder`). Sequence numbers stay increasing across phone relaunches (`SequenceClock`), so stale or out-of-order updates
  are dropped (`StatusGate`).
- **Phone hub** (`Prompter/Services/PrompterRemoteHub.swift`): owns `WCSession` through a `nonisolated` delegate and applies watch
  commands to the open prompter. Every reply carries the fresh status. It pushes a live status only when something the watch shows
  changes (state, whole seconds left, speed, progress by 0.5 %), with one message in flight at a time so a slow link never builds a
  backlog, and updates the application context on every state change. It logs to `<prefix>.prompter` / `remote`.
- **Watch app** (`PrompterWatch/`), one glanceable screen:
  - script title and state ("Open Prompter on your iPhone", "Open a script on your iPhone", Ready, 3-2-1, Playing, Paused, Finished);
  - a big amber Start/Pause/Resume button inside a progress ring, with time remaining or the countdown digit;
  - Back to top and Jump back on the left, Speed + and − on the right;
  - Digital Crown speed control with detents (steps coalesced);
  - haptics: a click per countdown second, a start tap at go, success at the end.

  Controls are disabled with a clear line when the phone can't be reached.
- **Robustness:** if the phone's pushes stop (seen on the simulators, where the phone's WatchConnectivity session sometimes wrongly
  decides the watch app isn't installed and refuses to push), the watch asks for the status itself once a second, so it never freezes.
- **App Intents** (M4, built alongside): "Start/Pause/Resume Prompter" for Siri, Shortcuts and the Action button, through the same hub.

End-to-end check on the simulators: Apple Watch SE 3 44 mm (watchOS 27) paired with the iPhone 17 Pro (iOS 27). `scripts/watch-e2e.sh`
launches the phone on the prompter. The watch runs `-remoteScript "start@8,pause@24,speedStep:5@28,resume@32,backToTop@50"`, which
sends real WatchConnectivity commands. The script saves screenshots of both screens and both logs. In the final run:
- Watch → phone commands arrived in about 0.2 s.
- The phone counted down, played, paused, went to 150 wpm, resumed and returned to the top, all as commanded.
- The watch tracked it, about 1.3 s behind (the simulator delivers in batches), showing 5, 4 … Playing, Paused, 150 wpm, Playing, Ready.
- Earlier runs showed simulator delivery stalls of up to ~12 s; the watch's own status requests recover from those.

Screenshots: `docs/screenshots/m3-watch-{ready,countdown,playing,paused,finished,unreachable,noprompter}.png` and the 40 mm variants (made
with the watch's `-demoStatus` debug option), plus the end-to-end pairs `m3-e2e-03-playing-{phone,watch}.png` and
`m3-e2e-04-paused-{phone,watch}.png`.
Checks: `scripts/build.sh` green (iOS app with the embedded watch app), `scripts/test.sh` green, **364 tests**.

## M4. Stretch: DONE (2026-10-07)

### Voice-follow
Plan: `docs/superpowers/plans/2026-10-07-m4-stretch.md` (all six tasks). Voice-follow was built by one Opus agent.

What works:
- **Scroll mode "Voice"** (Settings > Scrolling, fourth segment): start counts down as usual, then the text waits for you.
  As you read, the line you're on comes up to the reading line. It glides there, never faster than 4 lines a second and
  never with a jump. Stop talking and it stays put; after 2 s the HUD says "Listening…". Start again and it carries on.
  Pause turns the microphone off. `[pause N]` cues don't hold in voice mode (you set the pace), speed steps from the watch,
  keys or Crown do nothing, and the watch shows "Voice" as the speed. Time left is the rest of the script at your WPM
  setting (Settings shows the Pace slider in voice mode for that).
- **Following** (`Prompter/Features/Prompter/Voice/`):
  - `VoiceAligner` (pure) aligns the last 6 heard words against the script around where you are, from 5 words back to
    60 ahead, using only words on text lines (notes and cues aren't read). Words match loosely: "45" = "forty-five",
    "don't" = "do not", "memorizing" = "memorising".
  - It moves on as you read, catches up if you skip ahead (with 3 or more words in agreement), and holds still on ad-libs.
    It never jumps back on a repeated word; re-reading a phrase does take it back.
  - Recognisers keep rewriting the words just heard, and that never moves the text backwards.
  - A step, drag or back to top by hand makes it pick up from the new place.
- **Listening** (`LiveSpeechSource`): on-device only. On the iPhone it uses iOS 26's SpeechAnalyzer + SpeechTranscriber, which
  needs no speech-recognition permission and updates about once a second. Where that isn't available it falls back to
  SFSpeechRecognizer on-device, restarting its tasks. The microphone is on only while a voice take is playing, and comes
  on 0.4 s after "go" so the beep isn't clipped. Nothing is recorded or sent.
- **Permissions:** asked when Voice is picked in Settings, or when the prompter opens in voice mode, never at launch. If
  anything is missing (permission denied, no recogniser for the script's language, the speech model can't download, or the
  microphone fails mid-take):
  - the take scrolls at the WPM pace instead;
  - the HUD says so in plain words ("Voice needs microphone access. Scrolling at your set pace instead.") whenever the text isn't moving;
  - the settings footer says the same and offers Open Settings.
- Purpose strings in `project.yml`. The privacy manifest is unchanged, because voice mode uses no required-reason API
  (checked on the Release build).

Checks:
- `scripts/build.sh` and the Release device build: green.
- `scripts/test.sh`: green, **441 tests**. New suites: `VoiceTextTests`, `VoiceAlignerTests`, `SpeechTranscriptTests`,
  `VoiceLocaleTests`, `VoiceFollowControllerTests` (with a fake microphone, including `deniedFallsBackToWPM`) and
  `ScrollEngineVoiceTests`.
- `scripts/qa.sh prompter settings voice`: green. The new `qa/voice.yaml` covers denied and allowed, in settings and in the
  prompter.
- **The simulator can't recognise speech.** SpeechTranscriber is unavailable there, DictationTranscriber says "Model not
  available" and SFSpeechRecognizer fails with `kLSRErrorDomain 300`. Fed the audio file (`-voiceFile`), the app does the
  right thing: it gives up after five quick failures and scrolls at 140 wpm. So the check was done in two halves:
  - **Recognition, on the Mac** (`scripts/voice-check.sh`): the app's own SpeechAnalyzer code, transcript and aligner
    files, compiled for macOS, were fed a spoken read-through of the demo script in real time (`say`, 29 s). All 84 words
    were followed in order, with no backward moves, the last one 0.4 s after the audio ended.
  - **The app, on the simulator** (`scripts/voice-demo.sh`): those recorded results, replayed at their recorded times
    (`-voiceReplay`), through the real transcript → aligner → engine → screen path.

Screenshots (all of the replay ones are labelled as a replay):
- `docs/screenshots/m4-voice-listening.png`: just after "go", "Listening…".
- `m4-voice-following-1/2/3.png`: following the read-through.
- `m4-voice-holding.png`: the recording has ended, so the next line waits at the reading line with "Listening…".
- `m4-voice-denied-hud.png`, `m4-voice-settings-denied.png`, `m4-voice-settings.png`.

### Script markup (`[pause]` cues and `// notes`)
- A line starting with `//` is a note for you: shown at about half size, italic and dimmed, and not counted in words or time.
- A line that is exactly `[pause]` or `[pause 3]` is a cue: a small amber "PAUSE 3s" line.
  - **`[pause N]`:** holds the text for N seconds when it reaches the reading line, with "Pause 3" in the HUD. Pausing or dragging
    skips the hold, and stepping back re-arms it.
  - **`[pause]`:** a visual cue only.
  - **Timing:** read times include the holds, and WPM paces only the spoken lines.
- Only whole lines count, so `//` in a URL or "[pause] for effect" inside a sentence stay ordinary text.
- The sample script shows one note and one cue. The editor shows a one-line tip until a script uses markup.
- Screenshots: `docs/screenshots/m4-markup-note.png`, `m4-markup-pause.png`.

### PDF import
- **Import file…** accepts `.pdf` alongside `.txt` and `.rtf`, through PDFKit. Pages are joined with a blank line, and words hyphenated
  across a line break are rejoined.
- A scanned PDF with no text says "This PDF has no text to import (it may be a scan)." A broken or password-protected PDF says it
  couldn't be read.

### App Intents (Siri, Shortcuts, Action button)
- "Start Prompter", "Pause Prompter" and "Resume Prompter" act on the open prompter through the same hub as the watch.
- They run in the foreground and wait up to 2 s for the prompter to be on screen. With no prompter open they answer "Tap Prompt on a
  script in Prompter first."

### iPad
- At full width the library is a split view: scripts on the left, the editor on the right, the same actions, and ⌘N for a new script.
- The prompter scales the text so about the same number of words fit per line as on the iPhone.
- Screenshots: `docs/screenshots/m4-ipad-*.png`. Flows: `qa/ipad-library.yaml`, `qa/ipad-landscape.yaml`.

### Release readiness (TestFlight)
- Version 1.0.0 (build 1), shared by the phone and watch apps from one place in `project.yml`. `scripts/bump-build.sh` gives the next
  build number.
- Privacy manifests for both apps: no tracking and no data collected. Declared API uses: UserDefaults `CA92.1` on the phone,
  system boot time `35F9.1` on the watch.
- `ITSAppUsesNonExemptEncryption = NO`, purpose strings for the microphone and speech, a dark launch screen, and app icons for both apps.
- The Release build for a real device compiles cleanly, with the watch app embedded.
- `scripts/archive.sh` archives and exports with your team once you set `TEAM_ID`. The full morning steps are in
  **`docs/testflight-checklist.md`**.

## Final QA (2026-10-07, before TestFlight)
Three independent reviews of the whole app, plus a full end-to-end pass:
- **Logic review (Opus):** one must-fix and four should-fixes.
- **Release-readiness review (Opus):** no upload blockers, no launch crashes on iOS 26 or watchOS 10.
- **UX, copy and accessibility review (Sonnet):** no spec misses.
- **Shoot-day journey (Sonnet):** `qa/journey.yaml`. It creates a script with a note and a pause cue, prompts it, pauses, changes
  settings in the popover, resumes through the hold, closes, deletes with Undo and checks the settings stuck.

Everything they raised was fixed:
- **Watch and Siri commands only act on a prompter you can see.** With the phone app in the background or the phone locked, Start and
  Resume are refused and the watch says "Open Prompter on your iPhone". Before, an invisible countdown could start and fire on return.
- **Voice mode recovers** from audio interruptions and media-server resets. A quick pause-resume can no longer switch off the new take's
  microphone.
- **WPM paces the spoken lines** at exactly your setting when a script has notes or cues.
- **A crash is fixed** for scripts containing some CJK numerals ("2.5万").
- **Launch:** the library is protected if the app is started before the first unlock after a reboot, and the screen-sleep restore can no
  longer get stuck.
- **HUD:** shows "Tap to start" when ready, and the amber markers have enough contrast on the black-on-white scheme.
- **Copy:**
  - the sample script now tells you to tap the screen to start, and that the watch needs the prompter open;
  - the rotation hint is clearer;
  - "Silent mode mutes the beeps" is stated;
  - US spelling throughout;
  - the permission strings say "this device".
- **Accessibility:** Dynamic Type fixes in Settings and the library, Reduce Motion support, VoiceOver hints, and wider watch buttons on
  40 mm.
- **Settings → How to use:** a page listing every gesture, key, watch control and markup.

Checks after the fixes are under "Final state" at the end of this file.

One more fix came out of the last watch end-to-end run. The phone used to push status 4 times a second whether or not anything had
changed (217 messages a minute), and the simulators' link drains more slowly than that, so statuses reached the watch 7–13 s late.
Now it pushes only on change, with one message in flight (about 30 messages a minute):
- start → countdown on the watch: 0.2–0.8 s;
- pause, speed and resume: 0.2–1.7 s;
- every reply: under 2 s.

**Known behaviour (by design):** with `// notes` or `[pause]` cues, the prompter's time left (it also counts the scroll time of the note
and cue lines) can be a few seconds longer than the library's read time (spoken words at your WPM plus holds).

## Needs the owner
### This morning: TestFlight (full steps in `docs/testflight-checklist.md`)
1. **Tools:** use `/Applications/Xcode.app` (27.0, a release), not the 27.1 beta that is also installed. Accept any pending Apple
   agreements (developer.apple.com and App Store Connect).
2. **Signing:** put your team ID and bundle ID prefix in `Config/Local.xcconfig` (git-ignored; copy
   `Config/Local.xcconfig.example`), then `xcodegen generate`. Nothing signing-related was changed overnight.
3. **Register the iPhone:** run once on it from Xcode, which needs Developer Mode on the phone and "Trust this computer". This also
   registers both App IDs, `<prefix>.prompter` and `.watchkitapp`.
4. **App Store Connect:** create the app record. The store name "Prompter" is probably taken, so pick a unique one; the home-screen
   name stays "Prompter".
5. **Upload:** archive and upload, with Xcode → Product → Archive → Distribute → TestFlight, or `TEAM_ID=<your team ID> scripts/archive.sh`
   and then Transporter. Answer "No" to export compliance (already set in the app).
6. **Install:** add yourself as an internal tester and install from TestFlight. The watch app installs through the iPhone's Watch app.
7. **Next upload:** `scripts/bump-build.sh` gives the next build number.

### Checks after installing
- **Paste as new script:** iOS asks "Allow Paste" each time an app reads the clipboard. To skip that, turn on Settings → Prompter →
  Paste from Other Apps → Allow.
- **Prompter checks only a real iPhone can do** (the simulator can't):
  - **Smoothness:** does the 120 Hz scroll feel smooth on the iPhone 17 Pro?
  - **Gestures:** pinch to resize, and two-finger tap for settings.
  - **Clicker:** does a Bluetooth clicker's Page Up/Down or arrows step the script?
  - **Beeps:** countdown beeps are system sounds, so they are silent when the ring/silent switch is on silent.
  - **Legibility:** read the default heavy white text through the acrylic and judge the ghosting.
  - **Landscape lock:** it picks the side the phone is on when you open the prompter. Hold the phone the way it sits in the cradle when
    you tap Prompt. If it ever comes up wrong, Settings → Rotation fixes it.
- **Watch checks only real devices can do:**
  - How fast a command and the status really travel between your iPhone and watch. The simulators batch about once a second; real
    devices are usually quicker.
  - How the Crown detents and the countdown haptics feel.
  - On the watch, set Settings → General → Return to Clock → Prompter to a long timeout so the remote stays on screen during takes.
- **App Intents:** in the Shortcuts app you should see Start, Pause and Resume Prompter. To use the Action button, go to Settings → Action
  Button → Shortcut → "Start Prompter".
- **Voice mode, on the iPhone** (the simulator can't recognise speech, so none of this has run on a phone yet). Put the
  phone in the rig and stand where you film from:
  1. Settings (gear) > Scrolling > **Voice**. Allow the microphone when asked. If iOS also asks about speech recognition,
     the phone is using the older fallback recogniser; allow that too and note it.
  2. Open "YouTube intro: rig tour" (or any script) and tap Start, or start from the watch. After the countdown the HUD
     says "Listening…". Read the first paragraph at your normal pace. Does each line come up to the reading line as you
     reach it, smoothly and without lagging more than a word or two?
  3. Stop for 3 s mid-paragraph: the text should stay still and "Listening…" should show. Carry on reading: it should
     follow again.
  4. Ad-lib a sentence that isn't in the script: the text should not move. Then skip a sentence and read the next one: it
     should catch up within three or four words. Repeat a line you just read: it should not jump back.
  5. Listen for the countdown beeps and the "go" sound: are they all still there and unclipped in voice mode? The
     microphone comes on 0.4 s after go.
  6. Pause with the watch: the microphone indicator (orange dot) should go off. Resume: it comes back.
  7. The first voice take may need to download Apple's speech model once (needs internet). If the HUD says "Voice needs a
     one-time download of the speech model…", connect to Wi-Fi and open the prompter again.
  8. Try it at 1 to 2 m from the phone with the camera rolling. If it misses words, say how far and how loud; a closer mic
     plugged into the phone is used automatically.
  9. Deny check, optional: Settings app > Apps > Prompter > Microphone off, then open the prompter. It should say "Voice
     needs microphone access. Scrolling at your set pace instead." and scroll at your WPM pace.

## Final state (2026-10-07, 07:00)
All milestones M1–M4 are done. Everything below was run by the orchestrator on the final code (`main`):
- `scripts/build.sh`: green (the iPhone app with the embedded watch app, Debug, for the simulator).
- `scripts/test.sh`: **524 tests, all passing** (Swift Testing, iPhone 17 Pro simulator, iOS 27.0).
- `scripts/qa.sh`: **all 6 iPhone flows pass** (library, editor, settings, prompter, voice, journey). `SIM="iPad Pro 13-inch (M5)"
  scripts/qa.sh`: **both iPad flows pass** (ipad-library, ipad-landscape).
- `scripts/watch-e2e.sh` on the paired iPhone 17 Pro and Apple Watch SE 3 simulators:
  - every watch command reached the phone in about 0.2 s and did what it should;
  - once the link was warm, the watch showed the result in 0.2–1.7 s.
  - **Simulator caveat:** for the first 10–15 s after the watch app launches, the simulators' WatchConnectivity sometimes delivers
    nothing at all. The watch catches up when it does.
- **Release build for a real iPhone** (`generic/platform=iOS`, no signing): succeeds with no warnings and the watch app embedded.
  Both apps are 1.0.0 (1), with privacy manifests, `ITSAppUsesNonExemptEncryption = NO`, purpose strings and a dark launch screen.
- **Screenshots:** `docs/screenshots/` (M1–M4). **Plans:** `docs/superpowers/plans/`.
- **Every UI change has a Maestro flow** in `qa/`.
- **Only a real device can check:** feel, sound and haptics, real WatchConnectivity latency and voice recognition. See the checks
  under "Needs the owner".


## M5. Shared core + macOS target: DONE (2026-10-07)
Plan: `docs/superpowers/plans/2026-10-08-m5-m8-mac-and-sync.md` (M5–M8: Prompter for Mac and Mac/iPhone sync).
- **`Core/`** (compiled into the iPhone app and the Mac app; moved with `git mv`, names unchanged):
  `Models/*`, `Services/{ScriptStore,ScriptImporter,SettingsStore,ProtectedDataWait}`,
  `Engine/{ScrollEngine (+ ScrollTiming),PrompterLayout,DisplayPositionSmoother,PrompterKeyAction,VoiceProblem}`,
  `Text/{PrompterDocument,PrompterText,PrompterLayoutExtractor}`, `Platform/PlatformTypes` (`PlatformFont`/`PlatformColor`),
  `Support/LaunchArguments` (the `-flag` / bare-flag parsing both apps use).
- **Platform shims:** the protected-data wait (before the first unlock) is iOS-only; on the Mac the stores never wait. RTF import uses
  AppKit's `NSAttributedString` on the Mac, PDF import uses PDFKit on both. The store's error messages say "Mac" on the Mac.
  `PrompterTextStyle.textContainerInset` (`UIEdgeInsets`) and the `…UIColor` names stay iOS-only; both platforms have
  `foregroundColor`/`backgroundColor`/`cueColor` and the new `textWidth`. The UIKit key map stays in the iOS app; the Mac has
  `MacKeyMap` (virtual key codes → the same `PrompterKeyAction`s).
- **View-less layout:** `PrompterLayoutExtractor.layout(of: document, style:)` lays the script out with its own TextKit 2 stack. An
  iOS test checks that it gives exactly the same layout as the iPhone's text view.
- **Prompter for Mac skeleton** (`PrompterMac/`): macOS 26 app "Prompter" (`<prefix>.prompter.mac`), dark-only, signed to run
  locally (ad hoc, no team needed), not sandboxed. It shows a split view of the library from `~/Library/Application Support/Prompter/`.
  With `-demoData` (and when it hosts the tests) it uses a temp library with the demo scripts and throwaway settings. The app icon is
  generated by `scripts/make-icons.swift`: the same art in a macOS squircle. The accent colour is amber.
- **Debug options:** `-snapshot <dir>` makes the app write PNGs of its own windows (no screen-recording permission needed, nothing else
  on screen captured; Liquid Glass is drawn flat). `-quitAfter <seconds>` quits it afterwards.
- **Scripts:** `scripts/build-mac.sh` builds the app to `build/DerivedData/Build/Products/Debug/Prompter.app`, and
  `scripts/test-mac.sh` runs the `PrompterMacTests`.

Checks: `scripts/build.sh` green; `SIM="Prompter Dev iPhone" scripts/test.sh` **525 tests** passing (524 + the layout parity
test); `scripts/build-mac.sh` green; `scripts/test-mac.sh` **19 tests** passing (store round trip, RTF/PDF/text import, the
text builder, the view-less layout, the engine ticking, key map, launch options).
Screenshot: `docs/screenshots/m5-mac-skeleton.png` (taken by the app's own `-snapshot`).

## M6. Prompter for Mac: library, HDMI output and Presenter view: DONE (2026-10-08)
Plan: `docs/superpowers/plans/2026-10-08-m5-m8-mac-and-sync.md` (6a: Sonnet, 6b: Opus, in parallel; merged and verified by the
orchestrator).
- **Library and editor** (`PrompterMac/Features/Library`, `Editor`):
  - a sidebar with search and rows (title, first line, words, read time, edited), and an editor with live stats;
  - in the editor, notes show dimmed and `[pause]` cues in amber;
  - New script ⌘N, Paste as new script ⇧⌘V, Import… ⌘O (`.txt`/`.rtf`/`.pdf`, or drag files onto the window), Duplicate ⌘D, Rename,
    Delete with Undo ⌘Z, Prompt ⌘↩;
  - Settings (⌘,) with General, Text, Teleprompter, Library and How to use tabs, plus an iPhone tab for sync (M7).
- **Output on the teleprompter screen** (`PrompterMac/Features/Prompter`): a borderless, black, full-screen window on the chosen display
  (above the menu bar and Dock, pointer hidden). It has the mirrored/flipped/rotated text, reading-line markers, dimming, the HUD strip
  and the countdown, drawn as a Core Animation layer tree from the same TextKit 2 layout as the scroll engine.
- **Display choice:** it picks the external screen automatically (not the built-in one, not the one with the menu bar) and remembers
  the choice. If a screen is unplugged mid-take, it pauses and falls back. With a single screen, both windows are normal windows.
- **Presenter view on the laptop** (PowerPoint-style, full screen, as the owner chose):
  - a live, readable preview with a "Show as on the teleprompter" toggle;
  - time left, elapsed, progress and pace;
  - big transport buttons (Back to top, Jump back, Line back, Start/Pause, Line forward, Speed − / +);
  - a live settings panel, a script switcher, the screen picker with Swap screens, and Stop presenting (Esc).
- **Keys:** Space/Return, ↑/↓, Page Up/Down (⇧ for a paragraph), +/−, 0 and Esc. Display sleep is held off while presenting, and the
  countdown beeps use system sounds.
- Checks: `scripts/build-mac.sh` and `scripts/test-mac.sh` (93 tests), `scripts/build.sh` (iOS) green.
  - **Displays:** the output was checked by snapshot on the second screen (the 2560×1440 stand-in for the HDMI teleprompter) and the
    Presenter view on the main screen.
  - **Snapshots:** taken with `-presenterSnapshots`, because agents can't use `screencapture`.
- Screenshots: `docs/screenshots/m6-mac-library.png`, `m6-mac-settings.png`, `m6-output-mirrored.png`, `m6-output-countdown.png`,
  `m6-presenter.png`, `m6-presenter-settings.png`.

## M7. Mac ⇄ iPhone script sync: DONE (2026-10-08)
Plan: `docs/superpowers/plans/2026-10-08-m5-m8-mac-and-sync.md`, section M7. A script written or pasted on the Mac shows up on the
iPhone about 0.3 s later, and the other way round; edits and deletions too; an iPhone that was away catches up when Prompter opens.

**Design** (`Core/Sync/`, compiled into both apps):
- **Merge** (`SyncModels.swift`, pure): last writer wins on a per-script *sync clock* (milliseconds since 1970; kept apart from
  `updatedAt`, which is whole seconds for the library's sorting). A local change always takes a clock just after the version it
  replaces (`SyncClock.next`), so it wins even when this device's clock is behind the other's. Same clock: a deletion beats an
  edit (an older copy never brings a deleted script back); two edits are split by a content digest, so both devices pick the same
  one. (The plan said "ties by device id"; the digest gives the same guarantee without recording who made each edit.) Deletions
  are kept as tombstones for 30 days.
- **Library** (`ScriptStore`): file format **v2** adds `clocks` and `tombstones`; a v1 file loads as is (its clocks are the
  `updatedAt`s), and an older app reading v2 ignores the new keys. `applyRemote(scripts:deletions:)` merges without touching
  dates and without reporting a local change, so nothing echoes. `onLocalChange` fires on every local change; `remoteChange`
  tells an open editor (iPhone and Mac) to take in the new version instead of saving its stale draft over it. Undoing a delete
  gets a fresh clock, so it wins over the deletion on the other device too. Blank new scripts are not shared.
- **Protocol** (`SyncMessages.swift`, `SyncSession.swift`): JSON messages (`hello`, `manifest`, `scripts`, `deletions`, `ack`,
  `pairRequest`, `pairAccepted`, `unpair`) in 4-byte length-prefixed frames (a pure decoder rather than an `NWProtocolFramer`, so
  framing is unit-tested on its own). Both sides send hello + manifest, then each sends what wins over the other's version, and
  remembers what the peer has so it never sends anything back. Local changes are pushed as they happen, gathered for 0.3 s.
- **Transport** (`SyncConnection.swift`, `SyncHost.swift`, `SyncClient.swift`, Network.framework, after Apple's peer-to-peer
  sample): the Mac runs an `NWListener` advertising `_prompter-sync._tcp` (TXT: id, name, protocol version, demo flag) only while
  an iPhone is paired or a code is showing; the iPhone runs an `NWBrowser` only while paired or on the Sync with Mac screen, and
  only in the foreground. Background: disconnects cleanly; foreground: reconnects and catches up. Reconnect back-off 1, 2, 4, 8,
  16, then 30 s, and at once when the Mac reappears in Bonjour.
- **Security:** TLS with pre-shared keys. Network.framework can't do TLS 1.3 with an external PSK (the handshake fails; checked on
  this Mac), so it is **TLS 1.2 pinned to `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256`**: ephemeral ECDHE gives forward secrecy,
  and nobody who records the pairing can test codes offline. Pairing: the Mac shows a random 6-digit code (5 minutes); both sides
  turn it into a 256-bit key (HKDF-SHA256, fixed salt); over that one connection the Mac hands the iPhone a fresh random 256-bit
  key, and only that key (identity: the iPhone's id) is used from then on. Five wrong codes close pairing. A peer without a
  matching key fails the TLS handshake ("unpaired peers are refused"); Forget on the Mac removes the key, Forget on the iPhone
  tells the Mac (`unpair`). Keys live in `sync.json` next to the library (0600; on the iPhone encrypted until first unlock), not
  the Keychain: the scripts they protect are a plain file in the same folder, and an ad-hoc-signed Mac app would get Keychain
  password prompts after every rebuild.
- **UI:** Mac Settings → **iPhone**: Pair an iPhone (big code with a countdown, Cancel), paired iPhones with Connected / Last
  synced …, Forget. iPhone Settings → **Sync with Mac**: Macs on this network, tap → code → paired; then status, Sync now, Forget.
  Libraries: "Synced with Studio Mac" under the iPhone's Scripts title, and a line at the bottom of the Mac's script list.
- **Info.plist:** both apps have `NSLocalNetworkUsageDescription` and `NSBonjourServices` = `_prompter-sync._tcp` (the Mac's
  string says "finds your iPhone"). `ITSAppUsesNonExemptEncryption` stays NO (Apple's TLS only; noted in
  `docs/testflight-checklist.md`). Privacy manifests unchanged (no required-reason API).
- **Debug options** (both apps): `-syncPairingCode 123456` pairs with no UI (the Mac keeps that code open); `-syncDemo` (Mac:
  create, edit, delete a script once an iPhone connects; iPhone: create one); `-syncPort` (Mac) and `-syncHost 127.0.0.1:<port>`
  (iPhone) for loopback runs without Bonjour. With `-demoData` the library *and* the pairings are throwaway, and demo Macs and
  demo iPhones only see each other. iPhone `-route syncSettings` opens Settings → Sync with Mac; Mac `-snapshotDelay <s>`.

**Local Network privacy on macOS (finding):** macOS 26 applies Local Network privacy to the Mac app too. When the listener first
advertised over Bonjour, `nehelper` was consulted and a UserNotificationCenter window appeared (4×4 px, no readable text through
Accessibility; nothing was clicked). The NetworkExtension rules show `<prefix>.prompter.mac` with Local Network
**not yet answered** (`DenyMulticast = true`, `MulticastPreferenceSet = false`), as are the iOS app and Claude Code. Loopback is
exempt: a listener without Bonjour (`-syncPort`) consults nothing and works, so the unattended checks use loopback with the very
same TLS, pairing and protocol code. Bonjour discovery itself is still unverified on this Mac and needs the owner (below).

**End-to-end (the real apps):** `scripts/sync-e2e.sh` runs Prompter for Mac (`-demoData -emptyLibrary -syncPairingCode 123456
-syncPort 50123 -syncDemo`) and the iPhone app on "Prompter Dev iPhone" (`-demoData -syncPairingCode 123456 -syncHost
127.0.0.1:50123 -syncDemo`), watches both library files and the logs, and takes screenshots. Final run: they paired on their own;
the Mac's new script, its edit and its deletion reached the iPhone's `scripts.json` (read through `simctl get_app_container`;
the deleted one gone, its tombstone kept), and the iPhone's new script reached the Mac's library file. Latency from the change on
one side to "applied" on the other (same clock): **0.21 s create, 0.32 s edit, 0.32 s delete Mac → iPhone; 0.30 s create
iPhone → Mac**, which is the 0.3 s gathering delay plus about 20 ms. The iPhone's four demo scripts went to the Mac as well.

Checks: `scripts/build.sh` and `scripts/build-mac.sh` green; `SIM="Prompter Dev iPhone" scripts/test.sh` **577 tests** and
`scripts/test-mac.sh` **151 tests**, all passing. New suites in `CoreTests/` (run on both platforms): `SyncMergeTests` (every
conflict, ties, clock skew, resurrection guard, tombstone expiry), `SyncProtocolTests` (framing across every split, oversize,
message round trips, codes, pinned key derivation, back-off), `ScriptStoreSyncTests` (v1 → v2, clocks and tombstones on disk,
applyRemote without echo, undo beats deletion), `SyncSessionTests` (two sessions in memory: first merge, push without echo, no
resend on reconnect, offline catch-up, conflicts, same-instant tie). Mac only: `SyncLoopbackTests`, a real `SyncHost` and
`SyncClient` over TLS on 127.0.0.1: pair and sync both ways, wrong code, five wrong codes close pairing, forgotten iPhone
refused, Forget on the iPhone unpairs the Mac, background/foreground catch-up, reconnect after the Mac comes back.
`SIM_UDID=… SKIP_BUILD=1 scripts/qa.sh library settings`: both pass (`qa/settings.yaml` now also checks the Sync with Mac row).
Screenshots: `docs/screenshots/m7-mac-pairing.png`, `m7-mac-library.png`, `m7-iphone-sync-settings.png`,
`m7-synced-iphone-library.png`.

**Known limits:**
- One Mac per iPhone (a Mac can have several iPhones). Sync needs both apps open on the same network; nothing syncs through a
  server.
- A device away for more than 30 days can bring back a script deleted meanwhile (its tombstone has expired).
- Last writer wins per script: if both sides edit the same script while apart, the later edit replaces the other one whole.
- An open editor takes in a new version from the other device; typing on both at the same moment can move the cursor.
- Settings (speed, mirror…) don't sync, only scripts.
- Skipped (optional stretch): the Mac as a remote for the iPhone's open prompter.

### Needs the owner: pair your real iPhone and Mac
1. Build and run Prompter for Mac (`scripts/build-mac.sh`, then open `build/DerivedData/Build/Products/Debug/Prompter.app`) and
   install the new iPhone build (Xcode or TestFlight).
2. On the Mac: Prompter → Settings (⌘,) → **iPhone** → **Pair an iPhone**. macOS asks "Allow “Prompter” to find devices on local
   networks?" → **Allow**. (Already answered or missed it: System Settings → Privacy & Security → Local Network → Prompter on.
   A request from an earlier run may already be pending.)
3. On the iPhone, same Wi-Fi: Prompter → Settings (gear) → **Sync with Mac**. iOS asks to find devices on your local network →
   **Allow**. Tap your Mac, type the 6-digit code from the Mac, Pair.
4. Check: the Mac lists the iPhone as Connected; the iPhone's library says "Synced with <your Mac>". Paste a script on the Mac
   (⇧⌘V): it should be on the iPhone within a second. Then edit one on the iPhone and watch the Mac.
5. Please confirm the Mac shows up in the iPhone's list over Bonjour (not testable unattended here, see above). If it doesn't,
   check that neither device has Local Network off for Prompter.

### M8: Mac UI polish, guidance, accessibility, README for Mac
From an independent UX review (copy, guidance, accessibility only; no sync or presenting logic changed apart from
`SyncHost.clearPairingMessage()`).
- **Mac Settings → iPhone:** header "iPhone sync"; an orange Local Network hint with a button to System Settings when the listener
  fails or is still starting after 3 s; pairing failures in orange, "Paired with…" in green, cleared after 10 s or when the tab
  closes; the pairing-reset message with Dismiss.
- **iPhone Sync with Mac:** "Not seeing your Mac?" after 8 s of looking; the refused state says so plainly with **Pair again** and
  **Forget**; a wrong code adds "Codes expire after 5 minutes."; the pairing-reset message; the settings row says "Not paired".
- **Guidance:** Mac Settings → How to use gains "Teleprompter screen" (HDMI, Esc, Mirror Displays); the Presenter view shows a
  one-line banner while only one screen is found.
- **Presenter view:** the wide layout starts at 1440 pt (it overflowed between 1180 and 1420 before) and, with the settings panel
  open, at 1830 pt; below that the compact layout has the same 96 pt "Time left", a keys strip and the settings panel inline, so
  a 14" MacBook never overflows. Notch inset, wall clock, "Press Space or click Start" prompt, screen name and resolution,
  complete key legend, bigger captions (13 pt) and state pill (20 pt), the state pill no longer overlaps the top-bar buttons.
  VoiceOver: preview label and state value, toggle trait, chip pickers and sections grouped with their titles, "Time left";
  Reduce Motion for the panel transition.
- **Copy:** "Words per minute", "White on black / Yellow on black / Black on white" and "Mirror and rotation" are the same on the Mac
  (Settings and Presenter panel) and the iPhone (the iPhone's WPM segment keeps "WPM", it has no room for more); "While presenting";
  "Stop presenting".
- **Library:** "Pair an iPhone…" under the script list while nothing is paired, and in the File menu; an empty library says
  "Write your first script" once. New **Presenter** menu (Start/Pause, Back to top, Swap screens, Stop presenting ⌘.).
- **README:** "Prompter for Mac", the sync steps, Local Network prompts and troubleshooting.
- Screenshots: `docs/screenshots/m8-presenter.png`, `m8-presenter-settings.png`, `m8-presenter-single-screen.png`,
  `m8-mac-pairing.png`, `m8-iphone-sync.png`.
- Not verified here: the Presenter menu's enabled state while presenting (needs the menu bar, which unattended runs can't
  drive), the notch inset (no notched screen on this Mac), the refused-state screen on the iPhone, `qa/voice.yaml` (its "Pace"
  check is now "Words per minute"; the flow wasn't run).

### M8: Sync and presenting fixes from the independent correctness review (Opus, `fbb5f06`)
- **Your iPhone's sample script is safe:** the Mac's first-launch sample has clock 0 and isn't shared until edited. A fresh Mac can
  never overwrite your edited sample on the iPhone, or bring back one you deleted.
- **Memory:** each presenting session is fully released when you stop. It used to leak the rendered text, roughly 25–100 MB per take.
- **Mac editor:** a version that arrives from the iPhone goes in as one undoable step, so ⌘Z can't garble the text, and Undo/Redo
  now save. A version arriving while you're typing an accented character waits for you to finish.
- **Re-pairing after Forget works:** a forgotten iPhone stops retrying and no longer uses up the 5 tries.
- **Several devices:** the Mac passes changes on between them, for example iPhone ⇄ iPad.
- **Hardening:**
  - large libraries are sent in batches of at most 4 MB;
  - device ids are tied to their key with an HMAC proof;
  - a handshake times out after 10 s, and only a few connections may wait at once;
  - the debug pairing code works only with `-demoData`;
  - a damaged pairing file is kept and you're told to pair again.

  Because of the proof, **update both apps together**: an older iPhone build is refused by this Mac build.
- **Mac app behaviour:**
  - ⌘W on the library no longer quits Prompter, and the Dock icon brings it back;
  - closing the laptop lid mid-take pauses and keeps the output full screen;
  - screen changes show a short notice in the Presenter view;
  - Esc pauses a running take first, then stops presenting.
- A regression test pins each one. Mac tests: 186.

## M9. Markdown support: DONE (2026-10-08)
Plan: `docs/superpowers/plans/2026-10-08-m9-markdown.md`. Built by one Opus agent in its own worktree.
- **Setting:** "Markdown formatting", on by default (iPhone Settings → Text and the prompter's settings popover; Mac Settings →
  Text and the Presenter view's settings panel). Older settings without the key decode as on. A script without Markdown looks
  exactly the same either way; off, every symbol shows as typed.
- **On the teleprompter:** `**bold**`/`__bold__` in the scheme's amber cue colour (same Heavy font, so nothing reflows);
  `*italic*`/`_italic_` italic; `~~strike~~` struck through and dimmed; `` `code` `` plain; `[text](url)` text only; `\*` a real
  `*`. `# `/`## `/`### ` headings are amber section titles at 1.2×/1.1×/1.0×; `- `/`* `/`+ ` become "•"; `1. ` keeps its
  number; `> ` quotes show plain; `---` is a thin dimmed line. Unmatched markers (`**bold`) show as typed, nothing is
  swallowed. `// notes` and `[pause N]` lines win over Markdown; notes take inline Markdown too (bold stays dim in a note).
- **Parser:** our own (`Core/Text/MarkdownInline.swift`, `ScriptMarkdown.swift`), not Foundation's, because the Mac editor needs
  the source position of each marker and both apps must agree. It follows CommonMark's emphasis algorithm; a test checks 46
  cases against Foundation's `AttributedString(markdown:)` (the 3 places Foundation differs are its own quirks: nested strong,
  bold inside link text, an image attachment character). Not handled, shown as typed: HTML, entities, autolinks, single `~`.
- **Timing:** word counts and read times (library rows, both editors, the engine's WPM pace, voice-follow) count the words the
  prompter shows. Headings, like notes, are not spoken words: not counted, not followed by voice, and they don't slow the WPM
  pace (it is spread over the text lines); they scroll past at the same speed, so (as with notes) the prompter's time left can
  be a few seconds above the library's read time. Numbered items keep and count their number.
- **Live switch:** toggling while the prompter is open re-lays the text (iPhone: the document and the voice aligner are rebuilt;
  Mac: the session's document), and the engine keeps its place.
- **Editors:** the Mac editor shows Markdown as you type (bold amber, italic, struck, headings bigger and amber, markers dimmed)
  next to the note/cue colours; the iPhone editor stays plain text and its tip mentions Markdown while the setting is on.
- **Import:** `.md` and `.markdown` (and `.mdown`/`.mkd`/`.mkdn`) on both, Markdown kept as written, title from the file name.
- **How to use** on both apps has a Markdown section. README updated.
- **Debug:** `-demoData -script markdown` (both apps) adds the "Markdown demo: talking to camera" script and opens it. The four
  existing demo scripts and their counts are unchanged.

Checks: `scripts/build.sh` and `scripts/build-mac.sh` green; `SIM="Prompter Dev iPhone 2" scripts/test.sh` **625 tests** and
`scripts/test-mac.sh` **220 tests**, all passing. New: `CoreTests/MarkdownTests.swift` (both platforms: every inline marker,
unbalanced markers, escapes, the Foundation cross-check, blocks, notes/cues interplay, word counts = document words,
attributed-string colours per scheme, heading sizes, rule, the view-less layout, settings decoding, `.md` import),
`PrompterTests/MarkdownPrompterTests.swift` (voice word index ignores markers, live switch re-lays the engine, view-less layout =
text view for a Markdown script, tip, route), `PrompterMacTests/MarkdownMacTests.swift` (editor spans and live attributes,
stats, import, Presenter session switch). Maestro `library editor prompter` on "Prompter Dev iPhone 2": all pass (`editor` and
`journey` now expect the Markdown tip; `journey` not run here).
Screenshots: `docs/screenshots/m9-markdown-iphone.png` (mid-take, mirrored: amber heading, bullet, bold in amber),
`m9-markdown-mac.png` (Presenter view), `m9-markdown-mac-editor.png` (the Mac editor's live highlighting).

## Final state, Mac + sync (2026-10-08, 02:30)
The owner asked for: a native macOS app that runs on a MacBook with a teleprompter screen over HDMI, controlled from the MacBook, which
works hand in hand with the iPhone app so a script pasted on the Mac just shows up on the iPhone, tested end to end and polished.
All done. The orchestrator ran every check below on the final code (`main`, not pushed):
- `scripts/build.sh` (iPhone + watch) and `scripts/build-mac.sh`: green.
- **Tests:**
  - `SIM="Prompter Dev iPhone" scripts/test.sh`: **590 iOS tests pass**.
  - `scripts/test-mac.sh`: **186 Mac tests pass**. They include real TLS loopback sync tests: pairing, both directions, a forgotten
    iPhone, relay, reconnect.
- `scripts/sync-e2e.sh`: the real Mac app and the real iPhone app (on the "Prompter Dev iPhone" simulator) paired by themselves and
  synced, each change landing on the other device:
  - create Mac → iPhone 0.18 s
  - edit 0.33 s
  - delete 0.32 s
  - create iPhone → Mac 0.32 s
- **Maestro on the iPhone:** all 6 flows pass (library, editor, settings, prompter, voice, journey). The run waited for the other
  session's Maestro before each flow, so the two never overlapped.
- **Presenting on this Mac's second screen** (the 2560×1440 stand-in for the HDMI teleprompter) during the countdown and while playing:
  - the output is mirrored full screen with the reading line, dimming and the HUD;
  - the Presenter view on the main screen shows the wall clock, the screen name and resolution, time left, elapsed, progress, the full
    key legend and the transport buttons.

### Needs the owner (Mac)
- **Run it:** `xcodegen generate && scripts/build-mac.sh`, then open `build/DerivedData/Build/Products/Debug/Prompter.app`, or run the
  `PrompterMac` scheme in Xcode. No Apple ID is needed, since it's signed to run locally.
- **On your MacBook with the HDMI teleprompter screen**, judge:
  - smoothness at the real refresh rate (the displays here were asleep overnight, so a 60 Hz fallback drove the frames);
  - the hidden pointer over the output;
  - the notch inset in the Presenter view;
  - the Presenter menu (Start/Pause, Swap screens, Stop presenting ⌘.).

  If the text shows on the laptop instead, turn off Mirror Displays in System Settings → Displays.
- **Pair your iPhone** with the steps above under "Needs the owner: pair your real iPhone and Mac". Then confirm the Mac shows up on the
  iPhone through Bonjour discovery. That path couldn't be tested unattended, because macOS asks you to allow Local Network first.
- **Reinstall the iPhone app** with this build. It's needed for sync, and its sync protocol must match the Mac's.
- **Screenshots:** the Mac ones come from the app's own snapshot renderer, which flattens the Liquid Glass sidebar and toolbar. The
  real app looks better.

## Watch → iPhone → Mac bridge (M9): DONE (2026-10-08)
Plan: `docs/superpowers/plans/2026-10-08-m9-watch-mac-bridge.md`. The owner can control Prompter for Mac, presenting on the HDMI
teleprompter screen, from the Apple Watch. watchOS only talks to its paired iPhone (WatchConnectivity), so the iPhone relays
over the paired, encrypted sync connection from M7.

**Design:**
- **Protocol** (`Core/Sync/SyncMessages.swift`): three new sync messages.
  - `remoteSubscribe(Bool)`, iPhone → Mac, sent on every connection.
  - `remote(RemoteCommand, id:)`, iPhone → Mac.
  - `presenterStatus(PrompterStatus, replyTo:)`, Mac → iPhone. It answers each command (`replyTo` = its id) and is pushed
    whenever what the watch shows changes while presenting.

  An app that doesn't know a message already skips the frame, so the protocol version stays 1. Only a paired iPhone with a
  proven session may use these: the pairing connection is ignored (tested). Sync JSON now carries infinite numbers as strings.
  `PrompterStatus` gains `deviceName` (the Mac's name; the watch shows "On Studio Mac") and `note` (`macConnected`,
  `phoneInBackground`; an unknown one reads as `.unknown`). Both are left out of the JSON when nil, so older apps read statuses
  as before.
- **Mac** (`PrompterMac/App/MacRemoteControl.swift`):
  - Commands go through `PresenterSession` (start, pause, togglePlay, speedStep, backToTop, jumpBack). Resume only resumes a
    paused take. setSpeed is saved like a speed step, so speed persists, elapsed time is right and the canvases wake.
  - Not presenting: nothing is applied, and the answer says "not presenting". While presenting, the Mac's prompter counts as
    on screen.
  - It samples every 0.25 s while presenting. `SyncHost.publishPresenterStatus` sends only to iPhones that asked, and only
    when what the watch shows changed (`LivePushGate.showsDifferently`, moved to `Shared/`).
  - `PresenterLauncher.onPresentingChange` tells the iPhone at once when presenting starts, switches script or stops.
- **iPhone hub** (`PrompterRemoteHub`, `RemoteTarget`): who the watch controls, in order:
  1. A prompter open on the iPhone, exactly as before.
  2. If the app is in the background with a Mac paired: nothing, and the watch says "iPhone app in the background".
  3. A connected Mac that is presenting. Commands are forwarded; the watch's reply waits for the Mac's answer (at most 1.5 s).
     A status request is answered from the Mac's last push.
  4. Otherwise nothing ("Tap Prompt on your iPhone or Mac" while the Mac is connected).

  Relayed statuses are re-stamped with the phone's `SequenceClock`. They go out through the same live gate and application
  context (whose key now includes the device and the note). The WatchConnectivity reply is now a callback, so a forwarded
  command can answer later. Siri and Shortcuts intents still control the iPhone only.
- **iPhone UI:** **Remote for Mac** (`Prompter/Features/Remote/MacRemoteView.swift`) shows the Mac's status big and simple
  (title, state, time left, progress, speed), the same controls as the watch, the connection and watch lines, and "Keep this
  open; your Apple Watch controls the Mac through this iPhone." The screen stays awake while it is open. Entry points: an Apple
  Watch button in the library toolbar and a row in Settings → Sync with Mac, both only while a Mac is paired. Debug route:
  `-route macRemote`.
- **Watch:** an amber "On <Mac name>" line under the title. Every control and the Crown work as before. New demos:
  `-demoStatus macPlaying` and `phoneBackground`.

**End-to-end (the three real apps):** `scripts/watch-mac-e2e.sh`.
- The Mac app runs with `-demoData -syncPort 50124 -syncPairingCode 123456 -route prompter -script sample
  -presenterSnapshots … -quitAfter 62`. It presents on the second screen (2560×1440) and quits by itself.
- The iPhone app runs on "Prompter Dev iPhone" with `-demoData -syncHost 127.0.0.1:50124 -syncPairingCode 123456 -route
  macRemote` and pairs by itself.
- The watch app runs on its paired "Prompter Dev Watch" with `-remoteScript "start@8,pause@20,speedStep:5@24,resume@28,backToTop@40"`.

Both runs below presented full screen on the second display (made before the owner was at the Mac). The script now defaults to
`-singleScreen` (ordinary windows on the main screen, never full screen); `SECOND_SCREEN=1` brings back the full-screen run.
The `-singleScreen` default itself wasn't run end to end here, so nothing would open windows while the owner used the Mac.

Two runs, both complete:
- The Mac's log shows Ready → Starting 5…1 → Playing → Paused → 150 wpm → Playing → Ready (back to top) → not presenting.
- The watch showed each state, marked "On Studio Mac", and then "no prompter [macConnected]" after the Mac stopped.
- Mac Presenter snapshots show Playing, Paused and back at the top at 150 wpm.

Latency, measured from the logs (simulators log the host's clock):
- **Watch send → applied on the Mac:** run 2, after warm-up: **0.29–0.99 s** (start 0.38, pause 0.31, speed 0.95, resume
  0.30, back to top 0.99). Run 1: 1.50–1.61 s.
- **The bridge's own share is 1–15 ms:** the iPhone forwards on receipt and the Mac answers over loopback TLS within 2–15 ms.
  The rest is WatchConnectivity's watch → iPhone hop. A phone-only baseline (`scripts/watch-e2e.sh`) on the same simulator
  pair measured 1.41–1.48 s for that hop (0.42 s for the first command). In bridge run 1 the iPhone received every command
  at the same point of a second, so the simulator seems to deliver in once-a-second batches.
- **Mac state change → on the watch:** run 2, 0.05–1.32 s, once 2.26 s (playing). Run 1, 0.12–1.34 s. The simulator often
  stalls the phone's live messages ("unanswered after 3 s"); then the application context and the watch's own requests carry
  the status, as in M3.

Screenshots: `docs/screenshots/m9-watch-controls-mac.png` (watch: "On Studio Mac · Playing"),
`m9-iphone-remote-for-mac.png`.

Checks:
- `scripts/build.sh` and `scripts/build-mac.sh`: green.
- `SIM="Prompter Dev iPhone" scripts/test.sh`: **614 iOS tests**. `scripts/test-mac.sh`: **199 Mac tests**. All pass.
- New tests:
  - `PrompterTests/MacBridgeTests.swift`: routing decisions; hub forwarding (the reply waits for the Mac, in order, and comes
    even without an answer); status requests without a round trip; the iPhone's prompter wins; push gating; stop and
    disconnect; the background note; intents; status coding (fields left out, unknown note); watch texts.
  - `CoreTests/SyncProtocolTests.swift` (both platforms): round trips of the new messages, infinite seconds, unknown message
    types, a status from an older Mac.
  - `PrompterMacTests/MacRemoteTests.swift`: commands through `PresenterSession` (saved speed, elapsed time reset, countdown
    cancel, resume only resumes); refused when not presenting; a real TLS loopback (a command and its status, pushes on
    change only, no pushes without subscribing, the pairing connection can't send commands, disconnect).
- Maestro `settings` passes. It now also checks that Remote for Mac is hidden while unpaired.

**Known limits:**
- The bridge needs the iPhone app in the foreground (sync only runs there): Remote for Mac keeps the screen awake. If the
  iPhone locks or Prompter goes to the background, the watch says so, and it reconnects when Prompter comes back.
- A prompter open on the iPhone always takes the watch. There is no switch to pick the Mac while the iPhone also presents.
- The latency is mostly WatchConnectivity's. On real devices the watch → iPhone hop is usually well under the simulators'
  1–1.5 s, but that is not measured here.
- One Mac per iPhone, as for sync. Siri, Shortcuts and the Action button don't control the Mac.

### Needs the owner (bridge)
- With the real iPhone, watch and Mac: pair the iPhone and the Mac (above), present on the Mac, open Remote for Mac on the iPhone
  and use the watch. Check how quickly the Mac responds on the real devices and whether the iPhone keeps the link with its
  screen awake for a whole take. Update all three apps together.

