#!/bin/bash
# Fold, open or rotate an iPhone Duo simulator from a script. `xcrun simctl` has no posture verb, so this presses Device
# Hub's own posture buttons (Closed, Book, Open, Rotate Right) through the macOS Accessibility API.
#
#   scripts/duo-posture.sh select        show the Duo in Device Hub (its screen and posture buttons)
#   scripts/duo-posture.sh state         print the posture Device Hub shows for it (Closed, Book or Open)
#   scripts/duo-posture.sh Open          press a posture button: Closed, Book, Open or "Rotate Right"
#
#   DUO      the simulator's name as Device Hub lists it, default "Prompter Dev Duo"
#
# Device Hub is shared with every other session on this Mac, so the script never presses a button while Device Hub shows
# another device: `select` first, and every press checks the window title again. It needs Accessibility permission for the
# terminal that runs it. Never quit Device Hub. After a press, wait a few seconds for the app to resize, then take
# screenshots with `xcrun simctl io <udid> screenshot --display=<id>` (`xcrun simctl io <udid> enumerate` lists the IDs).
set -euo pipefail

DUO="${DUO:-Prompter Dev Duo}"
ACTION="${1:-}"
case "$ACTION" in
  select|state|Closed|Book|Open|"Rotate Right") ;;
  *) echo "usage: scripts/duo-posture.sh select|state|Closed|Book|Open|\"Rotate Right\"" >&2; exit 2 ;;
esac

PIDS=$(pgrep -f 'DeviceHub.app/Contents/MacOS/DeviceHub' || true)
if [ -z "$PIDS" ]; then echo "Device Hub is not running. Open it from Xcode (Window > Devices and Simulators)." >&2; exit 1; fi
if [ "$(echo "$PIDS" | wc -l | tr -d ' ')" != 1 ]; then echo "More than one Device Hub is running ($PIDS)." >&2; exit 1; fi

AXPID="$PIDS" AXDUO="$DUO" AXACTION="$ACTION" osascript -l JavaScript - <<'JXA'
ObjC.import("Cocoa");
ObjC.import("stdlib");
ObjC.bindFunction("AXUIElementCreateApplication", ["id", ["int"]]);
ObjC.bindFunction("AXUIElementCopyAttributeValue", ["int", ["id", "id", "id*"]]);
ObjC.bindFunction("AXUIElementSetAttributeValue", ["int", ["id", "id", "id"]]);
ObjC.bindFunction("AXUIElementPerformAction", ["int", ["id", "id"]]);
ObjC.bindFunction("AXIsProcessTrusted", ["bool", []]);

function attr(el, name) { const r = Ref(); return $.AXUIElementCopyAttributeValue(el, name, r) === 0 ? r[0] : null; }
function str(v) { if (v === null || v === undefined) return ""; try { return ObjC.unwrap(v) + ""; } catch (e) { return ""; } }
function kids(el) { const k = attr(el, "AXChildren"); const out = []; if (k) for (let i = 0; i < k.count; i++) out.push(k.objectAtIndex(i)); return out; }
function find(el, test, depth) {
  if (depth > 18) return null;
  if (test(el)) return el;
  for (const k of kids(el)) { const hit = find(k, test, depth + 1); if (hit) return hit; }
  return null;
}
function fail(message) { console.log(message); $.exit(1); }

const env = $.NSProcessInfo.processInfo.environment;
const pid = parseInt(str(env.objectForKey("AXPID")), 10);
const duo = str(env.objectForKey("AXDUO"));
const action = str(env.objectForKey("AXACTION"));
if (!$.AXIsProcessTrusted()) fail("This terminal has no Accessibility permission (System Settings > Privacy & Security > Accessibility).");

const app = $.AXUIElementCreateApplication(pid);
const windows = attr(app, "AXWindows");
if (!windows || Number(windows.count) === 0) fail("Device Hub shows no window.");
const win = windows.objectAtIndex(0);
const title = () => str(attr(win, "AXTitle"));
const showsDuo = () => title() === duo || title().startsWith(duo + " ");

// The sidebar row for the Duo: the row whose text is exactly its name. Its image describes the posture ("v68_Closed").
function duoRow() {
  return find(win, el => {
    if (str(attr(el, "AXRole")) !== "AXRow") return false;
    return find(el, t => str(attr(t, "AXRole")) === "AXStaticText" && str(attr(t, "AXValue")) === duo, 0) !== null;
  }, 0);
}
function posture() {
  const row = duoRow();
  if (!row) return "";
  const image = find(row, el => str(attr(el, "AXRole")) === "AXImage", 0);
  const d = image ? str(attr(image, "AXDescription")) : "";
  const m = d.match(/_(Closed|Book|Open)/i);
  return m ? m[1] : d;
}

if (action === "state") { console.log(posture() || "unknown"); $.exit(0); }

if (action === "select") {
  if (showsDuo()) { console.log("Device Hub shows " + title()); $.exit(0); }
  const row = duoRow();
  if (!row) fail("Device Hub lists no device named '" + duo + "'.");
  $.AXUIElementSetAttributeValue(row, "AXSelected", $.NSNumber.numberWithBool(true));
  for (let i = 0; i < 20 && !showsDuo(); i++) delay(0.25);
  if (!showsDuo()) fail("Selected '" + duo + "' but Device Hub still shows '" + title() + "'.");
  console.log("Device Hub shows " + title());
  $.exit(0);
}

// A posture press: only ever on the Duo.
if (!showsDuo()) fail("Device Hub shows '" + title() + "', not '" + duo + "'. Run: scripts/duo-posture.sh select");
const button = find(win, el => {
  const role = str(attr(el, "AXRole"));
  if (role !== "AXButton" && role !== "AXRadioButton" && role !== "AXCheckBox") return false;
  return str(attr(el, "AXTitle")) === action || str(attr(el, "AXDescription")) === action;
}, 0);
if (!button) fail("Device Hub shows no '" + action + "' button for " + duo + " (is it booted?).");
const before = posture();
const rc = $.AXUIElementPerformAction(button, "AXPress");
if (rc !== 0) fail("Pressing '" + action + "' failed (AX error " + rc + ").");
if (action !== "Rotate Right") {
  for (let i = 0; i < 24 && posture().toLowerCase() !== action.toLowerCase(); i++) delay(0.25);
}
console.log("pressed " + action + " (posture " + (before || "?") + " -> " + (posture() || "?") + ")");
JXA
