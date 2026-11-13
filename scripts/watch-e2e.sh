#!/usr/bin/env bash
# Watch <-> phone end-to-end on the paired dedicated simulators ("Prompter Dev iPhone" + "Prompter Dev Watch"):
# the watch app runs a -remoteScript that sends real WatchConnectivity commands; screenshots of both screens and both logs are saved.
#   scripts/build.sh && scripts/watch-e2e.sh [out-dir] ["start@8,pause@24,..."]
#   ORDER=watch-first scripts/watch-e2e.sh ...   # launch the watch app first and the phone 4 s later (default: phone first)
#   GAP=2 scripts/watch-e2e.sh ...               # seconds between the two launches (default 4)
#   NO_PUSH=1 scripts/watch-e2e.sh ...           # phone launched with -noWatchPush: it only answers the watch, never pushes
#                                                # (what WatchConnectivity does when the phone wrongly thinks the watch app is gone)
# Logs: phone.log / watch.log are the apps' own (debug level: every live push and its acknowledgement on the phone, every status
# the watch got with its sequence, which is the phone's clock in ms since 2001 when it made it), phone-wc.log / watch-wc.log
# are WatchConnectivity's framework log inside each app process (what WCSession actually sent and received).
# Phone screenshots of the landscape prompter come out as portrait frames; `sips -r 270` turns them upright.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
. scripts/lib.sh
OUT="${1:-$REPO/build/watch-e2e/$(date +%Y%m%d-%H%M%S)}"
PHONE="${PHONE:-$(sim_udid "Prompter Dev iPhone" iOS)}" || exit 1   # override with PHONE=<udid>
WATCH="${WATCH:-$(sim_udid "Prompter Dev Watch" watchOS)}" || exit 1   # override with WATCH=<udid>
APP="$REPO/$IOS_APP_DEFAULT"
WAPP="$APP/Watch/PrompterWatch.app"
[ -d "$WAPP" ] || { echo "No iOS build; run scripts/build.sh" >&2; exit 1; }
PHONE_ID="$(app_bundle_id "$APP")"
WATCH_ID="$(app_bundle_id "$WAPP")"
SCRIPT="${2:-start@8,pause@24,speedStep:5@28,resume@32,backToTop@50}"
ORDER="${ORDER:-phone-first}"
mkdir -p "$OUT"
for d in $PHONE $WATCH; do xcrun simctl boot $d 2>/dev/null; done
xcrun simctl bootstatus $PHONE -b >/dev/null; xcrun simctl bootstatus $WATCH -b >/dev/null
xcrun simctl status_bar $PHONE override --time 9:41 --batteryState charged --batteryLevel 100 2>/dev/null
xcrun simctl install $PHONE "$APP"
xcrun simctl install $WATCH "$WAPP"
xcrun simctl terminate $PHONE "$PHONE_ID" 2>/dev/null
xcrun simctl terminate $WATCH "$WATCH_ID" 2>/dev/null
# logs
LOGS=()
stream() { # device file predicate [level]
  xcrun simctl spawn "$1" log stream --style compact --level "${4:-info}" --predicate "$3" > "$OUT/$2" 2>&1 &
  LOGS+=($!)
}
stream $WATCH watch.log "subsystem == \"$WATCH_ID\"" debug
stream $PHONE phone.log "subsystem BEGINSWITH \"$PHONE_ID\"" debug
stream $WATCH watch-wc.log 'process == "PrompterWatch" AND subsystem == "com.apple.wcd"'
stream $PHONE phone-wc.log 'process == "Prompter" AND subsystem == "com.apple.wcd"'
sleep 1
# --terminate-running-process: a watch message can launch the phone app in the background first, and a plain launch would
# only bring that process forward without these arguments.
PHONE_ARGS=(-demoData -route prompter)
[ "${NO_PUSH:-0}" = 1 ] && PHONE_ARGS+=(-noWatchPush)
launch_phone() { xcrun simctl launch --terminate-running-process $PHONE "$PHONE_ID" "${PHONE_ARGS[@]}" >/dev/null; }
launch_watch() {
  xcrun simctl launch --terminate-running-process $WATCH "$WATCH_ID" -remoteScript "$SCRIPT" >/dev/null
  T0=$(date +%s)
}
GAP="${GAP:-4}"   # seconds between the two launches
if [ "$ORDER" = watch-first ]; then
  launch_watch; sleep "$GAP"; launch_phone
else
  launch_phone; sleep "$GAP"; launch_watch
fi
echo "order: $ORDER, phone: ${PHONE_ARGS[*]}"
shot() { # name at-seconds (after the watch launch, which starts the remote script)
  local now=$(( $(date +%s) - T0 )); local wait=$(( $2 - now )); [ $wait -gt 0 ] && sleep $wait
  xcrun simctl io $PHONE screenshot "$OUT/$1-phone.png" >/dev/null 2>&1
  xcrun simctl io $WATCH screenshot "$OUT/$1-watch.png" >/dev/null 2>&1
  echo "$1 at $(( $(date +%s) - T0 ))s"
}
shot 01-ready 6
shot 02-countdown 12
shot 03-playing 20
shot 04-paused 27
shot 05-speed-step 31
shot 06-resumed 38
shot 07-back-to-top 55
kill "${LOGS[@]}" 2>/dev/null
echo done
