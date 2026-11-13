#!/usr/bin/env bash
# Install the last simulator build (scripts/build.sh) on an iPhone simulator, launch Prompter with optional launch arguments,
# wait, and save a screenshot to docs/screenshots/<name>.png.
#
#   scripts/sim-shot.sh <name> [delay-seconds] [-- app arguments...]
#   scripts/sim-shot.sh m1-library 3 -- -demoData -route library
#
# SIM="Prompter Dev iPad" scripts/sim-shot.sh ... picks another simulator by exact name (default "Prompter Dev iPhone").
# SIM_UDID=<udid> picks one by hand. The script stops when a name matches none or more than one simulator.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh
NAME="${1:?usage: scripts/sim-shot.sh <name> [delay] [-- args...]}"; shift
DELAY="3"
if [ $# -gt 0 ] && [ "$1" != "--" ]; then DELAY="$1"; shift; fi
if [ $# -gt 0 ] && [ "$1" = "--" ]; then shift; fi
SIM="${SIM:-Prompter Dev iPhone}"
APP="$IOS_APP_DEFAULT"
[ -d "$APP" ] || { echo "No build at $APP; run scripts/build.sh first" >&2; exit 1; }

UDID="${SIM_UDID:-$(sim_udid "$SIM" iOS)}" || exit 1
APP_ID="$(app_bundle_id "$APP")"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl terminate "$UDID" "$APP_ID" 2>/dev/null || true
xcrun simctl launch "$UDID" "$APP_ID" "$@" >/dev/null
sleep "$DELAY"
mkdir -p docs/screenshots
xcrun simctl io "$UDID" screenshot "docs/screenshots/$NAME.png" >/dev/null 2>&1
echo "docs/screenshots/$NAME.png ($SIM, $UDID)"
