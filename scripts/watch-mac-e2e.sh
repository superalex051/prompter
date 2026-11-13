#!/usr/bin/env bash
# Apple Watch → iPhone → Mac end-to-end check with the three real apps (M9):
#   - Prompter for Mac on this Mac presents the sample script (in ordinary windows on the main screen: -singleScreen, so it
#     never takes over a display someone is using; SECOND_SCREEN=1 presents full screen on the second one), listening for sync
#     on loopback (-syncPort) with a standing demo pairing code, and writes snapshots of its output and Presenter view;
#   - the iPhone app on "Prompter Dev iPhone" pairs with it by itself (-syncHost, -syncPairingCode) and opens Remote for Mac;
#   - the watch app on its paired "Prompter Dev Watch" runs a -remoteScript that sends real WatchConnectivity commands,
#     which the iPhone forwards to the Mac.
# Logs from all three, screenshots of the watch and the iPhone, the Mac's own snapshots, and the measured latencies end up in $OUT.
#
#   scripts/build.sh && scripts/build-mac.sh && scripts/watch-mac-e2e.sh
#
# Environment:
#   PHONE / WATCH   simulator UDIDs (default: found by exact name, "Prompter Dev iPhone" and "Prompter Dev Watch"; the
#                   script stops when a name matches none or more than one)
#   SYNC_PORT       default 50124
#   SCRIPT          the watch's remote script (seconds after the watch app launches)
#   OUT             default qa/output/watch-mac-<timestamp>
#   SECOND_SCREEN=1 present full screen on the second display, as on the real rig (only when nobody is using this Mac)
# Both apps run with -demoData (throwaway libraries, settings and pairings). Loopback needs no Local Network permission.
# The simulators are shut down again at the end if this script booted them; the Mac app quits by itself (-quitAfter).
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

PHONE="${PHONE:-$(sim_udid "Prompter Dev iPhone" iOS)}" || exit 1
WATCH="${WATCH:-$(sim_udid "Prompter Dev Watch" watchOS)}" || exit 1
PORT="${SYNC_PORT:-50124}"
SCRIPT="${SCRIPT:-start@8,pause@20,speedStep:5@24,resume@28,backToTop@40}"
MAC_APP="$MAC_APP_DEFAULT"
IOS_APP="$IOS_APP_DEFAULT"
WATCH_APP="$IOS_APP/Watch/PrompterWatch.app"
OUT="${OUT:-qa/output/watch-mac-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT/mac"
OUT="$(cd "$OUT" && pwd)"

[ -d "$MAC_APP" ] || { echo "No Mac build; run scripts/build-mac.sh" >&2; exit 1; }
[ -d "$WATCH_APP" ] || { echo "No iOS build; run scripts/build.sh" >&2; exit 1; }
BUNDLE_ID="$(app_bundle_id "$IOS_APP")"
WATCH_ID="$(app_bundle_id "$WATCH_APP")"
MAC_BUNDLE_ID="$(app_bundle_id "$MAC_APP")"
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $PORT is in use; set SYNC_PORT to another one." >&2; exit 1
fi
MAC_PID=""

BOOTED=()
for d in "$PHONE" "$WATCH"; do
  if ! xcrun simctl list devices | grep -F "$d" | grep -q "(Booted)"; then
    xcrun simctl boot "$d" && BOOTED+=("$d")
  fi
done
LOGS=()
cleanup() {
  [ ${#LOGS[@]} -gt 0 ] && kill "${LOGS[@]}" 2>/dev/null
  xcrun simctl terminate "$WATCH" "$WATCH_ID" >/dev/null 2>&1 || true
  xcrun simctl terminate "$PHONE" "$BUNDLE_ID" >/dev/null 2>&1 || true
  # Only the instance this script started (another Prompter for Mac may be open, with real data: never touch it).
  [ -n "$MAC_PID" ] && kill "$MAC_PID" 2>/dev/null || true
  xcrun simctl status_bar "$PHONE" clear >/dev/null 2>&1 || true
  for d in ${BOOTED[@]+"${BOOTED[@]}"}; do xcrun simctl shutdown "$d" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT
xcrun simctl bootstatus "$PHONE" -b >/dev/null
xcrun simctl bootstatus "$WATCH" -b >/dev/null
xcrun simctl status_bar "$PHONE" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 >/dev/null 2>&1 || true
xcrun simctl install "$PHONE" "$IOS_APP"
xcrun simctl install "$WATCH" "$WATCH_APP"
xcrun simctl terminate "$PHONE" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl terminate "$WATCH" "$WATCH_ID" >/dev/null 2>&1 || true

# Logs: the apps' own (watch and iPhone at debug level: every status the watch got, every forward on the iPhone); the
# Mac's remote and sync categories are streamed from the instance this script starts (by its process id, below).
stream_sim() { # device file predicate
  xcrun simctl spawn "$1" log stream --style compact --level debug --predicate "$3" > "$OUT/$2" 2>&1 &
  LOGS+=($!)
}
stream_sim "$WATCH" watch.log "subsystem == \"$WATCH_ID\""
stream_sim "$PHONE" phone.log "subsystem == \"$BUNDLE_ID\" AND (category == \"remote\" OR category == \"sync\")"
sleep 2

# Timeline (seconds after the Mac launches): Mac presents at ~1.5; iPhone at 3; watch at 6, so the watch's script steps land
# at 6 + their time. The Mac's snapshots are timed from when presenting began: mid-countdown, playing, paused, sped up,
# resumed, back at the top.
T0=$(date +%s)
echo "Mac: presenting, sync on 127.0.0.1:$PORT"
# Started directly (not with `open`), so the script knows its process and quits only that one.
SCREEN_ARGS=(-singleScreen)
[ "${SECOND_SCREEN:-0}" = 1 ] && SCREEN_ARGS=()
"$MAC_APP/Contents/MacOS/Prompter" -demoData ${SCREEN_ARGS[@]+"${SCREEN_ARGS[@]}"} -syncPort "$PORT" -syncPairingCode 123456789012 \
  -route prompter -script sample -snapshot "$OUT/mac" -presenterSnapshots 13,21,27,31,37,49 -quitAfter 62 \
  > "$OUT/mac-stdout.log" 2>&1 &
MAC_PID=$!
/usr/bin/log stream --style compact --level info \
  --predicate "processIdentifier == $MAC_PID AND subsystem == \"$MAC_BUNDLE_ID\" AND (category == \"remote\" OR category == \"sync\")" \
  > "$OUT/mac.log" 2>&1 &
LOGS+=($!)
sleep 3
echo "iPhone: Remote for Mac"
xcrun simctl launch --terminate-running-process "$PHONE" "$BUNDLE_ID" -demoData -syncHost "127.0.0.1:$PORT" \
  -syncPairingCode 123456789012 -route macRemote >/dev/null
sleep 3
echo "watch: $SCRIPT"
xcrun simctl launch --terminate-running-process "$WATCH" "$WATCH_ID" -remoteScript "$SCRIPT" >/dev/null
TW=$(date +%s)

shot() { # name at-seconds-after-the-watch-launch [phone]
  local now=$(( $(date +%s) - TW )); local wait=$(( $2 - now )); [ $wait -gt 0 ] && sleep $wait
  xcrun simctl io "$WATCH" screenshot "$OUT/$1-watch.png" >/dev/null 2>&1
  [ "${3:-}" = phone ] && xcrun simctl io "$PHONE" screenshot "$OUT/$1-phone.png" >/dev/null 2>&1
  echo "$1 at watch +$(( $(date +%s) - TW ))s"
}
shot 01-ready 6 phone
shot 02-countdown 10
shot 03-playing 17 phone
shot 04-paused 23 phone
shot 05-speed-step 27
shot 06-resumed 33 phone
shot 07-back-to-top 44 phone
# Let the Mac quit by itself and the logs catch up.
while kill -0 "$MAC_PID" 2>/dev/null && [ $(( $(date +%s) - T0 )) -lt 75 ]; do sleep 1; done
sleep 1
kill "${LOGS[@]}" 2>/dev/null
LOGS=()

# What happened, and how fast: watch "send X" → Mac "remote X applied" (same clock: the simulators log the host's time),
# and each Mac state change → the first watch status showing it.
python3 -I - "$OUT" <<'PY'
import os, re, sys
from datetime import datetime
out = sys.argv[1]
def lines(name):
    try:
        return open(os.path.join(out, name), errors="replace").read().splitlines()
    except OSError:
        return []
stamp = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)")
def t(line):
    m = stamp.match(line)
    return datetime.strptime(m.group(1)[:26], "%Y-%m-%d %H:%M:%S.%f").timestamp() if m else None
watch, phone, mac = lines("watch.log"), lines("phone.log"), lines("mac.log")
sends = [(t(l), m.group(1)) for l in watch for m in [re.search(r"\bsend (\w+(?:\(-?\d+\))?)", l)] if m and t(l) and m.group(1) != "failed"]
applied = [(t(l), m.group(1), l) for l in mac for m in [re.search(r"remote (\S+) applied", l)] if m and t(l)]
forwards = [(t(l), m.group(1)) for l in phone for m in [re.search(r"forward (\S+) to the Mac", l)] if m and t(l)]
states = [(t(l), m.group(1)) for l in mac for m in [re.search(r"presenter (.+?) at [0-9.]+$", l)] if m and t(l)]
watch_states = [(t(l), m.group(1)) for l in watch for m in [re.search(r"\] status (.+?) seq", l)] if m and t(l)]
report = []
def say(s):
    print(s); report.append(s)
say("Mac presenter states (from the Mac's log):")
for ts, s in states:
    say(f"  {datetime.fromtimestamp(ts).strftime('%H:%M:%S.%f')[:-3]}  {s}")
say("Commands, watch send → iPhone forward → Mac applied:")
used = set()
for ts, cmd in sends:
    if cmd == "requestStatus":
        continue
    key = cmd.replace("(", "(").split("(")[0]
    fw = next((f for f in forwards if f[0] >= ts - 0.05 and f[1].startswith(key)), None)
    ap = next((a for a in applied if a[0] >= ts - 0.05 and a[1].startswith(key) and a[0] not in used), None)
    if ap: used.add(ap[0])
    fws = f"{fw[0] - ts:6.3f} s" if fw else "   none"
    aps = f"{ap[0] - ts:6.3f} s" if ap else "   none"
    say(f"  {cmd:14} forwarded after {fws}, applied on the Mac after {aps}")
say("Mac state change → watch shows it (from when the watch app was up):")
watch_up = next((t(l) for l in watch if t(l)), 0)
for ts, s in states:
    if ts < watch_up: continue
    word = s.split(" ")[0].split("(")[0]
    if word == "not": continue
    seen = next((w for w in watch_states if w[0] >= ts and w[1].startswith(word) and " on " in w[1]), None)
    say(f"  {s:32} {'on the watch after %.3f s' % (seen[0] - ts) if seen else 'not seen on the watch'}")
open(os.path.join(out, "latency.txt"), "w").write("\n".join(report) + "\n")
PY
ls "$OUT" "$OUT/mac"
