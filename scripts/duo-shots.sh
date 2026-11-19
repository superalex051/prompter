#!/usr/bin/env bash
# Screenshots of every screen on the iPhone Duo in every posture, from both displays, for a contact sheet.
#
#   scripts/heavy.sh --task DUO-SHOTS -- scripts/duo-shots.sh <output folder>
#
# Builds once, then for each posture launches every route (-demoData, so never real scripts) and saves a screenshot of the
# cover display and of the open display. Files are named <posture>-<route>-<display>.png, for example
# closed-prompter-cover.png or open-tall-library-open.png, so a sort puts the same screen in every posture side by side
# (and `ls *-library-*` gives one screen's whole row). The folder also gets manifest.txt: one line per shot with the
# window the app reported (size, size classes) at that moment, and any shot that failed.
#
# Postures (in this order): closed (cover, portrait 466x678), closed-landscape (cover turned: 678x466), open (951x669),
# book (half open, held wide like open: the fold runs top to bottom), open-tall (open turned: 669x951). Book comes before
# open-tall because a turn stays: pressed after open-tall it would fold across a tall window (tabletop). The posture is set
# with scripts/duo-posture.sh and the window is measured with the app's -duoProbe log (book too), so a run that could not
# reach a posture says so in the manifest instead of quietly shooting the wrong one.
# Routes: library, editor, prompter (playing: the countdown has run), prompterSettings, settings, syncSettings, macRemote.
#
# Environment:
#   SIM_UDID / SIM   the Duo (default: the simulator named "Prompter Dev Duo", found by exact name)
#   POSTURES         space separated subset, default "closed closed-landscape open book open-tall"
#   ROUTES           space separated subset, default as above
#   SKIP_BUILD=1     reuse the last scripts/build.sh output
#   DISPLAYS         "1 3" by default: 1 is the cover display, 3 the open one (`xcrun simctl io <udid> enumerate`)
#
# Run it through scripts/heavy.sh (it boots a simulator, and only one heavy task runs at a time). Never run it while another
# session is using Device Hub on this Mac: the posture buttons are shared. The Duo is left booted in the posture it ended
# in; heavy.sh shuts it down when the slot ends. Local Network and similar system prompts are not answered: a shot that
# shows one is a real finding.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

OUT="${1:?usage: scripts/duo-shots.sh <output folder>}"
SIM="${SIM:-Prompter Dev Duo}"
POSTURES="${POSTURES:-closed closed-landscape open book open-tall}"
ROUTES="${ROUTES:-library editor prompter prompterSettings settings syncSettings macRemote}"
DISPLAYS="${DISPLAYS:-1 3}"
APP="$IOS_APP_DEFAULT"
mkdir -p "$OUT"
MANIFEST="$OUT/manifest.txt"
: > "$MANIFEST"

if [ "${SKIP_BUILD:-0}" != "1" ]; then scripts/build.sh; fi
[ -d "$APP" ] || { echo "No build at $APP; run scripts/build.sh first" >&2; exit 1; }
UDID="${SIM_UDID:-$(sim_udid "$SIM" iOS)}" || exit 1
sim_is_duo "$UDID" || { echo "$UDID is not an iPhone Duo simulator" >&2; exit 2; }
APP_ID="$(app_bundle_id "$APP")"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"
trap 'xcrun simctl terminate "$UDID" "$APP_ID" 2>/dev/null || true; xcrun simctl status_bar "$UDID" clear 2>/dev/null || true' EXIT

# route -> app arguments, and how long to wait before the shot
route_args() {
  case "$1" in
    library)         echo "-route library" ;;
    editor)          echo "-route editor" ;;
    prompter)        echo "-route prompter -autoStart true" ;;
    prompterSettings) echo "-route prompterSettings" ;;
    settings)        echo "-route settings" ;;
    syncSettings)    echo "-route syncSettings" ;;
    macRemote)       echo "-route macRemote" ;;
    *) echo "unknown route $1" >&2; return 1 ;;
  esac
}
route_wait() { case "$1" in prompter) echo 10 ;; *) echo 5 ;; esac; }   # the prompter: 5 s countdown, then some seconds of playing
display_name() { case "$1" in 1) echo cover ;; 3) echo open ;; *) echo "d$1" ;; esac; }

shoot_posture() {  # shoot_posture <posture slug> <duo_apply_posture name>
  local slug="$1" want="$2" route args wait d name probe
  echo "== $slug"
  if ! duo_apply_posture "$UDID" "$APP_ID" "$want"; then
    echo "$slug: could not reach the posture; shooting what is there" | tee -a "$MANIFEST"
  fi
  sleep 2
  for route in $ROUTES; do
    args="$(route_args "$route")" || continue
    wait="$(route_wait "$route")"
    # Same launch twice would be wasteful: one launch with the probe on gives both the window line and the screenshots.
    xcrun simctl terminate "$UDID" "$APP_ID" 2>/dev/null || true
    local data; data="$(xcrun simctl get_app_container "$UDID" "$APP_ID" data 2>/dev/null || true)"
    [ -n "$data" ] && rm -f "$data/Documents/duo-probe.log"
    # shellcheck disable=SC2086
    if ! xcrun simctl launch "$UDID" "$APP_ID" -duoProbe -demoData $args >/dev/null 2>&1; then
      echo "$slug-$route | FAILED (the app did not launch)" | tee -a "$MANIFEST"
      continue
    fi
    sleep "$wait"
    # (|| true: no log, a crash or a slow launch must give "no probe line", not stop the whole run under set -e)
    probe="$( { grep -E '^[0-9:.]+ size ' "$data/Documents/duo-probe.log" 2>/dev/null | tail -1 | sed -E 's/^[0-9:.]+ //; s/ · Kind.*//'; } || true)"
    for d in $DISPLAYS; do
      name="$slug-$route-$(display_name "$d").png"
      if xcrun simctl io "$UDID" screenshot --display="$d" "$OUT/$name" >/dev/null 2>&1; then
        echo "$name | ${probe:-no probe line}" >> "$MANIFEST"
      else
        rm -f "$OUT/$name"
        echo "$name | FAILED (display $d gave no screenshot)" >> "$MANIFEST"
      fi
    done
    xcrun simctl terminate "$UDID" "$APP_ID" 2>/dev/null || true
  done
}

for p in $POSTURES; do
  case "$p" in
    closed)           shoot_posture closed Closed ;;
    closed-landscape) shoot_posture closed-landscape ClosedLandscape ;;
    open)             shoot_posture open Open ;;
    open-tall)        shoot_posture open-tall OpenTall ;;
    book)             shoot_posture book Book ;;
    *) echo "unknown posture $p (closed closed-landscape open book open-tall)" >&2; exit 2 ;;
  esac
done
echo "Done: $(find "$OUT" -name '*.png' | wc -l | tr -d ' ') screenshots in $OUT, manifest in $MANIFEST"
