#!/usr/bin/env bash
# Run the Maestro UI flows in qa/ on an iPhone simulator and leave a screenshot of every screen they touch.
#
#   scripts/qa.sh                     # build, then run every qa/*.yaml (the ipad-* flows only when the simulator is an iPad,
#                                     # and then only those)
#   scripts/qa.sh library settings    # only these flows (a name, name.yaml or qa/name.yaml)
#   CONFIG=Release scripts/qa.sh      # build the shipping configuration and run the one flow in qa/release/ (a Release
#                                     # build ignores every launch flag, so the normal flows cannot run against it)
#   CONFIG="Store Debug" scripts/qa.sh  # the store code (needs Config/Store.xcconfig); "Store Release" runs qa/release/
#
# Environment:
#   SIM       simulator name, default "Prompter Dev iPhone" (the iPad run uses SIM="Prompter Dev iPad"). Found by exact
#             name; the script stops when no simulator or more than one has that name
#   SIM_UDID  use this simulator instead of looking SIM up
#   DUO_POSTURE  iPhone Duo only (SIM="Prompter Dev Duo"): Closed (the cover screen, 466x678), Open (951x669) or OpenTall
#             (Open, then one "Rotate Right": 669x951). Set with scripts/duo-posture.sh after boot and before the flows, and
#             checked by measuring the window. Without it the Duo is used in whatever posture it is in now.
#             With no flow names the flows follow the measured window, not the simulator's name: a window at least
#             DUO_SPLIT_MIN_WIDTH points wide (default 700: the open Duo, 951, like an iPad) runs the ipad-*.yaml split view
#             flows; a narrower one (the cover, 466, and the open Duo turned tall, 669) runs the phone flows.
#   CONFIG    Debug (default), Release, "Store Debug" or "Store Release" (see scripts/lib.sh)
#   The app's bundle ID is read from the built app and handed to every flow as ${APP_ID}.
#   SKIP_BUILD=1   reuse the last scripts/build.sh output
#   KEEP_SIM=1     leave the simulator booted afterwards (by default one this script booted is shut down again)
#   MAESTRO   path to the maestro binary, default ~/.maestro/bin/maestro (it is not on PATH here)
#
# Screenshots land in qa/output/<timestamp>/<timestamp from Maestro>/<flow name>/takeScreenshot/*.png (git-ignored).
# Exit status is non-zero when a flow fails; the remaining flows still run.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

APP="$IOS_APP_DEFAULT"
MAESTRO="${MAESTRO:-$HOME/.maestro/bin/maestro}"
SIM="${SIM:-Prompter Dev iPhone}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="qa/output/$STAMP"

[ -x "$MAESTRO" ] || { echo "Maestro not found at $MAESTRO (set MAESTRO=/path/to/maestro)" >&2; exit 2; }

# --- Which flows. Shared sub-flows belong in qa/helpers/, which the glob below does not reach. Flows for the shipping
# configurations live in qa/release/ and run only with CONFIG=Release or "Store Release" (name one as release/<name>). ---
FLOWS=()
DEFAULT_RUN=0
if [ $# -eq 0 ] && [ "$IS_RELEASE_CONFIG" = 1 ]; then
  for f in qa/release/*.yaml; do FLOWS+=("$f"); done
elif [ $# -eq 0 ]; then
  DEFAULT_RUN=1   # narrowed to the iPhone flows or the iPad flows once the simulator (and its window) is known (below)
  for f in qa/*.yaml; do FLOWS+=("$f"); done
else
  for arg in "$@"; do
    name="${arg#qa/}"; name="${name%.yaml}"
    [ -f "qa/$name.yaml" ] || { echo "No flow qa/$name.yaml" >&2; exit 2; }
    FLOWS+=("qa/$name.yaml")
  done
fi
[ ${#FLOWS[@]} -gt 0 ] || { echo "No flows in qa/" >&2; exit 2; }

# --- Build ---
if [ "${SKIP_BUILD:-0}" != "1" ]; then
  scripts/build.sh
fi
[ -d "$APP" ] || { echo "No build at $APP; run scripts/build.sh first" >&2; exit 1; }
check_script_build "$APP"

# --- Simulator ---
if [ -n "${SIM_UDID:-}" ]; then
  UDID="$SIM_UDID"
else
  UDID="$(sim_udid "$SIM" iOS)" || exit 1
fi
APP_ID="$(app_bundle_id "$APP")"

IS_DUO=0
if sim_is_duo "$UDID"; then IS_DUO=1; fi
if [ -n "${DUO_POSTURE:-}" ]; then
  [ "$IS_DUO" = "1" ] || { echo "DUO_POSTURE only applies to an iPhone Duo simulator (SIM=\"Prompter Dev Duo\")" >&2; exit 2; }
  case "$DUO_POSTURE" in Closed|Open|OpenTall) ;; *) echo "DUO_POSTURE must be Closed, Open or OpenTall (got '$DUO_POSTURE')" >&2; exit 2 ;; esac
fi

# With no flow names given, an iPad simulator runs the qa/ipad-*.yaml flows and any other simulator runs the rest
# (the split view only exists at regular width, so the two sets cannot pass on each other's device). A Duo is decided
# later, from the window it really has (below).
select_flows() {  # select_flows <1 for the ipad-* flows, 0 for the rest>
  local want_ipad="$1" f SELECTED=()
  for f in "${FLOWS[@]}"; do
    case "$(basename "$f")" in
      ipad-*) [ "$want_ipad" = "1" ] && SELECTED+=("$f") ;;
      journey.yaml) [ "$want_ipad" = "1" ] || [ "$IS_DUO" = "1" ] || SELECTED+=("$f") ;;   # iPhone 17 Pro popover points (journey.yaml header)
      *)      [ "$want_ipad" = "1" ] || SELECTED+=("$f") ;;
    esac
  done
  FLOWS=(${SELECTED[@]+"${SELECTED[@]}"})   # (an empty array is an error under `set -u` in macOS's bash 3.2)
  [ ${#FLOWS[@]} -gt 0 ] || { echo "No flows for this simulator in qa/" >&2; exit 2; }
}
if [ "$DEFAULT_RUN" = "1" ] && [ "$IS_DUO" = "0" ]; then
  if sim_is_ipad "$UDID"; then select_flows 1; else select_flows 0; fi
fi

is_booted() { xcrun simctl list devices | grep -F "$UDID" | grep -q "(Booted)"; }

BOOTED_BY_US=0
ensure_booted() {
  if ! is_booted; then
    echo "Booting simulator $UDID"
    xcrun simctl boot "$UDID" 2>/dev/null || true
    BOOTED_BY_US=1
  fi
  xcrun simctl bootstatus "$UDID" -b >/dev/null
  # A fixed clock and full bars, so screenshots from different runs line up.
  xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 2>/dev/null || true
}

cleanup() {
  # OpenTall turned the simulator a quarter; turn it back so the next run (and Device Hub) start from the wide window.
  if [ "${DUO_POSTURE:-}" = "OpenTall" ]; then duo_apply_posture "$UDID" "$APP_ID" Open >/dev/null 2>&1 || true; fi
  xcrun simctl status_bar "$UDID" clear 2>/dev/null || true
  if [ "$BOOTED_BY_US" = "1" ] && [ "${KEEP_SIM:-0}" != "1" ]; then
    echo "Shutting the simulator down again (KEEP_SIM=1 keeps it)"
    xcrun simctl shutdown "$UDID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

ensure_booted
xcrun simctl install "$UDID" "$APP"

# --- iPhone Duo: posture, the window the flows will see, and which flows fit it ---
# Every flow gets -e DUO=0|1. On a Duo it also gets the measured window (from the app's -duoProbe log): WIN_W x WIN_H when
# the library opens, PRO_W x PRO_H when the prompter opens (the prompter turns a portrait window to landscape),
# PRO_SAFE_L / PRO_SAFE_T its real safe area, and TURNS=1 when the prompter's window is the library's turned a quarter.
# Other simulators get no measuring at all, so an iPhone or iPad run is what it always was.
FLOW_ENV=(-e "APP_ID=$APP_ID" -e "DUO=$IS_DUO")
if [ "$IS_DUO" = "1" ] && [ "$IS_RELEASE_CONFIG" = "1" ]; then
  # A Release build ignores every launch flag, -duoProbe included, so nothing can be measured and no release flow reads WIN_*.
  [ -z "${DUO_POSTURE:-}" ] || { echo "DUO_POSTURE needs the Debug build (a Release build ignores -duoProbe, so the posture cannot be checked)" >&2; exit 2; }
elif [ "$IS_DUO" = "1" ]; then
  if [ -n "${DUO_POSTURE:-}" ]; then
    echo "Duo posture: $DUO_POSTURE"
    duo_apply_posture "$UDID" "$APP_ID" "$DUO_POSTURE" || { echo "Could not put the Duo in $DUO_POSTURE" >&2; exit 1; }
  fi
  read -r WIN_W WIN_H WIN_CLASS _ <<<"$(duo_probe "$UDID" "$APP_ID" -route library)"
  read -r PRO_W PRO_H _ PRO_SAFE_L PRO_SAFE_T <<<"$(duo_probe "$UDID" "$APP_ID" -route prompter)"
  [ -n "${WIN_W:-}" ] || { echo "The Duo's window could not be measured (no -duoProbe log); is this the Debug build?" >&2; exit 1; }
  TURNS=0; [ "${PRO_W:-$WIN_W}" != "$WIN_W" ] && TURNS=1
  echo "Duo window: library ${WIN_W}x${WIN_H} ($WIN_CLASS width), prompter ${PRO_W:-?}x${PRO_H:-?}, safe l${PRO_SAFE_L:-?} t${PRO_SAFE_T:-?}, turns=$TURNS"
  FLOW_ENV+=(-e "WIN_W=$WIN_W" -e "WIN_H=$WIN_H" -e "PRO_W=${PRO_W:-$WIN_W}" -e "PRO_H=${PRO_H:-$WIN_H}"
             -e "PRO_SAFE_L=${PRO_SAFE_L:-0}" -e "PRO_SAFE_T=${PRO_SAFE_T:-0}")
  if [ "$DEFAULT_RUN" = "1" ]; then
    # 700 must match LibraryLayout.minimumSplitWidth (Prompter/Features/Library/LibraryLayout.swift): narrower phone windows
    # get the stack, where the ipad-* split-view flows fail. LibraryLayoutTests pins that number to this one.
    if [ "$WIN_W" -ge "${DUO_SPLIT_MIN_WIDTH:-700}" ]; then select_flows 1; else select_flows 0; fi
  fi
fi
# --- Tap points inside the prompter (qa/prompter.yaml and qa/journey.yaml) ---
# The prompter is landscape. Maestro reports its elements in landscape points but sends taps in the display's own portrait
# points when the window was turned (README, "Landscape"), so a landscape point (x, y) is tapped at "<H - y>,<x>" (H = the
# landscape window's height) when TURNS=1 and at "x,y" when TURNS=0. Off the Duo the numbers are the iPhone 17 Pro's (874 x 402),
# the points the flows always had: Done 336,759, close 368,96 (the flows fall back to the same ones when run by hand), and the
# drag in qa/prompter.yaml is its own fixed points whenever TURNS=1.
land_to_tap() { if [ "${TURNS:-1}" = 1 ]; then echo "$((${PRO_H:-402} - $2)),$1"; else echo "$1,$2"; fi; }
if [ "$IS_DUO" = "1" ] && [ -n "${WIN_W:-}" ]; then
  # The settings popover is anchored to the window's right edge. Done was measured on the cover screen (678 x 466 prompter
  # window: 76 pt from the right, 68 from the top). Other windows (the open Duo) have not been measured yet, so they get the
  # iPhone's offsets (115, 66): a guess that the first Open run has to confirm.
  if [ "$PRO_W" = 678 ] && [ "$PRO_H" = 466 ]; then DONE_X=$((PRO_W - 76)); DONE_Y=68; else DONE_X=$((PRO_W - 115)); DONE_Y=66; fi
  CLOSE_X=$((${PRO_SAFE_L:-0} + 34)); CLOSE_Y=34
else
  PRO_W=874; PRO_H=402; TURNS=1; DONE_X=759; DONE_Y=66; CLOSE_X=96; CLOSE_Y=34
fi
FLOW_ENV+=(-e "TAP_DONE=$(land_to_tap $DONE_X $DONE_Y)" -e "TAP_CLOSE=$(land_to_tap $CLOSE_X $CLOSE_Y)" -e "TURNS=$TURNS")
echo "Simulator $UDID, $APP_ID ($CONFIG), ${#FLOWS[@]} flow(s), output in $OUT"

# --- Don't collide with other Maestro runs on this Mac ---
# Two Maestro runs at once (e.g. another Claude Code session doing E2E on its own simulators) can fight over the iOS driver.
# Before each flow, wait until no other Maestro process is running (up to MAESTRO_WAIT seconds, default 1200), else stop.
other_maestro() { pgrep -fl 'maestro\.cli\.|maestro-driver' | grep -v -e 'pgrep' || true; }
wait_for_other_maestro() {
  local waited=0 limit="${MAESTRO_WAIT:-1200}"
  while [ -n "$(other_maestro)" ]; do
    if [ "$waited" -ge "$limit" ]; then
      echo "Another Maestro run has been busy for ${limit}s; stopping so the two don't collide." >&2
      other_maestro >&2
      exit 3
    fi
    [ "$waited" -eq 0 ] && echo "Waiting for another Maestro run on this Mac to finish…"
    sleep 15; waited=$((waited + 15))
  done
}

# --- Run ---
mkdir -p "$OUT"
PASSED=(); FAILED=()
for flow in "${FLOWS[@]}"; do
  name="$(basename "$flow" .yaml)"
  wait_for_other_maestro
  ensure_booted   # something else on this Mac may have shut the simulator down between flows
  echo
  echo "=== $name ==="
  if "$MAESTRO" --device "$UDID" test "${FLOW_ENV[@]}" --test-output-dir "$OUT" "$flow"; then
    PASSED+=("$name")
  else
    FAILED+=("$name")
  fi
done

# --- Report ---
echo
echo "Screenshots (a failed step also leaves a screenshot-... PNG next to the flow's folder):"
PNG_COUNT=$(find "$OUT" -name '*.png' | wc -l | tr -d ' ')
echo "  $PNG_COUNT PNG(s) under $OUT"
find "$OUT" -name '*.png' | sort | sed 's/^/  /'
echo
echo "Passed (${#PASSED[@]}): ${PASSED[*]:-none}"
echo "Failed (${#FAILED[@]}): ${FAILED[*]:-none}"
[ ${#FAILED[@]} -eq 0 ]
