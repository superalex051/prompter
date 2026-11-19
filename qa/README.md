# Simulator QA

Maestro flows for the iPhone app. Each flow walks one screen or journey on a simulator, asserts what it should see and
leaves a screenshot of every screen it touches. Maestro cannot drive the watchOS simulator, so the watch is not covered
here (the watch app has its own `-remoteScript` debug option).

## The rule

**Every UI change ships with a pass of the flows that cover it, and someone opens the PNGs and looks.** A change nobody
looked at is not done. (Convention borrowed from another project.)

## Setup

Maestro 2.11.0 is already at `~/.maestro/bin/maestro` (it is not on `PATH`; `scripts/qa.sh` finds it, or set
`MAESTRO=/path/to/maestro`). It needs Java, which is installed. Nothing else to install.

## Running

Flows start with `appId: ${APP_ID}`; `scripts/qa.sh` reads the bundle ID from the built app and passes it with `-e APP_ID=...`. To run
one by hand, pass it yourself: `maestro test -e APP_ID=<bundle id> qa/library.yaml`. That is all an iPhone or iPad needs: the values
`scripts/qa.sh` adds for the iPhone Duo (`DUO`, `TAP_DONE`, `TAP_CLOSE`, `TURNS`, see "iPhone Duo") fall back to the iPhone 17 Pro's
when they are not passed.

```bash
scripts/qa.sh                      # build, boot the simulator, install, run every qa/*.yaml
scripts/qa.sh library settings     # just these (a name, name.yaml or qa/name.yaml)
SIM="Prompter Dev iPad" scripts/qa.sh # on an iPad simulator the default run is the ipad-*.yaml flows only
SIM="Prompter Dev iPad" scripts/qa.sh ipad-library ipad-landscape
```

With no flow names, an iPad simulator runs only `qa/ipad-*.yaml` and an iPhone runs everything else: the split view
exists only at regular width, so the two sets cannot pass on each other's device. The iPhone Duo is chosen by its window
instead (see "iPhone Duo"). Naming flows runs exactly those; the flows in `qa/promax/` only run by name.

| Variable | Default | Meaning |
| --- | --- | --- |
| `SIM` | `Prompter Dev iPhone` | Simulator name; found by exact name, the script stops if none or more than one has it |
| `CONFIG` | `Debug` | `Release` builds the shipping configuration and runs only `qa/release/` (a Release build ignores every launch flag) |
| `SIM_UDID` | | Use this simulator instead (needed when another job is using the one `SIM` finds) |
| `SKIP_BUILD` | `0` | `1` reuses the last `scripts/build.sh` output |
| `KEEP_SIM` | `0` | `1` leaves the simulator booted; by default one the script booted is shut down again |
| `MAESTRO` | `~/.maestro/bin/maestro` | Maestro binary |

The script exits non-zero if any flow fails; the other flows still run, and the last lines say which passed and failed.

One flow by hand, on a simulator that already has the app installed:

```bash
~/.maestro/bin/maestro --device <udid> test --test-output-dir /tmp/qa qa/library.yaml
```

## iPhone Duo

`SIM="Prompter Dev Duo" scripts/qa.sh` runs the flows on the foldable simulator. The Duo has no `simctl` verb for folding, so
`DUO_POSTURE=Closed|Open|OpenTall` presses Device Hub's posture buttons (`scripts/duo-posture.sh`) after boot and then
**measures** the window (the app's `-duoProbe` log), because "Rotate Right" is cumulative and Device Hub does not say which way
the simulator is turned. Without `DUO_POSTURE` the Duo is used in the posture it is in.

- **Which flows.** Chosen from the measured window, not the simulator's name: a window at least `DUO_SPLIT_MIN_WIDTH` points wide
  (default 700: the open Duo, 951) runs the `ipad-*` split-view flows; a narrower one (the cover, 466, and the open Duo turned
  tall, 669) runs the phone flows. `journey.yaml` is left out on the Duo: its settings-popover taps are iPhone 17 Pro points.
  The 700 is the app's own line (`LibraryLayout.minimumSplitWidth`): a phone window narrower than that shows the stack, so
  the open Duo held tall (669) gets the phone flows. Change the two together; `LibraryLayoutTests` pins the number.
- **Env the flows get.** Every flow gets `-e DUO=0|1`. The prompter flows get `TAP_DONE`, `TAP_CLOSE` and `TURNS`
  (portrait tap points worked out from the measured prompter window; off the Duo they are the iPhone 17 Pro numbers, and the
  drag in `prompter.yaml` is the iPhone's fixed points whenever `TURNS=1`). Do not put a default for these in a flow's
  `env:` header: a header value wins over `-e` (checked on Maestro 2.11.0), so the measured value would never arrive. The
  flows default inline instead (`${typeof TAP_DONE === "undefined" ? "336,759" : TAP_DONE}`), which `-e` still overrides.
  On the Duo, run flows through `scripts/qa.sh`.
- **Screenshots.** Maestro's `takeScreenshot` on the cover screen is the cover display (1398 x 2034 px, portrait, the picture
  in the prompter turned a quarter turn like on an iPhone). For shots of every screen in every posture from both displays use
  `scripts/duo-shots.sh` (see `scripts/README.md`).
- **Maestro sees only the cover.** On the open Duo, Maestro's hierarchy and screenshots are still the cover display (dark,
  1398 x 2034), so every flow fails at its first check. `qa.sh` therefore stops with exit 3 when it measures an open window
  (Open, OpenTall, or a Duo left open) and says to use `scripts/duo-shots.sh` and the `-duoProbe` log for the open screen.
  `DUO_OPEN_FLOWS=1` runs the flows anyway, for the day a Maestro release reaches the inner display. The `ipad-*` flows
  are written to pass on the open Duo held wide, but have not passed there for this reason.
- **Taps by id and the popover.** As on the iPhone, a `tapOn: {id: prompter.close}` lands in the wrong place in the prompter and the
  settings popover is not in Maestro's hierarchy, so Done and close are points.
- **Needs Device Hub.** `DUO_POSTURE` and `duo-shots.sh` need Device Hub open with a window and Accessibility permission. If it
  has no window (it can lose it), they stop with "Device Hub would not show the Duo"; open its window by hand.
- **Not while the Mac's screen is locked.** Accessibility sees no window on a locked screen, so the posture buttons cannot be
  pressed and `DUO_POSTURE` fails. The Duo simulator boots folded, so without `DUO_POSTURE` the flows run on the cover only
  (a 466 pt window: the phone flows). Open, open tall and Book can only be run with the Mac unlocked and awake
  (`caffeinate -d`). `DUO_POSTURE` also needs the Debug build, because it measures the window with `-duoProbe`.
- **Cover results today.** `editor`, `library`, `settings`, `prompter` and `voice` all pass on the cover (466 x 678).
  Where the cover differs, the flow has a `DUO=1` branch and the iPhone and iPad steps stay as they were: the back button is a
  bare chevron, so the Duo taps it by id (`BackButton`) instead of by the label ("Scripts", "Settings"); the editor's text fills
  the screen, so the sentence is typed on the empty line between the first two paragraphs instead of at the end; in Settings the
  Weight and Line spacing rows are checked before the scroll that centers the color tile (it pushes them off the top), the
  "Reset all settings" button is scrolled into view without centering (it sits at the end of the form), and the form scrolls
  back up to Done before it is tapped (the bar with Done is not in the hierarchy while the form is scrolled).
  `journey.yaml` stays off the Duo: its settings-popover taps are iPhone 17 Pro points.

## Where the screenshots land

`qa/output/<run>/<timestamp Maestro adds>/<flow name>/takeScreenshot/<name>.png`, git-ignored. `<flow name>` is the
`name:` at the top of the flow file (`Library`, `Editor`, `Settings`, `Prompter`, `Journey`), not the file name. A failing step also leaves a
`screenshot-...` PNG beside the flow folder. `scripts/qa.sh` prints every path at the end.

## The flows

| Flow | What it walks | Screenshots |
| --- | --- | --- |
| `library.yaml` | The four demo rows with their Prompt buttons and stats; the + menu; New script opens a blank editor and leaving it leaves no "Untitled" row, both with the back button and with a swipe back from the left edge; swipe-delete shows the "Deleted" banner and Undo brings the row back; the context menu's Duplicate adds "… copy" (then deleted again) | `library-top`, `library-add-menu`, `library-new-script-editor`, `library-after-new-script`, `library-deleted-banner`, `library-undo-restored`, `library-context-menu`, `library-duplicated` |
| `editor.yaml` | Open a script, the footer reads 108 words with the one-line markup tip under it, the Prompt button is enabled; type a sentence at the end and the footer reads 115 words (Done shows in the navigation bar next to Prompt); take it out again and Done goes; back in the library | `editor-open`, `editor-typed`, `editor-final`, `editor-back-in-library` |
| `settings.yaml` | The gear opens Settings; scroll mode to Speed and countdown to 10 s; each section scrolled into view (the Mirror footer says to set Rotation to 180° if the text is upside down; the Controls row opens the "How to use" guide and Back returns); "Restore sample script" is greyed out and the footer says "Already in your library."; Done; reopen and both changes are still there; Reset all settings puts the defaults back | `settings-defaults`, `settings-scrolling-countdown`, `settings-text`, `settings-mirror`, `settings-reading-line`, `settings-controls-row`, `settings-controls-guide`, `settings-sample-script`, `settings-reopened`, `settings-reset-section`, `settings-reset-confirm`, `settings-after-reset` |
| `prompter.yaml` | `-route prompter`: the HUD says "Ready, 1:11 left, 140 wpm"; tap starts the 5 s countdown ("Starting in …"), then "Playing" and the close button is gone; tap pauses and the close button is back; a short drag scrubs (the time left changes, still paused); long-press opens the settings popover (not visible to Maestro here, driven by points like the journey), whose Done closes it; the close button returns to the library. Taps use hand-converted portrait points, see "Landscape" below | `prompter-ready`, `prompter-countdown`, `prompter-playing`, `prompter-paused`, `prompter-dragged`, `prompter-settings`, `prompter-closed-library` |
| `voice.yaml` | Voice mode with the microphone and speech recognition **denied** (Maestro `permissions`): picking Voice in Settings shows "Voice needs microphone access. Scrolling at your set pace instead.", then (as separate paragraphs) "Turn on Microphone…" and the explainer, with an Open Settings button; the prompter in voice mode says the first sentence in the HUD ("… Ready, 1:11 left, 140 wpm"), plays at 140 wpm and hides the notice while moving. Then **allowed**: the footer explains on-device listening, and the prompter is "Ready, 1:11 left, Voice". It never starts a voice take with the microphone allowed (that would open the Mac's microphone; the simulator can't recognise speech anyway) | `voice-settings-denied`, `voice-prompter-denied`, `voice-prompter-denied-playing`, `voice-settings`, `voice-prompter-ready` |
| `journey.yaml` | **iPhone, in one cold run: the shoot day.** Library, + > New script, a title ("Shoot day test") and a two-paragraph body with a `// note` and a `[pause 2]` line (footer "58 words · 0:27 at 140 wpm": the note and the cue are not words, the 2 s hold is in the time; a blank script has Prompt disabled and shows the tip, which is gone once the markup is typed); back, the row says "58 words · 0:27"; Prompt, ready (the HUD says 0:30 left: the note and cue lines scroll past in time of their own), countdown, playing, tap to pause; long-press settings, Speed mode and a 3 s countdown (by hand-converted points, the popover is invisible to Maestro here, see "Landscape"), Done (the HUD already says "Speed 3.0"); tap to resume, wait for the HUD to say "Pause 2" at the `[pause 2]` cue, pause; close (portrait library, whole screen visible); the app Settings show Speed and 3 s (then put back to WPM and 5 s); swipe-delete the script, Undo (same script back), delete again, wait the banner out. The library ends as it began | `journey-01-library`, `journey-02-add-menu`, `journey-03-editor-blank`, `journey-04-editor-typed`, `journey-05-library-new-row`, `journey-06-prompter-ready`, `journey-07-countdown`, `journey-08-playing`, `journey-09-paused`, `journey-10-settings-open`, `journey-11-settings-speed-3s`, `journey-12-playing-speed`, `journey-13-hold`, `journey-14-paused-after-hold`, `journey-15-library-after-close`, `journey-16-settings-kept`, `journey-17-deleted-banner`, `journey-18-undo-restored`, `journey-19-library-final` |
| `ipad-library.yaml` | **iPad, and the open iPhone Duo held wide** (through `scripts/qa.sh`, which sets `DUO=1` so the flow leaves the posture alone). The split view at regular width (portrait): the empty detail ("Pick a script or make a new one"); a tap on a row opens its editor next to the list, another row replaces it (the footer's word count proves the editor really switched); swipe-delete of the open script clears the detail, and Undo brings the row back and opens it again; + > New script opens a blank editor beside the list and opening another script drops the blank one; renaming the open script from the sidebar (context menu > Rename) shows the new title in the editor's title field; Prompt opens the prompter and its close button returns to the split view with the list intact; a relaunch with `-route editor` opens the newest script in the detail | `ipad-library-empty-detail`, `ipad-library-selected`, `ipad-library-deleted-open-script`, `ipad-library-new-script`, `ipad-library-prompter`, `ipad-library-route-editor`, `ipad-library-renamed-open-script` |
| `ipad-landscape.yaml` | **iPad, and the open iPhone Duo held wide** (`DUO=1`: the flow does not turn the simulator). Looks only (no taps), in landscape: the split view with a script open, the empty detail, the prompter playing, the prompter's settings sheet. Turns the simulator back to portrait at the end | `ipad-landscape-library`, `ipad-landscape-empty-detail`, `ipad-landscape-prompter`, `ipad-landscape-prompter-settings` |
| `promax/layout-switch.yaml` | **iPhone Pro Max, run by name** (`SIM_UDID=<Pro Max> scripts/qa.sh promax/layout-switch`). The library's switch between the stack (portrait) and the split view (landscape, regular width) with a script open, the same switch the iPhone Duo makes when it folds or unfolds: a blank new script survives both ways and keeps the keyboard; the list is back beside the editor the second time; the rename alert and the delete banner with its Undo stay across a switch; typing in the middle of a script goes on where it stopped after each switch | `switch-1-split-new-script`, `switch-2-stack-typed`, `switch-3-split-again`, `switch-4-rename-kept`, `switch-5-banner-kept`, `switch-6-stack-cursor-kept`, `switch-7-split-cursor-kept` |

Voice mode actually following a read-through can't be driven from Maestro: see `scripts/voice-check.sh` (the recognition, on
the Mac) and `scripts/voice-demo.sh` (the app replaying those results on the simulator, with timed screenshots).

The `prompter-*` shots (except `prompter-closed-library`) and `journey-06` to `journey-14` come out turned a quarter turn, see
"Landscape" below. To read one, `sips -r 270 prompter-ready.png --out /tmp/prompter-ready-upright.png`, or, because those
PNGs carry an EXIF orientation tag (`LeftBottom`), `magick prompter-ready.png -auto-orient prompter-ready-upright.png`.

Shared sub-flows go in `qa/helpers/` (none yet). `scripts/qa.sh` only runs `qa/*.yaml`, so anything in `helpers/` is never run on its own.

## Conventions

- One flow per screen or journey. Every flow starts with `launchApp` (with `clearState: true` and demo data), takes a
  screenshot of every screen it touches, and ends with the app as it began.
- Comments explain why a step is there, not what it does.
- Maestro matches a selector against the **whole** string, as a case-insensitive regex. A row's title is its own element
  (`Client testimonial ask`) and its first line and stats are others, so a tap on part of a string needs a `.*`.
- Almost every control has a stable label, so no `accessibilityIdentifier`s are needed. The prompter has four because its
  elements have no useful text of their own: `prompter.canvas` (the text), `prompter.close`, `prompter.hud` (one element, label
  "Paused, 1:10 left, 140 wpm") and `prompter.countdown` (the big digit, label "Starting in 5"). Add one only where a label
  cannot be matched, and name it like `library.row.prompt`.
- Nothing taps **Paste as new script** (iOS asks "Allow Paste") or **Import file…** (opens the Files picker); those are
  system UI. No other system prompt appeared in any run. Microphone and speech-recognition prompts are answered by
  `launchApp: permissions:` (Maestro sets them with its bundled applesimutils), so they never show.

## Gotchas

**Landscape (the prompter).** The prompter locks the app to landscape, but the simulator itself stays portrait, and that
confuses Maestro in four ways. Checked on the iPhone 17 Pro simulator (402 x 874 pt):

- *Bounds are landscape, taps are portrait.* Elements report bounds on the 874 x 402 screen (the close button is
  `[74,12][118,56]`), but a tap goes to a point on the 402 x 874 screen. `tapOn: {id: prompter.close}` therefore taps the
  centre of a rectangle that is off the right edge of the real screen, and `tapOn: 'Done'` in the settings popover misses the
  same way. Tap landscape point (x, y) as `point: "<402 - y>, <x>"`: the close button's centre (96, 34) is `'368,96'`, the
  popover's Done at (759, 66) is `'336,759'`. Swipes follow the same rule: a drag up the landscape screen from y=350 to y=100
  is `start: '52,437'`, `end: '302,437'`. The exact middle of the screen is the same point either way, so `50%,50%` is fine for
  tapping and long-pressing the text. Selecting by text or id for *asserting* works as usual; only tapping is off.
- *Screenshots are portrait frames with the landscape picture turned a quarter turn* (clockwise). `sips -r 270` makes them
  upright. The library shot after closing the prompter is an ordinary portrait one.
- *After the app turns back to portrait, Maestro still clips to the landscape screen height:* nothing below y=402 is reported
  as visible for the rest of that flow (not even after 30 s, while a fresh `maestro hierarchy` shows everything). After closing
  the prompter `prompter.yaml` asserts only the first two rows; the screenshot shows all four. Anything that needs the whole
  library again belongs in a new flow (a new `launchApp`).
- *The close button leaves the view tree while it is hidden* (it used to fade to opacity 0 with `accessibilityHidden`, and
  Maestro still found it). While the text moves `prompter.close` is gone, so `prompter.yaml` asserts that it is not visible.
- *What Maestro can see depends on the orientation the app is in when a run first needs the screen size* (it keeps that
  size for the rest of the run). Checked with the same settings popover, same steps:
  - A run that **starts in landscape** (`prompter.yaml`: `-route prompter`) thinks the screen is 874 x 402. The popover is
    visible by text (`Settings`, `Countdown`, selected segments), and after closing the prompter nothing below y=402 is.
  - A run that **starts in the portrait library and opens the prompter** (`journey.yaml`) thinks it is 402 x 874. The library
    and the Undo banner stay fully visible after the prompter closes, but everything that lies wholly right of landscape
    x=402 is dropped from the hierarchy: the settings popover (x 412..812) is not there at all, so `assertVisible: 'Settings'`
    times out even though the screenshot shows it. While it is open the HUD is gone from the hierarchy too, so
    `notVisible: {id: prompter.hud}` is the "popover is up" signal. Drive it by points and check it by its effects (the HUD's
    "Speed 3.0", and the library's Settings sheet afterwards).
  - Points do not carry between the two kinds of run. In the portrait-start run a slow drag (800 ms) at `102,600` to
    `252,600` scrolls the popover's form; in a run that started in landscape the same drag missed the popover, dismissed
    it and scrubbed the text. Taps by point (`232,486` Speed, `336,759` Done) worked in both.

A drag is a `swipe` of 200 ms. The prompter's long-press (0.5 s hold) opens the settings, and the build notes warn that Maestro
holds still briefly before it starts moving; swipes of 200, 1000 and 2000 ms all scrubbed without opening the popover here, so
200 ms is a choice for speed, not a requirement. To check that the HUD changed, copy its label and compare: `copyTextFrom: {id: prompter.hud}`, `evalScript: ${output.before = maestro.copiedText}`, drag, copy again,
`assertTrue: ${maestro.copiedText != output.before}`.

The prompter always starts from the default 5 s countdown: `-demoData` switches to a throwaway settings suite that is emptied
at every demo launch. Steps in Maestro take about a second each, so by the time a flow looks at the HUD after "Playing" the
time left has moved on by several seconds; assert the state word, not the exact time (only "Ready" has a fixed `1:11`).

**iPad.** Checked on the iPad Pro 13-inch (M5) simulator, iOS 27 (1032 x 1376 pt).

- *The iPad window does not rotate by itself.* The prompter's "Landscape only" lock is ignored on iPad (iPadOS windowing), so
  the prompter stays in whatever orientation the simulator has. `- setOrientation: LANDSCAPE_LEFT` (and `PORTRAIT`) does turn
  the simulator, and **the simulator keeps that orientation after the flow ends**, so every iPad flow sets the orientation it
  needs and `ipad-landscape` puts it back to portrait. A flow that fails halfway through landscape leaves the simulator turned:
  run any flow that starts with `setOrientation: PORTRAIT` (or `ipad-library`) before the next one.
- *Landscape shots are portrait frames with the picture turned a quarter turn*, as on the iPhone: `sips -r 270`. Swipes and
  taps are in portrait points, so flows that interact stay in portrait and the landscape flow only looks.
- *The prompter's settings sheet is not in Maestro's hierarchy* (`maestro hierarchy` lists only `prompter.canvas`,
  `prompter.close` and `prompter.hud` while it is open), so it can't be asserted or tapped by text. The screenshot is the check.
- *The status bar shows the window title* ("9:41 AM Wed Oct 7 Prompter") and a resize grip sits in the bottom-right corner: the
  simulator runs the app as a window. Both are in every iPad shot.

**Launch arguments.** Maestro's `launchApp: arguments:` reaches the app as `ProcessInfo.processInfo.arguments`, flattened
to `<key> <value>` pairs, in the order written. Maestro puts a `-` in front of every key that has none, **except when the
value is a YAML boolean**. Checked by launching with each form and reading the process's command line:

| In the flow | What the app sees |
| --- | --- |
| `route: editor` | `-route editor` |
| `demoData: true` | `demoData true` (no dash: the key is left alone for a boolean) |
| `demoData: "true"` | `-demoData true` |
| `-demoData: true` | `-demoData true` |
| `-demoData: YES` | `-demoData true` (YAML 1.1 reads `YES`, `yes`, `on` as booleans too) |

`LaunchOptions` accepts both `-demoData` and a bare `demoData` (and the same for `route`), so none of these can silently
launch the app without demo data. The flows still write `-demoData: "true"` and `-route: library` with the dash and the
quotes, so they read like the shell form (`xcrun simctl launch … -demoData true -route library`).

**`clearState: true`** deletes the app's data, including `UserDefaults`, so Settings start from the defaults. Checked:
a changed countdown survives a plain relaunch and is gone after a `clearState` launch. `-demoData` only isolates the
script library (a throwaway folder in the temp directory); settings are real `UserDefaults`, which is why `settings.yaml`
resets them before it ends.

**The Undo banner is up for 6 seconds** (not while VoiceOver is on). `library.yaml` takes its screenshot and taps Undo
straight after the swipe; do not put slow steps in between.

**The editor body is one accessibility element.** Its value is the whole script, but iOS hands Maestro only about the
first 400 characters, so a flow cannot assert on the end of a long script. `editor.yaml` checks the footer's word count
and the screenshot shows where the sentence landed. There is no End key on iOS either: the flow taps the empty space below
the last line (`point: 50%,88%`), which puts the cursor at the end. That only works for a script that fits on one screen,
which is why the flow uses "Client testimonial ask".

**The back button is labelled with the screen it goes back to**, so it is `tapOn: 'Scripts'`. (The identifier is `BackButton`.)

**Segmented controls** expose `selected`: `assertVisible: {text: '10 s', selected: true}`. After switching to Speed there
are two elements called "Speed" (the segment and the slider), so assert with `selected: true`.

**A confirmation dialog hides the form behind it** from the accessibility tree, so with "Reset all settings?" open there
is only one "Reset all settings" to tap: the dialog's button.

**`scrollUntilVisible` with `centerElement: true` only scrolls when the element is not fully on screen.** To get a
section's shot, aim at something that starts off screen (the color tile is cut off by the sheet's bottom edge).
The form is short, so the last three sections overlap in their shots.

**The status bar** is set to 9:41, full bars and a charged battery for the run (and cleared at the end), so shots from
different runs line up. The accessibility tree still reports the real clock.

**Something else on the Mac can shut the simulator down mid-run** (it happened once, between steps of a probe flow:
`Unable to lookup in current state: Shutting Down`). `scripts/qa.sh` boots the simulator again before every flow, but a flow
already running dies. Re-run it.

**Pick the simulator.** Another job may be using `Prompter Dev iPhone`; pass `SIM_UDID=<udid>` to use a different one. Keep one
simulator booted at a time (see `AGENTS.md`).
