#!/usr/bin/env bash
# Run the Maestro UI flows in qa/ on an iPhone simulator and leave a screenshot of every screen they touch.
#
#   scripts/qa.sh                     # build, then run every qa/*.yaml (the ipad-* flows only when the simulator is an iPad,
#                                     # and then only those)
#   scripts/qa.sh library settings    # only these flows (a name, name.yaml or qa/name.yaml)
#   CONFIG=Release scripts/qa.sh      # build the shipping configuration and run the one flow in qa/release/ (a Release
#                                     # build ignores every launch flag, so the normal flows cannot run against it)
#
# Environment:
#   SIM       simulator name, default "Prompter Dev iPhone" (the iPad run uses SIM="Prompter Dev iPad"). Found by exact
#             name; the script stops when no simulator or more than one has that name
#   SIM_UDID  use this simulator instead of looking SIM up
#   CONFIG    Debug (default) or Release
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
# configuration live in qa/release/ and run only with CONFIG=Release (name one as release/<name>). ---
FLOWS=()
DEFAULT_RUN=0
if [ $# -eq 0 ] && [ "$CONFIG" = "Release" ]; then
  for f in qa/release/*.yaml; do FLOWS+=("$f"); done
elif [ $# -eq 0 ]; then
  DEFAULT_RUN=1   # narrowed to the iPhone flows or the iPad flows once the simulator is known (below)
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

# --- Simulator ---
if [ -n "${SIM_UDID:-}" ]; then
  UDID="$SIM_UDID"
else
  UDID="$(sim_udid "$SIM" iOS)" || exit 1
fi
APP_ID="$(app_bundle_id "$APP")"

# With no flow names given, an iPad simulator runs the qa/ipad-*.yaml flows and any other simulator runs the rest
# (the split view only exists at regular width, so the two sets cannot pass on each other's device).
if [ "$DEFAULT_RUN" = "1" ]; then
  if sim_is_ipad "$UDID"; then IS_IPAD=1; else IS_IPAD=0; fi
  SELECTED=()
  for f in "${FLOWS[@]}"; do
    case "$(basename "$f")" in
      ipad-*) [ "$IS_IPAD" = "1" ] && SELECTED+=("$f") ;;
      *)      [ "$IS_IPAD" = "1" ] || SELECTED+=("$f") ;;
    esac
  done
  FLOWS=(${SELECTED[@]+"${SELECTED[@]}"})   # (an empty array is an error under `set -u` in macOS's bash 3.2)
  [ ${#FLOWS[@]} -gt 0 ] || { echo "No flows for this simulator in qa/" >&2; exit 2; }
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
  xcrun simctl status_bar "$UDID" clear 2>/dev/null || true
  if [ "$BOOTED_BY_US" = "1" ] && [ "${KEEP_SIM:-0}" != "1" ]; then
    echo "Shutting the simulator down again (KEEP_SIM=1 keeps it)"
    xcrun simctl shutdown "$UDID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

ensure_booted
xcrun simctl install "$UDID" "$APP"
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
  if "$MAESTRO" --device "$UDID" test -e "APP_ID=$APP_ID" --test-output-dir "$OUT" "$flow"; then
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
