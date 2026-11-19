# Prompter on iPhone Duo (plan, 2026-11-19)

Goal: Prompter is polished and ready to use on iPhone Duo, Apple's foldable (5.4 inch cover screen, 7.6 inch open screen,
iOS 27.1). Work happens on branch `duo/optimize` (from `launch`). Nothing merges into `launch` or `main`, and nothing is
pushed without the owner's OK.

## The owner's decisions

- Prompter is used on the Duo in all three ways: open in the rig, folded in the rig, and handheld for writing scripts.
- Folding or unfolding in the middle of a take keeps it going: the line being read stays on the reading line, at the same pace.
- No new screen designs tonight. Where the open Duo needs a layout, reuse the one the app already has for iPad (or for a
  phone). Anything that needs a genuinely new design goes on the review page as a proposal, not into code.
- No Duo App Store screenshots in this round.

## What the Duo gives the app (measured on the simulator, `-duoProbe`)

| Posture | Window (pt) | Size classes (h/v) | The fold (`.division`) |
| --- | --- | --- | --- |
| Folded, tall | 466 x 678 | compact / regular | none |
| Folded, wide | 678 x 466 | compact / compact | none (upside down refused, as on any iPhone) |
| Open, wide | 951 x 669 | regular / regular | 40 pt strip at x 455, inactive while flat |
| Open, tall | 669 x 951 | regular / regular | 40 pt strip at y 455, inactive while flat |

- Idiom is always phone. Folding and unfolding resize the same scene live; no scene phase change was seen.
- The status bar and the cover's camera sit in `.occlusion` regions in a top corner (the bars stack on the trailing side).
- Hinge: closed, partially open, fully open, with an angle. Apple says not to drive layout from it.
- Size classes flip for a frame or two during the unfold animation.

Apple's guidance (notes in the run's working files) in short: lay out from the window, never from idiom, orientation or a
device check; scrolling text may cross the fold, controls should not cross an active fold; split views and system sheets
adjust to the fold on their own; the inner screen may not honour an app's orientation lock.

## Problems found before any change

1. The library open and tall (669 x 951) shows an empty "Pick a script" page; the script list hides behind the sidebar button.
2. The prompter sizes its text with an iPad check, so the open Duo (a 951 x 669 canvas) gets phone-sized defaults.
3. A fold mid-take re-lays out the text by line start, so the reading point slips back a little on every size change, and a
   fold passes through several sizes in a fraction of a second.
4. The landscape lock (`OrientationLock`) keeps one side across a fold, but the cover's landscape is the open screen's
   portrait for the same hold, and the lock restores an orientation captured on the other screen when the prompter closes.
5. On the open screen the countdown digit and the HUD's centre word sit on the fold; on the folded screen in landscape the
   close button or the HUD's corner label can meet the camera, depending on the real insets (to measure).
6. The Maestro flows pick iPad flows by simulator name and some tap points assume an iPhone 17 Pro, so the Duo has no
   working QA lane.

## Work streams (parallel, disjoint files, each on its own branch off `duo/optimize`)

### A. Prompter screen (branch `duo/prompter`)
Files: `Prompter/Features/Prompter/*`, `Prompter/App/OrientationLock.swift`, `Core/Engine/*`, `Core/Text/*`, matching tests.
1. Measure first, in one heavy slot: the prompter playing on the Duo through Closed, Open, Book and rotations, with the
   landscape lock on and off. Record whether the full-screen prompter survives the fold, the scene phase, the line at the
   reading line, whether the display link keeps firing on the other screen, what the orientation lock does on the open screen,
   the real safe area insets, and the settings sheet or popover.
2. Text size from the canvas, not the idiom: a large canvas (short side at least about 600 pt, or an iPad) gets the existing
   iPad scaling. iPhone, iPad and Mac results must not change.
3. Keep going across a fold: anchor the exact reading point (line start plus fraction, as a character position) across size
   changes so it does not drift, while a take plays or is paused. The scroll stays in WPM or finish-in as it is.
4. Orientation lock on the Duo: never turn the text 90 degrees to the presenter because of a fold, never restore an
   orientation captured on the other screen, and on the open screen accept the window as it is when the system ignores
   the lock.
5. Keep the countdown digit, the HUD's centre word and the close button clear of an active fold and of the camera,
   with the smallest move that works (Apple's rule). Nothing moves while the device is flat and the fold is inactive.
Acceptance: Swift Testing for every pure rule (style choice, anchor math, orientation rule, avoidance rect); iPhone and iPad
prompter screenshots unchanged against the baseline.

### B. Library, editor and the other screens (branch `duo/library`)
Files: `Prompter/Features/Library/*`, `Prompter/Features/Editor/*`, `Prompter/Features/Settings/*`,
`Prompter/Features/Remote/*`, matching tests.
1. Two columns only when the window really fits them; the open-and-tall Duo gets the phone layout with the list showing.
   iPad layouts must not change.
2. Folding or unfolding with a script open keeps it open (pushed editor on the phone layout, detail on the split layout),
   keeps the selection, the text and, where possible, the keyboard; no blank new script is lost.
3. Check every screen on the cover and open screens (bars that go vertical, sheets, alerts, Remote for Mac, settings) and fix
   what is clipped, hidden under the status bar or camera, or unreadable, using system components.
Acceptance: unit tests for the layout rule; Duo screenshots of every screen in every posture; iPhone and iPad library and
editor screenshots unchanged against the baseline.

### C. QA lane (branch `duo/qa`)
Files: `scripts/qa.sh`, `scripts/lib.sh`, `scripts/duo-posture.sh`, new `scripts/duo-shots.sh`, `qa/*.yaml`, `qa/README.md`.
1. `qa.sh` on the Duo: a posture setting (Closed, Open, Open tall) applied after boot, the right flow set per posture, and
   screenshots from the right display.
2. Flows that pass on the folded and open Duo without breaking the iPhone and iPad runs (no hard-coded iPhone tap points).
3. `scripts/duo-shots.sh`: one command that shoots every screen in every posture for review.

## Gates

- Baseline: the existing flows on Prompter Dev iPhone and iPad (and the Duo, to show the starting point) before any change.
- Every stream: builds, `scripts/test.sh` green, Mac tests green when `Core/` changed, its flows pass.
- After the merge: the whole flow set on iPhone, iPad and the Duo in every posture; iPhone and iPad screenshots compared with
  the baseline, every difference explained; a review of the whole diff (correctness, iPhone rig regression, Apple's rules).
- Screenshots in `docs/screenshots/duo/`, a `docs/PROGRESS.md` entry, commits on the branches.

## Out of scope here (for the owner)

- The script on the cover screen while the rear camera films (`CameraCaptureAccessory`, iOS 27.1). Apple's own example of it
  is a teleprompter, but it needs a camera capture session in the app and a real device to test.
- Duo App Store screenshots (required for submissions from April 2027).
- A cradle for the Duo in the rig.
