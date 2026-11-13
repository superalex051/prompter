# Shared helpers for the build, test, qa and e2e scripts. Source it, do not run it:
#
#   . "$(dirname "$0")/lib.sh"
#
# Bundle IDs are never written into the scripts: they are read from the built apps (`app_bundle_id`), so a build with
# any BUNDLE_ID_PREFIX works. Simulators are found by exact name (`sim_udid`), never by "booted" or by a guessed UDID.

# Build configuration: Debug (default) or Release. A Release build ignores every debug launch flag (see
# Shared/LaunchArguments.swift), so only the qa/release/ flow runs against it.
export CONFIG="${CONFIG:-Debug}"
case "$CONFIG" in
  Debug|Release) ;;
  *) echo "CONFIG must be Debug or Release (got '$CONFIG')" >&2; exit 2 ;;
esac

# Where xcodebuild leaves the apps (relative to the repo root, which the scripts cd into).
IOS_APP_DEFAULT="build/DerivedData/Build/Products/${CONFIG}-iphonesimulator/Prompter.app"
MAC_APP_DEFAULT="build/DerivedData/Build/Products/${CONFIG}/Prompter.app"

# app_bundle_id <path to a built .app>: its CFBundleIdentifier (iOS and watchOS apps keep Info.plist at the top, a Mac
# app keeps it in Contents/).
app_bundle_id() {
  local app="$1" plist
  for plist in "$app/Info.plist" "$app/Contents/Info.plist"; do
    if [ -f "$plist" ]; then
      /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist"
      return 0
    fi
  done
  echo "No Info.plist in $app" >&2
  return 1
}

# sim_udid <exact device name> [iOS|watchOS]: the UDID of the one available simulator with exactly that name.
# Fails (prints why on stderr, returns 1) when there is none or when more than one has that name, so a script never
# guesses between two simulators. Set SIM_UDID (or PHONE / WATCH in the watch scripts) to pick one by hand.
sim_udid() {
  local name="$1" platform="${2:-iOS}"
  local out
  out=$(xcrun simctl list devices available -j | NAME="$name" PLATFORM="$platform" python3 -I -c '
import json, os, sys
name, platform = os.environ["NAME"], os.environ["PLATFORM"]
found = []
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if platform + "-" not in runtime and platform not in runtime.split(".")[-1]:
        continue
    for d in devices:
        if d["name"] == name:
            found.append((runtime.split(".")[-1], d["udid"]))
if len(found) == 1:
    print(found[0][1])
elif not found:
    print("none")
    sys.exit(1)
else:
    print("duplicates " + " ".join(runtime + ":" + udid for runtime, udid in found))
    sys.exit(2)
') && { echo "$out"; return 0; }
  case "$out" in
    none) echo "No available $platform simulator named '$name'" >&2 ;;
    duplicates*) echo "More than one $platform simulator is named '$name' (${out#duplicates }); set SIM_UDID to pick one" >&2 ;;
    *) echo "Could not list simulators" >&2 ;;
  esac
  return 1
}

# sim_is_ipad <udid>: succeeds when the simulator is an iPad.
sim_is_ipad() {
  xcrun simctl list devices available -j | UDID="$1" python3 -I -c '
import json, os, sys
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices:
        if d["udid"] == os.environ["UDID"]:
            sys.exit(0 if "iPad" in d["name"] else 1)
sys.exit(1)
'
}
