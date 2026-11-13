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
