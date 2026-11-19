# Scripts

Build, test and release helpers. Run them from the repo root.

## Heavy tasks

Xcode builds, simulators, Maestro runs, e2e scripts and site builds take a lot of memory. Only one may run at a
time across every worktree and agent. Wrap each one in `scripts/heavy.sh`:

```bash
scripts/heavy.sh --task REL-04 -- scripts/test.sh
scripts/heavy.sh --task WEB-3 --timeout 1800 -- npm run check
```

What it does:

- Takes a lock shared by all worktrees (`.inbox/heavy.lock` in the main checkout) and waits, with a log line
  every minute, until it is free. A lock whose holder is gone, or older than 3 hours, is cleared.
- Waits until compressed memory is under 14 GB and swap has stopped growing (two readings 20 seconds apart).
- Runs your command in its own process group, then shuts down by UDID only simulators named "Prompter ..." that
  booted during the slot. Other simulators are never touched, and nothing is shut down if the simulator list fails.
- Adds one line to `.inbox/launch-plan/heavy-log.md` (task, command, start, end, exit code, compressed GB).
- Releases the lock when the command ends, fails, or gets INT, TERM or HUP. On a signal it stops the whole process
  tree first (TERM, then KILL after 10 s). A call made from inside a slot runs directly instead of deadlocking. The exit code is the command's;
  124 means `--timeout` ran out while waiting.

For long waits, run it in the background. Settings (`HEAVY_LOCK`, `HEAVY_MAX_COMPRESSED_GB`, and so on) are
listed at the top of the script. `scripts/heavy.sh --self-test` checks the lock, stale-lock clearing and the
memory gate, signal handling and simulator cleanup (with a fake `xcrun`) in about 40 seconds without touching the real lock or simulators.

## iPhone Duo (the foldable)

The Duo simulator ("Prompter Dev Duo") has a cover screen (466x678 pt) and an open screen (951x669 pt), and `xcrun simctl`
has no verb to fold it. These scripts work around that:

- `scripts/duo-posture.sh select|state|Closed|Book|Open|"Rotate Right"` presses Device Hub's own posture buttons through
  the macOS Accessibility API. It refuses to press while Device Hub shows another device, so run `select` first. "Rotate
  Right" is cumulative and Device Hub does not say which way the simulator is turned, so the helpers below measure the
  window instead of trusting a count.
- `lib.sh` has the helpers `sim_is_duo`, `duo_probe` (launches the app with `-duoProbe` and returns the window it logged:
  width, height, horizontal size class, safe area left and top) and `duo_apply_posture` (presses buttons until the
  measured window matches Closed 466x678, ClosedLandscape 678x466, Open 951x669, OpenTall 669x951 or Book, which is the
  Book button with Open's wide window).
- `scripts/qa.sh` takes `DUO_POSTURE=Closed|Open|OpenTall` and picks the flows from the measured window (see `qa/README.md`).
- `scripts/duo-shots.sh <folder>` is the contact-sheet run: one build, then every posture (closed, closed-landscape, open,
  book, open-tall) times every route (library, editor, prompter playing, prompterSettings, settings, syncSettings,
  macRemote), each saved from both displays as `<posture>-<route>-<display>.png` (display is `cover` or `open`), plus a
  `manifest.txt` with the window the app reported for each shot.

```bash
scripts/heavy.sh --task DUO-SHOTS -- scripts/duo-shots.sh .inbox/duo/shots/run1
POSTURES="closed open" ROUTES="library prompter" SKIP_BUILD=1 scripts/heavy.sh --task DUO-SHOTS -- scripts/duo-shots.sh /tmp/x
```

- `-duoProbe` is a launch option of Debug builds (a Release build ignores it). The app then logs its window every time it
  changes (size, safe area, size classes, scene orientation, the fold, regions covering the screen, the hinge, scene phase, the
  prompter's relayouts and orientation lock) to `Documents/duo-probe.log` and the console. `lib.sh` and `duo-shots.sh` read it to
  know which posture they are really in. Find the log with `xcrun simctl get_app_container <udid> <bundle id> data`.

Both need Device Hub running and Accessibility permission for the terminal. Never quit Device Hub; other sessions share it.

**Limit: they cannot run while the Mac's screen is locked.** Accessibility sees no window on a locked screen, so
`scripts/duo-posture.sh` fails and so do `DUO_POSTURE` and the posture steps of `duo-shots.sh` (the Duo simulator boots folded,
on the cover screen). Without a posture the cover can still be tested. Do not work around the lock screen: unlock the Mac by
hand and keep it awake for the run (`caffeinate -d`).
