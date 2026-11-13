#!/bin/bash
# One-at-a-time lock for heavy work (Xcode builds, simulators, Maestro, e2e, site builds).
#
#   scripts/heavy.sh --task <ID> [--timeout <sec>] -- <command...>
#   scripts/heavy.sh --self-test
#
# Waits for the lock, waits for the Mac to have memory headroom, runs the command,
# shuts down only the simulators the command booted, writes one line to the run log,
# and releases the lock (also on failure, INT and TERM). Exit code is the command's;
# 124 means the wait timed out before the slot started.
#
# Settings (environment):
#   HEAVY_LOCK                  lock directory (default: <main checkout>/.inbox/heavy.lock)
#   HEAVY_LOG                   run log (default: <main checkout>/.inbox/launch-plan/heavy-log.md)
#   HEAVY_MAX_AGE_SEC           a lock older than this is stale (default 10800 = 3 h)
#   HEAVY_MAX_COMPRESSED_GB     compressed memory must be under this (default 14)
#   HEAVY_POLL_SEC              seconds between lock polls (default 5)
#   HEAVY_SWAP_GAP_SEC          seconds between the two swap readings (default 20)
#   HEAVY_FAKE_COMPRESSED_GB    test only: use this reading instead of vm_stat
#   HEAVY_FAKE_COMPRESSED_GB_FILE  test only: read the fake value from this file each time
#   HEAVY_FAKE_SWAP_MB          test only: use this swap-used reading instead of sysctl
#   HEAVY_NO_SIM=1              skip the simulator cleanup (self-test)
#   HEAVY_SIM_PREFIX            only simulators whose name starts with this are shut down
#                               after a slot (default "Prompter "); others are never touched
#   HEAVY_KILL_GRACE_SEC        after TERM, wait this long before KILL (default 10)

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SELF")"

MAX_AGE="${HEAVY_MAX_AGE_SEC:-10800}"
MAX_GB="${HEAVY_MAX_COMPRESSED_GB:-14}"
POLL="${HEAVY_POLL_SEC:-5}"
SWAP_GAP="${HEAVY_SWAP_GAP_SEC:-20}"
SIM_PREFIX="${HEAVY_SIM_PREFIX:-Prompter }"
GRACE="${HEAVY_KILL_GRACE_SEC:-10}"

say() { echo "[heavy $(date '+%H:%M:%S')] $*" >&2; }
now() { date +%s; }

# Sleep that a trapped signal interrupts at once.
nap() {
  local sp
  sleep "$1" &
  sp=$!
  wait "$sp" 2>/dev/null
  kill "$sp" 2>/dev/null
  wait "$sp" 2>/dev/null
  return 0
}

resolve_paths() {
  local common root
  common="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [ -z "$common" ]; then
    common="$(cd "$SCRIPT_DIR" && cd "$(git rev-parse --git-common-dir)" && pwd)"
  fi
  root="$(dirname "$common")"
  LOCK="${HEAVY_LOCK:-$root/.inbox/heavy.lock}"
  LOG="${HEAVY_LOG:-$root/.inbox/launch-plan/heavy-log.md}"
  mkdir -p "$(dirname "$LOCK")" "$(dirname "$LOG")"
}

# ---------- memory readings ----------

compressed_gb() {
  if [ -n "${HEAVY_FAKE_COMPRESSED_GB_FILE:-}" ] && [ -r "$HEAVY_FAKE_COMPRESSED_GB_FILE" ]; then
    cat "$HEAVY_FAKE_COMPRESSED_GB_FILE"; return
  fi
  if [ -n "${HEAVY_FAKE_COMPRESSED_GB:-}" ]; then echo "$HEAVY_FAKE_COMPRESSED_GB"; return; fi
  vm_stat 2>/dev/null | awk '
    /page size of/ { for (i = 1; i <= NF; i++) if ($i == "of") ps = $(i + 1) }
    /Pages occupied by compressor/ { gsub(/\./, "", $NF); pages = $NF }
    END { if (ps == 0) ps = 16384; printf "%.2f\n", pages * ps / 1073741824 }'
}

swap_used_mb() {
  if [ -n "${HEAVY_FAKE_SWAP_MB:-}" ]; then echo "$HEAVY_FAKE_SWAP_MB"; return; fi
  sysctl -n vm.swapusage 2>/dev/null | awk '{
    for (i = 1; i <= NF; i++) if ($i == "used") { v = $(i + 2) }
    n = v + 0; u = substr(v, length(v), 1)
    if (u == "G") n *= 1024; else if (u == "K") n /= 1024
    printf "%.2f\n", n }'
}

gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 > b + 0) }'; }

# ---------- lock ----------

timed_out() { [ "$DEADLINE" -gt 0 ] && [ "$(now)" -ge "$DEADLINE" ]; }

write_info() {
  echo "$$" > "$LOCK/pid"
  echo "$TASK" > "$LOCK/task"
  echo "$*" > "$LOCK/command"
  date '+%Y-%m-%d %H:%M:%S' > "$LOCK/start"
  now > "$LOCK/start_epoch"
}

clear_if_stale() {
  # return 0: lock is gone (or we cleared it), retry now. return 1: lock is live.
  [ -d "$LOCK" ] || return 0
  local pid start reason="" age mtime grave gpid gtask
  pid="$(cat "$LOCK/pid" 2>/dev/null)"
  start="$(cat "$LOCK/start_epoch" 2>/dev/null)"
  if [ -z "$pid" ]; then
    mtime="$(stat -f %m "$LOCK" 2>/dev/null || now)"
    age=$(( $(now) - mtime ))
    [ "$age" -gt 30 ] && reason="no holder info for ${age}s"
  elif ! kill -0 "$pid" 2>/dev/null; then
    reason="holder pid $pid is dead"
  elif [ -n "$start" ] && [ $(( $(now) - start )) -gt "$MAX_AGE" ]; then
    reason="holder pid $pid has held it longer than ${MAX_AGE}s"
  fi
  [ -n "$reason" ] || return 1
  grave="$LOCK.stale.$$"
  mv "$LOCK" "$grave" 2>/dev/null || return 0     # someone else cleared it first
  gpid="$(cat "$grave/pid" 2>/dev/null)"
  if [ "$gpid" != "$pid" ]; then                  # we grabbed a different, fresh lock: put it back
    if mkdir "$LOCK" 2>/dev/null; then            # mkdir fails if a third process took the slot meanwhile
      cp -R "$grave"/. "$LOCK"/ 2>/dev/null
    else
      say "lock conflict while clearing a stale lock; leaving the new holder in place"
    fi
    rm -rf "$grave"
    return 1
  fi
  gtask="$(cat "$grave/task" 2>/dev/null)"
  rm -rf "$grave"
  say "cleared stale lock (task $gtask): $reason"
  return 0
}

acquire_lock() {
  local last_log; last_log="$(now)"
  while :; do
    [ -n "$SIGNALLED" ] && return 2
    if mkdir "$LOCK" 2>/dev/null; then
      HAVE_LOCK=1
      write_info "$@"
      if [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ]; then return 0; fi
      HAVE_LOCK=0                                 # someone else's lock dir replaced ours; wait again
      continue
    fi
    if clear_if_stale; then continue; fi
    if timed_out; then return 1; fi
    if [ $(( $(now) - last_log )) -ge 60 ]; then
      say "task $TASK waiting for lock held by task '$(cat "$LOCK/task" 2>/dev/null)' (pid $(cat "$LOCK/pid" 2>/dev/null), since $(cat "$LOCK/start" 2>/dev/null))"
      last_log="$(now)"
    fi
    nap "$POLL"
  done
}

release_lock() {
  if [ "${HAVE_LOCK:-0}" = 1 ] && [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ]; then
    rm -rf "$LOCK"
  fi
  HAVE_LOCK=0
}

memory_gate() {
  local c s1 s2 last_log; last_log="$(now)"
  while :; do
    [ -n "$SIGNALLED" ] && return 2
    c="$(compressed_gb)"
    if gt "$c" "$MAX_GB"; then
      if [ $(( $(now) - last_log )) -ge 60 ]; then say "waiting: compressed memory ${c} GB is over ${MAX_GB} GB"; last_log="$(now)"; fi
      timed_out && return 1
      nap "$POLL"; continue
    fi
    s1="$(swap_used_mb)"
    nap "$SWAP_GAP"
    [ -n "$SIGNALLED" ] && return 2
    s2="$(swap_used_mb)"
    if gt "$s2" "$s1"; then
      say "waiting: swap grew from ${s1} MB to ${s2} MB in ${SWAP_GAP}s"
      timed_out && return 1
      nap "$POLL"; continue
    fi
    COMPRESSED_AT_START="$c"
    return 0
  done
}

# ---------- simulators ----------

# Prints "<udid><TAB><name>" for every booted simulator. Returns 1 if the listing fails,
# so the caller can tell "nothing booted" from "could not look".
booted_sims() {
  local out
  out="$(xcrun simctl list devices booted 2>/dev/null)" || return 1
  printf '%s\n' "$out" | sed -nE 's/^[[:space:]]+(.*) \(([0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12})\) \(Booted\)[[:space:]]*$/\2\t\1/p'
  return 0
}

snapshot_sims() {
  SIMS_BEFORE_OK=0; SIMS_BEFORE=""
  [ "${HEAVY_NO_SIM:-0}" = 1 ] && return
  if SIMS_BEFORE="$(booted_sims)"; then SIMS_BEFORE_OK=1; fi
}

# Shuts down only simulators that (a) were not booted before the slot and (b) have a
# name starting with the project prefix. Anything else is left alone.
shutdown_new_sims() {
  [ "${HEAVY_NO_SIM:-0}" = 1 ] && return
  local after u name
  if [ "$SIMS_BEFORE_OK" != 1 ]; then
    say "simulator list was unavailable before the slot; not shutting any simulator down"; return
  fi
  if ! after="$(booted_sims)"; then
    say "simulator list was unavailable after the slot; not shutting any simulator down"; return
  fi
  while IFS="$(printf '\t')" read -r u name; do
    [ -n "$u" ] || continue
    if printf '%s\n' "$SIMS_BEFORE" | cut -f1 | grep -qx "$u"; then continue; fi
    case "$name" in
      "$SIM_PREFIX"*)
        say "shutting down simulator '$name' $u (booted during this slot)"
        xcrun simctl shutdown "$u" >/dev/null 2>&1 ;;
      *) say "leaving simulator '$name' $u alone (booted during this slot, not a ${SIM_PREFIX}simulator)" ;;
    esac
  done <<EOF
$after
EOF
}

# ---------- run ----------

write_log() {
  local code="$1" cmd
  cmd="$(printf '%s' "$CMD_TEXT" | tr '|\n' '/ ')"
  [ -f "$LOG" ] || {
    echo "| task | command | start | end | exit | compressed GB at start |" > "$LOG"
    echo "|---|---|---|---|---|---|" >> "$LOG"
  }
  echo "| $TASK | \`$cmd\` | $START_H | $(date '+%Y-%m-%d %H:%M:%S') | $code | ${COMPRESSED_AT_START:-n/a} |" >> "$LOG"
}

on_signal() { say "caught $1"; SIGNALLED="$2"; }

# All descendants of a pid, one per line.
tree_pids() {
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; tree_pids "$c"; done
}

# Stop the command and everything it started: TERM, a grace period, then KILL.
# With GROUP=1 the command has its own process group and one signal reaches all of it,
# including processes that were handed to init. With GROUP=0 (run from a terminal, where a
# separate group would be stopped by SIGTTIN) the tree is walked with pgrep -P instead,
# re-scanned each round so children started during shutdown are caught too.
stop_child() {
  [ -n "${CHILD:-}" ] || return
  local i=0 seen="$CHILD" p alive
  if [ "$GROUP" = 1 ]; then
    kill -TERM -- "-$CHILD" 2>/dev/null
    while kill -0 -- "-$CHILD" 2>/dev/null && [ "$i" -lt "$GRACE" ]; do nap 1; i=$((i + 1)); done
    if kill -0 -- "-$CHILD" 2>/dev/null; then
      say "command still running after ${GRACE}s; sending KILL"
      kill -KILL -- "-$CHILD" 2>/dev/null
      i=0
      while kill -0 -- "-$CHILD" 2>/dev/null && [ "$i" -lt 5 ]; do nap 1; i=$((i + 1)); done
    fi
    return
  fi
  while :; do
    seen="$seen $(tree_pids "$CHILD" | tr '\n' ' ')"
    alive=""
    for p in $seen; do kill -0 "$p" 2>/dev/null && alive="$alive $p"; done
    [ -n "$alive" ] || return
    if [ "$i" -lt "$GRACE" ]; then
      if [ "$i" = 0 ] || [ $((i % 3)) = 0 ]; then kill -TERM $alive 2>/dev/null; fi
    else
      [ "$i" = "$GRACE" ] && say "command still running after ${GRACE}s; sending KILL"
      kill -KILL $alive 2>/dev/null
      [ "$i" -gt $((GRACE + 5)) ] && return
    fi
    nap 1; i=$((i + 1))
  done
}

usage() { echo "usage: heavy.sh --task <ID> [--timeout <sec>] -- <command...>" >&2; exit 2; }

run_main() {
  TASK=""; TIMEOUT=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --task) [ $# -ge 2 ] || usage; TASK="$2"; shift 2 ;;
      --timeout) [ $# -ge 2 ] || usage; TIMEOUT="$2"; shift 2 ;;
      --) shift; break ;;
      *) echo "heavy.sh: unknown option $1" >&2; usage ;;
    esac
  done
  case "$TIMEOUT" in ''|*[!0-9]*) echo "heavy.sh: --timeout needs a whole number of seconds" >&2; exit 2 ;; esac
  if [ -z "$TASK" ] || [ $# -eq 0 ]; then usage; fi
  resolve_paths
  if [ -n "${HEAVY_HELD:-}" ] && [ "$HEAVY_HELD" = "$LOCK" ]; then
    say "already inside a heavy slot for task $TASK; running the command directly"
    exec "$@"
  fi
  CMD_TEXT="$*"
  DEADLINE=0; [ "$TIMEOUT" -gt 0 ] && DEADLINE=$(( $(now) + TIMEOUT ))
  HAVE_LOCK=0; SIGNALLED=""; CHILD=""; GROUP=1
  trap 'release_lock' EXIT
  trap 'on_signal INT 130' INT
  trap 'on_signal TERM 143' TERM
  trap 'on_signal HUP 129' HUP

  acquire_lock "$@"; rc=$?
  if [ $rc = 2 ]; then say "task $TASK cancelled while waiting for the lock"; exit "$SIGNALLED"; fi
  if [ $rc != 0 ]; then say "task $TASK gave up waiting for the lock after ${TIMEOUT}s"; exit 124; fi
  memory_gate; rc=$?
  if [ $rc = 2 ]; then say "task $TASK cancelled while waiting for memory"; release_lock; exit "$SIGNALLED"; fi
  if [ $rc != 0 ]; then say "task $TASK gave up waiting for memory after ${TIMEOUT}s"; release_lock; exit 124; fi

  START_H="$(date '+%Y-%m-%d %H:%M:%S')"
  snapshot_sims
  say "slot started for task $TASK: $CMD_TEXT"
  export HEAVY_HELD="$LOCK"
  # Without a terminal, give the command its own process group (set -m) so one signal stops
  # the whole tree. With a terminal on stdin that would leave it in a background group,
  # stopped by SIGTTIN on the first read, so it stays in our group and keeps stdin.
  if [ -t 0 ]; then
    GROUP=0
    "$@" <&0 &
    CHILD=$!
  else
    GROUP=1
    set -m
    "$@" &
    CHILD=$!
    set +m
  fi
  wait "$CHILD"; code=$?
  if [ -n "$SIGNALLED" ]; then
    say "stopping the command (and everything it started)"
    stop_child
    wait "$CHILD" 2>/dev/null
    code="$SIGNALLED"
  fi
  CHILD=""
  shutdown_new_sims
  write_log "$code"
  release_lock
  say "slot finished for task $TASK, exit $code"
  exit "$code"
}

# ---------- self-test ----------

self_test() {
  local tmp fails=0 out rc f p1 p2 dead sp t0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/heavy-selftest.XXXXXX")"
  export HEAVY_LOCK="$tmp/lock" HEAVY_LOG="$tmp/log.md" HEAVY_NO_SIM=1
  export HEAVY_POLL_SEC=1 HEAVY_SWAP_GAP_SEC=1 HEAVY_FAKE_SWAP_MB=100 HEAVY_FAKE_COMPRESSED_GB=1
  unset HEAVY_FAKE_COMPRESSED_GB_FILE
  trap 'rm -rf "$tmp"' EXIT
  ok() { echo "  ok   $1"; }
  bad() { echo "  FAIL $1"; fails=$((fails + 1)); }

  echo "1. two concurrent slots serialize"
  f="$tmp/order"; : > "$f"
  "$SELF" --task A -- sh -c "echo A-start >> $f; sleep 3; echo A-end >> $f" 2>/dev/null &
  p1=$!
  sleep 1
  "$SELF" --task B -- sh -c "echo B-start >> $f; sleep 1; echo B-end >> $f" 2>/dev/null &
  p2=$!
  wait $p1; wait $p2
  if [ "$(tr '\n' ' ' < "$f")" = "A-start A-end B-start B-end " ]; then ok "B started after A ended"; else bad "order was: $(tr '\n' ' ' < "$f")"; fi
  if [ ! -d "$HEAVY_LOCK" ]; then ok "lock released"; else bad "lock still present"; fi
  if [ "$(grep -c '^| [AB] |' "$HEAVY_LOG")" = 2 ]; then ok "two log lines"; else bad "log lines: $(cat "$HEAVY_LOG")"; fi

  echo "2. stale locks are cleared"
  sh -c 'exit 0' & dead=$!; wait $dead
  mkdir "$HEAVY_LOCK"; echo "$dead" > "$HEAVY_LOCK/pid"; echo old > "$HEAVY_LOCK/task"; now > "$HEAVY_LOCK/start_epoch"
  out="$("$SELF" --task C --timeout 20 -- echo ran 2>&1)"; rc=$?
  if [ $rc = 0 ] && echo "$out" | grep -q "cleared stale lock" && echo "$out" | grep -q "^ran"; then ok "dead holder pid cleared"; else bad "dead pid: rc=$rc $out"; fi
  mkdir "$HEAVY_LOCK"; echo "$$" > "$HEAVY_LOCK/pid"; echo old > "$HEAVY_LOCK/task"; echo $(( $(now) - 99999 )) > "$HEAVY_LOCK/start_epoch"
  out="$("$SELF" --task D --timeout 20 -- echo ran 2>&1)"; rc=$?
  if [ $rc = 0 ] && echo "$out" | grep -q "longer than"; then ok "over-age lock cleared"; else bad "old lock: rc=$rc $out"; fi
  mkdir "$HEAVY_LOCK"; echo "$$" > "$HEAVY_LOCK/pid"; echo live > "$HEAVY_LOCK/task"; now > "$HEAVY_LOCK/start_epoch"
  out="$("$SELF" --task E --timeout 3 -- echo ran 2>&1)"; rc=$?
  if [ $rc = 124 ]; then ok "live lock is respected"; else bad "live lock: rc=$rc $out"; fi
  rm -rf "$HEAVY_LOCK"

  echo "3. high memory blocks the slot until it clears"
  echo 99 > "$tmp/gb"; export HEAVY_FAKE_COMPRESSED_GB_FILE="$tmp/gb"
  out="$("$SELF" --task F --timeout 4 -- echo ran 2>&1)"; rc=$?
  if [ $rc = 124 ] && ! echo "$out" | grep -q "^ran"; then ok "blocked while compressed memory is 99 GB"; else bad "gate: rc=$rc $out"; fi
  if [ ! -d "$HEAVY_LOCK" ]; then ok "lock released after memory timeout"; else bad "lock left behind"; fi
  ( sleep 4; echo 2 > "$tmp/gb" ) &
  t0="$(now)"
  out="$("$SELF" --task G --timeout 60 -- echo ran 2>&1)"; rc=$?
  if [ $rc = 0 ] && echo "$out" | grep -q "^ran" && [ $(( $(now) - t0 )) -ge 3 ]; then ok "ran after memory cleared"; else bad "gate clear: rc=$rc $out"; fi
  unset HEAVY_FAKE_COMPRESSED_GB_FILE
  if gt 101 100 && ! gt 100 100; then ok "swap growth comparison"; else bad "swap comparison"; fi

  echo "4. exit code and signals"
  "$SELF" --task H -- sh -c 'exit 7' 2>/dev/null; rc=$?
  if [ $rc = 7 ]; then ok "exit code passed through"; else bad "exit code $rc"; fi
  if [ ! -d "$HEAVY_LOCK" ]; then ok "lock released after failure"; else bad "lock left after failure"; fi
  "$SELF" --task I -- sleep 30 2>/dev/null & sp=$!
  sleep 2; kill -TERM $sp; wait $sp; rc=$?
  if [ ! -d "$HEAVY_LOCK" ]; then ok "lock released after TERM (rc $rc)"; else bad "lock left after TERM"; fi

  echo "5. signals stop the whole command and cancel waiting"
  "$SELF" --task J -- bash -c 'sleep 3171; echo x' 2>/dev/null & sp=$!
  sleep 2; kill -TERM $sp; wait $sp; rc=$?
  if [ $rc = 143 ]; then ok "exit code 143 after TERM"; else bad "TERM exit code $rc"; fi
  if ! pgrep -f 'sleep 3171' >/dev/null; then ok "no child survived TERM"; else bad "sleep 3171 survived"; pkill -f 'sleep 3171'; fi
  if [ ! -d "$HEAVY_LOCK" ]; then ok "lock released after TERM"; else bad "lock left after TERM"; fi
  "$SELF" --task J2 -- bash -c 'sleep 3172; echo x' 2>/dev/null & sp=$!
  sleep 2; kill -HUP $sp; wait $sp; rc=$?
  if [ $rc = 129 ] && ! pgrep -f 'sleep 3172' >/dev/null; then ok "HUP stops the command too"; else bad "HUP rc=$rc"; pkill -f 'sleep 3172'; fi
  rm -rf "$HEAVY_LOCK"
  mkdir "$HEAVY_LOCK"; echo "$$" > "$HEAVY_LOCK/pid"; echo live > "$HEAVY_LOCK/task"; now > "$HEAVY_LOCK/start_epoch"
  "$SELF" --task K --timeout 60 -- echo ran > "$tmp/k.out" 2>&1 & sp=$!
  sleep 2; t0="$(now)"; kill -TERM $sp; wait $sp; rc=$?
  if [ $rc = 143 ] && [ $(( $(now) - t0 )) -le 3 ] && ! grep -q '^ran' "$tmp/k.out"; then ok "TERM while waiting for the lock exits fast, command not run"; else bad "wait-TERM rc=$rc $(cat "$tmp/k.out")"; fi
  rm -rf "$HEAVY_LOCK"
  echo 99 > "$tmp/gb"; export HEAVY_FAKE_COMPRESSED_GB_FILE="$tmp/gb"
  "$SELF" --task L --timeout 60 -- echo ran > "$tmp/l.out" 2>&1 & sp=$!
  sleep 2
  if [ -d "$HEAVY_LOCK" ]; then ok "holds the lock while waiting for memory"; else bad "no lock during memory wait"; fi
  t0="$(now)"; kill -TERM $sp; wait $sp; rc=$?
  if [ $rc = 143 ] && [ $(( $(now) - t0 )) -le 3 ] && [ ! -d "$HEAVY_LOCK" ]; then ok "TERM inside the memory gate releases the lock fast"; else bad "gate-TERM rc=$rc lock=$([ -d "$HEAVY_LOCK" ] && echo yes || echo no)"; fi
  unset HEAVY_FAKE_COMPRESSED_GB_FILE

  echo "5b. terminal mode (script(1)): reads work, signals still stop the tree"
  if command -v script >/dev/null 2>&1; then
    out="$(perl -e 'alarm 25; exec @ARGV' script -q /dev/null "$SELF" --task T1 -- bash -c 'read -t 3 v; echo done' 2>&1 </dev/null)"; rc=$?
    if [ $rc = 0 ] && echo "$out" | grep -q "^done"; then ok "command reading the terminal completes, no SIGTTIN hang"; else bad "tty read rc=$rc $out"; fi
    perl -e 'alarm 30; exec @ARGV' script -q /dev/null "$SELF" --task T2 -- bash -c 'sleep 3173 & sleep 3173; echo x' >/dev/null 2>&1 </dev/null & sp=$!
    sleep 3
    pkill -TERM -f '^/bin/bash .*heavy.sh --task T2' 2>/dev/null
    wait $sp 2>/dev/null
    sleep 1
    if ! pgrep -f 'sleep 3173' >/dev/null; then ok "TERM in terminal mode leaves no survivors"; else bad "sleep 3173 survived in terminal mode"; pkill -f 'sleep 3173'; fi
    if [ ! -d "$HEAVY_LOCK" ]; then ok "lock released after terminal-mode TERM"; else bad "lock left after terminal-mode TERM"; fi
  else
    echo "  skip script(1) not available"
  fi

  echo "6. argument checks and nesting"
  "$SELF" --task >/dev/null 2>&1; rc=$?
  if [ $rc = 2 ]; then ok "--task without a value is a usage error"; else bad "--task rc=$rc"; fi
  "$SELF" --task X --timeout abc -- echo hi >/dev/null 2>&1; rc=$?
  if [ $rc = 2 ]; then ok "non-numeric --timeout is a usage error"; else bad "timeout rc=$rc"; fi
  out="$("$SELF" --task outer -- "$SELF" --task inner --timeout 10 -- echo inner-ran 2>&1)"; rc=$?
  if [ $rc = 0 ] && echo "$out" | grep -q "^inner-ran" && echo "$out" | grep -q "already inside"; then ok "nested call runs directly"; else bad "nesting rc=$rc $out"; fi

  echo "7. simulator cleanup only touches this project's new simulators"
  local fb="$tmp/fakebin" st="$tmp/simstate" shut="$tmp/shut"
  mkdir -p "$fb"
  cat > "$fb/xcrun" <<'FAKE'
#!/bin/bash
# fake xcrun for the self-test
if [ "$1 $2" = "simctl list" ]; then
  if [ -n "$FAKE_FAIL_FIRST" ] && [ ! -e "$FAKE_FAIL_FIRST.done" ]; then touch "$FAKE_FAIL_FIRST.done"; exit 1; fi
  echo "== Devices =="; echo "-- iOS 26.0 --"; cat "$FAKE_SIM_STATE" 2>/dev/null; exit 0
fi
if [ "$1 $2" = "simctl shutdown" ]; then echo "$3" >> "$FAKE_SIM_SHUT"; exit 0; fi
exit 0
FAKE
  chmod +x "$fb/xcrun"
  local U1=11111111-1111-1111-1111-111111111111 U2=22222222-2222-2222-2222-222222222222 U3=33333333-3333-3333-3333-333333333333
  simrun() { HEAVY_NO_SIM=0 PATH="$fb:$PATH" FAKE_SIM_STATE="$st" FAKE_SIM_SHUT="$shut" "$SELF" "$@" 2>&1; }
  # a) the before listing fails: nothing may be shut down
  : > "$shut"; echo "    Prompter Dev iPhone ($U1) (Booted) " > "$st"; rm -f "$tmp/ff.done"
  out="$(FAKE_FAIL_FIRST="$tmp/ff" simrun --task S1 -- true)"
  if [ ! -s "$shut" ] && echo "$out" | grep -q "not shutting any simulator down"; then ok "failed before-snapshot: no shutdowns"; else bad "before-fail: $(cat "$shut") / $out"; fi
  # b) someone else's simulator boots during the slot: left alone
  : > "$shut"; : > "$st"
  out="$(simrun --task S2 -- sh -c "echo '    Shared iPhone 17 Pro Max ($U2) (Booted) ' >> $st")"
  if [ ! -s "$shut" ] && echo "$out" | grep -q "leaving simulator"; then ok "other session's simulator left alone"; else bad "foreign sim: $(cat "$shut") / $out"; fi
  # c) a project simulator boots during the slot: shut down, the pre-booted one is not
  : > "$shut"; echo "    Prompter Dev iPhone ($U1) (Booted) " > "$st"
  out="$(simrun --task S3 -- sh -c "echo '    Prompter Test Phone ($U3) (Booted) ' >> $st")"
  if [ "$(cat "$shut")" = "$U3" ]; then ok "new project simulator shut down, pre-booted one kept"; else bad "project sim: '$(cat "$shut")' / $out"; fi

  if [ $fails = 0 ]; then echo "self-test passed"; exit 0; else echo "self-test: $fails failure(s)"; exit 1; fi
}

case "${1:-}" in
  --self-test) self_test ;;
  -h|--help) sed -n '2,13p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") echo "usage: heavy.sh --task <ID> [--timeout <sec>] -- <command...>" >&2; exit 2 ;;
  *) run_main "$@" ;;
esac
