#!/usr/bin/env bash
# Voice mode on the iPhone simulator, with screenshots over time.
#
# The simulator has no working speech recogniser (SpeechTranscriber is unavailable there and SFSpeechRecognizer fails to
# start, kLSRErrorDomain 300), so the app can't listen to anything on it. Instead this replays real recogniser results:
# scripts/voice-check.sh streams a spoken read-through of the demo script through the app's own SpeechAnalyzer code on
# the Mac and records every result with its time; the app's DEBUG `-voiceReplay` option plays them back into the same
# transcript → aligner → engine → screen path, at the recorded times.
#
#   scripts/voice-demo.sh              # build, record if needed, run, screenshots in build/voice-demo/
#   PUBLISH=1 scripts/voice-demo.sh    # also copy them to docs/screenshots/m4-voice-*.png
#   MODE=file scripts/voice-demo.sh    # instead feed the audio itself (-voiceFile): shows the fallback to WPM, since
#                                      # recognition can't start on the simulator
#
# SIM picks the simulator by exact name (default "Prompter Dev iPhone"; SIM_UDID=<udid> picks one by hand); SKIP_BUILD=1 reuses the last build;
# KEEP_SIM=1 leaves a simulator this script booted running.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

APP="$IOS_APP_DEFAULT"
SIM="${SIM:-Prompter Dev iPhone}"
MODE="${MODE:-replay}"
OUT=build/voice-demo
mkdir -p "$OUT"
# name:seconds. BEFORE counts from the launch (a 5 s countdown starts about 1 s in); AFTER from the moment listening
# starts (the log says so). The recorded read-through's first word comes about 1 s after that and its last about 30 s.
BEFORE="${BEFORE:-countdown:3}"
AFTER="${AFTER:-listening:0.4 following-1:8 following-2:16 following-3:24 holding:34}"

[ "${SKIP_BUILD:-0}" = "1" ] || scripts/build.sh
[ -d "$APP" ] || { echo "No build at $APP; run scripts/build.sh first" >&2; exit 1; }
[ -f build/voice-check/voice-check.results ] || scripts/voice-check.sh

UDID="${SIM_UDID:-$(sim_udid "$SIM" iOS)}" || exit 1
BUNDLE_ID="$(app_bundle_id "$APP")"

BOOTED_BY_US=0
if ! xcrun simctl list devices | grep -F "$UDID" | grep -q "(Booted)"; then
  xcrun simctl boot "$UDID" 2>/dev/null || true
  BOOTED_BY_US=1
fi
LOG_PID=""
cleanup() {
  [ -n "$LOG_PID" ] && kill "$LOG_PID" 2>/dev/null || true
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  if [ "$BOOTED_BY_US" = "1" ] && [ "${KEEP_SIM:-0}" != "1" ]; then xcrun simctl shutdown "$UDID" 2>/dev/null || true; fi
}
trap cleanup EXIT
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$APP"

DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)
mkdir -p "$DATA/Documents"
cp build/voice-check/voice-check.results "$DATA/Documents/voice-demo.results"
cp build/voice-check/voice-demo.m4a "$DATA/Documents/voice-demo.m4a"
if [ "$MODE" = "file" ]; then
  # Maestro's applesimutils grants speech recognition without the system prompt.
  APPLESIMUTILS="$HOME/.maestro/deps/applesimutils"
  [ -x "$APPLESIMUTILS" ] && "$APPLESIMUTILS" --byId "$UDID" --bundle "$BUNDLE_ID" --setPermissions "speech=YES, microphone=YES" >/dev/null || true
  SOURCE=(-voiceFile Documents/voice-demo.m4a)
else
  SOURCE=(-voiceReplay Documents/voice-demo.results)
fi

xcrun simctl spawn "$UDID" log stream --level debug --style compact \
  --predicate "subsystem == \"$BUNDLE_ID\" AND category == \"voice\"" > "$OUT/voice.log" 2>&1 &
LOG_PID=$!
sleep 1
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
now() { perl -MTime::HiRes=time -e 'printf "%.2f", time'; }
shoot() {   # shoot <list> <start time>
  for shot in $1; do
    name="${shot%%:*}"; at="${shot##*:}"
    while perl -e "exit !($(now) - $2 < $at)"; do sleep 0.05; done
    xcrun simctl io "$UDID" screenshot "$OUT/$name.png" >/dev/null 2>&1
    printf '%5.1f s  %s\n' "$(perl -e "printf '%.1f', $(now) - $2")" "$OUT/$name.png"
    if [ "${PUBLISH:-0}" = "1" ]; then cp "$OUT/$name.png" "docs/screenshots/m4-voice-$name.png"; fi
  done
}
START=$(now)
xcrun simctl launch "$UDID" "$BUNDLE_ID" -demoData -route prompter -autoStart -scrollMode voice "${SOURCE[@]}" >/dev/null
echo "Launched ($MODE) on $SIM ($UDID); seconds from launch:"
shoot "$BEFORE" "$START"
until grep -q -E "Listening (with|\(replay\))" "$OUT/voice.log"; do
  perl -e "exit !($(now) - $START > 30)" && { echo "Never started listening" >&2; exit 1; }
  sleep 0.05
done
LISTEN=$(now)
echo "Seconds from the start of listening:"
shoot "$AFTER" "$LISTEN"
echo
echo "Voice log ($OUT/voice.log):"
grep -E "Voice ready|Listening with|Heard|keeps failing|couldn't|No voice" "$OUT/voice.log" | sed -E 's/^[0-9-]+ //; s/Prompter\[[0-9a-f:]+\] \[[^]]+:voice\] //' | tail -40
