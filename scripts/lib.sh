# Shared helpers for the build, test, qa and e2e scripts. Source it, do not run it:
#
#   . "$(dirname "$0")/lib.sh"
#
# Bundle IDs are never written into the scripts: they are read from the built apps (`app_bundle_id`), so a build with
# any BUNDLE_ID_PREFIX works. Simulators are found by exact name (`sim_udid`), never by "booted" or by a guessed UDID.

# Build configuration (quote the two-word names):
#   Debug (default), Release          the self-build: every feature on, no App Store purchase, no iCloud.
#   "Store Debug", "Store Release"    store builds. They also read the git-ignored Config/Store.xcconfig (copy
#                                     Config/Store.xcconfig.example); the scripts stop when it is missing.
# Release and Store Release ignore every debug launch flag (see Shared/LaunchArguments.swift), so only the qa/release/ flow
# runs against them.
export CONFIG="${CONFIG:-Debug}"
case "$CONFIG" in
  Debug|Release) IS_STORE_CONFIG=0 ;;
  "Store Debug"|"Store Release") IS_STORE_CONFIG=1 ;;
  *) echo "CONFIG must be Debug, Release, \"Store Debug\" or \"Store Release\" (got '$CONFIG')" >&2; exit 2 ;;
esac
case "$CONFIG" in *Release) IS_RELEASE_CONFIG=1 ;; *) IS_RELEASE_CONFIG=0 ;; esac
if [ "$IS_STORE_CONFIG" = 1 ] && [ ! -f "$(dirname "${BASH_SOURCE[0]}")/../Config/Store.xcconfig" ]; then
  echo "CONFIG=\"$CONFIG\" needs Config/Store.xcconfig (git-ignored). Copy Config/Store.xcconfig.example and fill it in;" >&2
  echo "without it a Store configuration quietly builds a self-build." >&2
  exit 2
fi
# What the tests should find (CoreTests/BuildFlagsTests.swift reads it through TEST_RUNNER_PROMPTER_EXPECTED_BUILD).
if [ "$IS_STORE_CONFIG" = 1 ]; then EXPECTED_BUILD=store; else EXPECTED_BUILD=selfbuild; fi

# Prompter for Mac flavor for script builds: selfbuild (default: ad hoc, not sandboxed) or qa (ad hoc, sandboxed).
# The team-signed store flavor is built only by scripts/build-cloud.sh.
export MAC_FLAVOR="${MAC_FLAVOR:-selfbuild}"
case "$MAC_FLAVOR" in
  selfbuild|qa) ;;
  store) echo "MAC_FLAVOR=store is signed by a team: build it with scripts/build-cloud.sh (main checkout only)" >&2; exit 2 ;;
  *) echo "MAC_FLAVOR must be selfbuild or qa (got '$MAC_FLAVOR')" >&2; exit 2 ;;
esac

# Settings every script build passes to xcodebuild, whatever the configuration and whatever Config/Local.xcconfig or
# Config/Store.xcconfig say: no entitlements and no iCloud container (an app without the iCloud entitlement must never
# open one), and on the Mac an ad hoc signature with no team. So a script build in a Store configuration has the store
# code compiled in but is never team-signed. Only scripts/build-cloud.sh builds signed store apps.
UNSIGNED_SETTINGS=(PROMPTER_CLOUD_CONTAINER= PROMPTER_IOS_ENTITLEMENTS=)
MAC_UNSIGNED_SETTINGS=(PROMPTER_CLOUD_CONTAINER= PROMPTER_IOS_ENTITLEMENTS= PROMPTER_MAC_FLAVOR="$MAC_FLAVOR"
  PROMPTER_MAC_SIGN_IDENTITY=- PROMPTER_MAC_TEAM=)

# Where xcodebuild leaves the apps (relative to the repo root, which the scripts cd into). The Store folders have a space
# in their name ("Store Debug-iphonesimulator"), so always quote these.
IOS_APP_DEFAULT="build/DerivedData/Build/Products/${CONFIG}-iphonesimulator/Prompter.app"
MAC_APP_DEFAULT="build/DerivedData/Build/Products/${CONFIG}/Prompter.app"

# app_info <path to a built .app> <key>: a top-level Info.plist value, empty when the key is missing.
app_info() {
  local app="$1" key="$2" plist
  for plist in "$app/Info.plist" "$app/Contents/Info.plist"; do
    if [ -f "$plist" ]; then
      /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
      return 0
    fi
  done
  echo "No Info.plist in $app" >&2
  return 1
}

# app_has_switch <path to a built .app> <switch>: succeeds when the app's PrompterBuildFlags names the switch.
app_has_switch() {
  local flags
  flags="$(app_info "$1" PrompterBuildFlags)" || return 1
  case " $(echo $flags) " in *" $2 "*) return 0 ;; esac
  return 1
}

# check_script_build <path to a built .app>: the app is what this configuration should make, so a Store configuration that
# lost its switches, or a self-build that gained some, stops the script. A script build never names an iCloud container.
check_script_build() {
  local app="$1" flags container
  flags="$(app_info "$app" PrompterBuildFlags)" || return 1
  container="$(app_info "$app" PrompterCloudContainer)" || return 1
  flags="$(echo $flags)"
  if [ "$IS_STORE_CONFIG" = 1 ]; then
    if ! app_has_switch "$app" PROMPTER_STORE; then
      echo "$CONFIG built a self-build (PrompterBuildFlags is '$flags'): set PROMPTER_FLAGS in Config/Store.xcconfig" >&2
      return 1
    fi
  elif [ -n "$flags" ]; then
    echo "$CONFIG must be a self-build, but PrompterBuildFlags is '$flags' (is PROMPTER_FLAGS set in Config/Local.xcconfig?)" >&2
    return 1
  fi
  if [ -n "$(echo $container)" ]; then
    echo "A script build must not name an iCloud container, but $app has '$container'" >&2
    return 1
  fi
  echo "build kind OK: $CONFIG, switches '${flags:-none}', no iCloud container"
}

# check_archived_app <path to an archived .app> <configuration>: a "Store Release" archive must be a store build
# (PROMPTER_STORE in its PrompterBuildFlags) and a plain "Release" archive (REHEARSAL=1) a self-build. scripts/archive.sh
# runs it before the export.
check_archived_app() {
  local app="$1" config="$2" flags
  flags="$(app_info "$app" PrompterBuildFlags)" || return 1
  flags="$(echo $flags)"
  echo "archive: build switches in the archived app: '${flags:-none}'"
  case "$config" in
    "Store Release")
      app_has_switch "$app" PROMPTER_STORE && return 0
      echo "archive: the archived app is not a store build (no PROMPTER_STORE). Stopping before the export." >&2
      return 1 ;;
    Release)
      [ -z "$flags" ] && return 0
      echo "archive: REHEARSAL=1 expects a self-build, but the archived app has switches '$flags'. Stopping before the export." >&2
      return 1 ;;
    *)
      echo "archive: unknown configuration '$config'" >&2
      return 1 ;;
  esac
}

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

# --- iPhone Duo (the foldable) ---------------------------------------------------------------------------------------
# The Duo has two displays and no simctl verb for folding, so a posture is set by pressing Device Hub's buttons
# (scripts/duo-posture.sh) and what the window really is gets measured by launching the app with -duoProbe, which logs the
# window size, the real safe area and the size classes to Documents/duo-probe.log (Prompter/App/DuoProbe.swift).

# sim_is_duo <udid>: succeeds when the simulator is an iPhone Duo (by its name, like sim_is_ipad).
sim_is_duo() {
  xcrun simctl list devices available -j | UDID="$1" python3 -I -c '
import json, os, sys
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices:
        if d["udid"] == os.environ["UDID"]:
            sys.exit(0 if "Duo" in d["name"] else 1)
sys.exit(1)
'
}

# duo_probe <udid> <bundle id> [app args...]: launch the app with -duoProbe -demoData plus the args, give it a moment to lay
# out, and print the last window it logged as "<width> <height> <h-class> <safe left> <safe top>"
# (for example "466 678 compact 0 0"). Prints nothing when the app wrote no log, so callers must handle an empty answer.
# The app is terminated again afterwards.
duo_probe() {
  local udid="$1" app_id="$2" data line; shift 2
  xcrun simctl terminate "$udid" "$app_id" 2>/dev/null || true
  data="$(xcrun simctl get_app_container "$udid" "$app_id" data 2>/dev/null)" || return 0
  rm -f "$data/Documents/duo-probe.log"
  xcrun simctl launch "$udid" "$app_id" -duoProbe -demoData "$@" >/dev/null 2>&1 || return 0
  sleep "${DUO_PROBE_WAIT:-5}"
  line="$(grep -E '^[0-9:.]+ size ' "$data/Documents/duo-probe.log" 2>/dev/null | tail -1)"
  xcrun simctl terminate "$udid" "$app_id" 2>/dev/null || true
  [ -n "$line" ] || return 0
  echo "$line" | sed -nE 's/.* size ([0-9]+)x([0-9]+) · safe t([0-9.]+) l([0-9.]+) .* classes h:([a-z]+) .*/\1 \2 \5 \4 \3/p'
}

# duo_apply_posture <udid> <bundle id> <Closed|Open|OpenTall|ClosedLandscape|Book>: put the Duo in that posture and
# check it by measuring the window, because "Rotate Right" is cumulative and Device Hub does not say which way the
# simulator is turned. Closed = 466x678, ClosedLandscape = 678x466, Open = 951x669, OpenTall = 669x951 (Open, then a turn).
# Book = the Book button with the window wide like Open (951x669, the fold upright down the middle); the same button with the
# window tall is a fold across the screen (tabletop), which is not Book. Returns 1 when the window never matched.
duo_apply_posture() {
  local udid="$1" app_id="$2" want="$3" base shape probe w h tries=0
  case "$want" in
    Closed|ClosedLandscape) base=Closed ;;
    Open|OpenTall) base=Open ;;
    Book) base=Book ;;
    *) echo "unknown posture '$want'" >&2; return 1 ;;
  esac
  # Device Hub needs a moment to list a freshly booted simulator (and briefly shows a helper window or a second process
  # while it turns), so `select` is tried a few times before giving up.
  local sel=0
  until scripts/duo-posture.sh select >/dev/null 2>&1; do
    sel=$((sel + 1)); [ "$sel" -le 6 ] || { echo "Device Hub would not show the Duo (scripts/duo-posture.sh select kept failing)" >&2; return 1; }
    sleep 5
  done
  [ "$(scripts/duo-posture.sh state)" = "$base" ] || { scripts/duo-posture.sh "$base" >/dev/null || return 1; sleep 5; }
  while :; do
    probe="$(duo_probe "$udid" "$app_id" -route library)"
    read -r w h _ <<<"$probe"
    case "$want" in
      Closed)          [ -n "$w" ] && [ "$w" -lt 600 ] && [ "$w" -lt "$h" ] && return 0 ;;
      ClosedLandscape) [ -n "$w" ] && [ "$w" -lt 800 ] && [ "$w" -gt "$h" ] && return 0 ;;
      Open|Book)       [ -n "$w" ] && [ "$w" -gt 800 ] && [ "$w" -gt "$h" ] && return 0 ;;
      OpenTall)        [ -n "$w" ] && [ "$w" -gt 600 ] && [ "$w" -lt "$h" ] && return 0 ;;
    esac
    tries=$((tries + 1))
    [ "$tries" -le 4 ] || { echo "posture $want: the window stayed ${w:-unknown}x${h:-unknown} after $((tries - 1)) turns" >&2; return 1; }
    scripts/duo-posture.sh "Rotate Right" >/dev/null || return 1
    sleep 5
  done
}
