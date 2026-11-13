#!/usr/bin/env bash
# End-to-end check of Mac ⇄ iPhone sync with the real apps: Prompter for Mac on this Mac and the iPhone app on a simulator.
#
#   scripts/sync-e2e.sh            # uses the last scripts/build.sh and scripts/build-mac.sh output
#
# Both apps run with -demoData (throwaway libraries and throwaway pairings, so real data is never touched) and pair on
# their own with -syncPairingCode. They talk over loopback (Mac: -syncPort, iPhone: -syncHost 127.0.0.1:<port>) instead of
# Bonjour, because loopback needs no Local Network permission and so no system prompt on an unattended run.
# The Mac's -syncDemo creates a script, edits it and deletes it; the iPhone's -syncDemo creates one. The script watches
# both library files, prints when each change landed, and leaves screenshots and logs in $OUT.
#
# Environment:
#   SIM        simulator name, default "Prompter Dev iPhone" (found by exact name; fails on none or duplicates)
#   SIM_UDID   a simulator picked by hand instead
#   SYNC_PORT  default 50123
#   OUT        default qa/output/sync-<timestamp>
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

SIM="${SIM:-Prompter Dev iPhone}"
UDID="${SIM_UDID:-$(sim_udid "$SIM" iOS)}"
PORT="${SYNC_PORT:-50123}"
MAC_APP="$MAC_APP_DEFAULT"
IOS_APP="$IOS_APP_DEFAULT"
OUT="${OUT:-qa/output/sync-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
MAC_TMP="$(getconf DARWIN_USER_TEMP_DIR)"

[ -d "$MAC_APP" ] || { echo "No Mac build; run scripts/build-mac.sh" >&2; exit 1; }
[ -d "$IOS_APP" ] || { echo "No iOS build; run scripts/build.sh" >&2; exit 1; }
BUNDLE_ID="$(app_bundle_id "$IOS_APP")"      # the iPhone app; the Mac app logs under its own ID
MAC_BUNDLE_ID="$(app_bundle_id "$MAC_APP")"
if pgrep -f "$MAC_APP/Contents/MacOS/Prompter" >/dev/null; then
  echo "A Prompter for Mac from this build is already running; quit it first." >&2; exit 1
fi

BOOTED_BY_US=0
if ! xcrun simctl list devices | grep -F "$UDID" | grep -q "(Booted)"; then
  xcrun simctl boot "$UDID"
  BOOTED_BY_US=1
fi
cleanup() {
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  pkill -f "$MAC_APP/Contents/MacOS/Prompter" 2>/dev/null || true
  xcrun simctl status_bar "$UDID" clear >/dev/null 2>&1 || true
  if [ "$BOOTED_BY_US" = "1" ]; then xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$IOS_APP"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

START="$(date "+%Y-%m-%d %H:%M:%S")"
echo "Mac: launching (direct mode, port $PORT)"
# The Settings window opens on the iPhone tab; the app snapshots its own windows 25 s in (paired by then) and quits 40 s later.
open -n "$MAC_APP" --args -demoData -emptyLibrary -syncPairingCode 123456789012 -syncPort "$PORT" -syncDemo \
  -route settings -settingsTab iphone -snapshot "$OUT/mac" -snapshotDelay 25 -quitAfter 40
sleep 3

echo "iPhone: launching"
xcrun simctl launch "$UDID" "$BUNDLE_ID" -demoData -syncPairingCode 123456789012 -syncHost "127.0.0.1:$PORT" -syncDemo >/dev/null
DATA="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)"

# Watch both library files; take a simulator screenshot at each step.
RESULT=0
python3 -I - "$DATA" "$MAC_TMP" "$OUT" "$UDID" <<'PY' || RESULT=$?
import glob, json, os, subprocess, sys, time
data, mac_tmp, out, udid = sys.argv[1:5]
MAC_TITLE = "Sync demo from the Mac"
PHONE_TITLE = "Sync demo from the iPhone"

def newest(pattern):
    files = glob.glob(pattern)
    return max(files, key=os.path.getmtime) if files else None

def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None

def shot(name):
    subprocess.run(["xcrun", "simctl", "io", udid, "screenshot", os.path.join(out, name + ".png")],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

events = {}
deadline = time.time() + 75
mac_id = None
while time.time() < deadline and len(events) < 4:
    phone_file = newest(os.path.join(data, "tmp", "PrompterDemo-*", "scripts.json"))
    mac_file = newest(os.path.join(mac_tmp, "PrompterMacDemo-*", "scripts.json"))
    phone = load(phone_file) if phone_file else None
    mac = load(mac_file) if mac_file else None
    now = time.time()
    if phone:
        scripts = {s["id"]: s for s in phone["scripts"]}
        tombstones = {t["id"] for t in phone.get("tombstones", [])}
        demo = [s for s in phone["scripts"] if s["title"] == MAC_TITLE]
        if demo and "created" not in events:
            mac_id = demo[0]["id"]; events["created"] = now
            print(f"iPhone has the Mac's new script ({mac_id})", flush=True)
            time.sleep(1.0); shot("01-created")
        if demo and "Edited on the Mac" in demo[0]["body"] and "edited" not in events:
            events["edited"] = now
            print("iPhone has the Mac's edit", flush=True)
            time.sleep(1.0); shot("02-edited")
        if mac_id and mac_id not in scripts and mac_id in tombstones and "deleted" not in events:
            events["deleted"] = now
            print("iPhone has the Mac's deletion (script gone, tombstone kept)", flush=True)
            time.sleep(1.0); shot("03-deleted")
            with open(os.path.join(out, "iphone-scripts.json"), "w") as f:
                json.dump(phone, f, indent=1)
    if mac and "phone-created" not in events and any(s["title"] == PHONE_TITLE for s in mac["scripts"]):
        events["phone-created"] = now
        print("Mac's library file has the iPhone's new script", flush=True)
        with open(os.path.join(out, "mac-scripts.json"), "w") as f:
            json.dump(mac, f, indent=1)
    time.sleep(0.05)
with open(os.path.join(out, "events.json"), "w") as f:
    json.dump(events, f, indent=1)
missing = {"created", "edited", "deleted", "phone-created"} - events.keys()
print("missing: " + ", ".join(sorted(missing)) if missing else "all four changes arrived", flush=True)
sys.exit(1 if missing else 0)
PY

# The Sync with Mac screen, from a fresh iPhone launch (it pairs again with the code, the Mac is still up).
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl launch "$UDID" "$BUNDLE_ID" -demoData -syncPairingCode 123456789012 -syncHost "127.0.0.1:$PORT" -route syncSettings >/dev/null
sleep 6
xcrun simctl io "$UDID" screenshot "$OUT/04-sync-settings.png" >/dev/null 2>&1

# Logs (category "sync") from both sides, with the times each change was made and applied.
/usr/bin/log show --start "$START" --predicate "subsystem == \"$MAC_BUNDLE_ID\" AND category == \"sync\"" --style compact \
  > "$OUT/mac-sync.log" 2>/dev/null || true
xcrun simctl spawn "$UDID" log show --start "$START" --predicate "subsystem == \"$BUNDLE_ID\" AND category == \"sync\"" \
  --style compact > "$OUT/iphone-sync.log" 2>/dev/null || true

# Latency: "syncDemo <action> <id> at <t>" on one side, "applied … <id> … at <t>" on the other (same clock).
python3 -I - "$OUT" <<'PY'
import re, sys, os
out = sys.argv[1]
def lines(name):
    try:
        return open(os.path.join(out, name)).read().splitlines()
    except OSError:
        return []
made = [(m.group(1), m.group(2), float(m.group(3))) for l in lines("mac-sync.log") + lines("iphone-sync.log")
        for m in [re.search(r"syncDemo (\w+) ([0-9A-F-]{36}) at ([0-9.]+)", l)] if m]
applied = [(m.group(1), m.group(2), float(m.group(3))) for l in lines("mac-sync.log") + lines("iphone-sync.log")
           for m in [re.search(r"applied (live|deleted) ([0-9A-F-]{36}).* at ([0-9.]+)", l)] if m]
for action, ident, t in made:
    later = [a for a in applied if a[1] == ident and a[2] >= t]
    if later:
        print(f"{action:8} {ident[:8]}: applied on the other side {later[0][2] - t:.3f} s later")
    else:
        print(f"{action:8} {ident[:8]}: no 'applied' line found")
PY
ls "$OUT"
exit $RESULT
