#!/usr/bin/env bash
# Build the signed Store Debug apps: the dev identity <prefix>.prompter.dev with iCloud (the dev container and key-value
# store), for the iCloud checks on simulators, devices and this Mac.
#
#   scripts/build-cloud.sh ios <UDID>    the iPhone and iPad app (watch app embedded) for one simulator or device
#   scripts/build-cloud.sh mac           Prompter for Mac, store flavor (team-signed, sandboxed)
#
# This SIGNS with the team in Config/Store.xcconfig (PROMPTER_STORE_DEBUG_*) and lets Xcode register the App IDs, the iCloud
# container and devices (-allowProvisioningUpdates -allowProvisioningDeviceRegistration). An iCloud container can never be
# deleted, so you confirm its name first: CONFIRM_CONTAINER=<container> scripts/build-cloud.sh ...
# It runs only in the main checkout, by the owner, never in a builder's worktree. DRY_RUN=1 checks the settings and prints
# the build command without building or signing (allowed anywhere).
#
# Order: run `mac` (or `ios` with a real device) first. Those builds get a provisioning profile, which registers the App ID
# and creates the container. A simulator build needs no profile, so it may register nothing: run it on its own and the
# simulator app names a container that does not exist yet.
#
# The store-flavor Mac app has no network entitlements yet (they come with MAC-02b), so its sandbox blocks the Bonjour sync
# listener: Mac sync with an iPhone is expected to fail in this build. iCloud is what it is for.
#
# Output goes to build/CloudDerivedData, apart from the unsigned script builds in build/DerivedData. At the end it prints
# each app's iCloud entitlements (team ID masked) and fails when the container or the key-value store is missing or a "$("
# was left unexpanded. A Mac or device app keeps them in its code signature. A simulator app keeps them in its binary
# (the __TEXT,__entitlements section), because its signature is ad hoc and close to empty.
set -euo pipefail
cd "$(dirname "$0")/.."
export CONFIG="Store Debug"
. scripts/lib.sh

usage() { echo "usage: scripts/build-cloud.sh ios <simulator or device UDID> | mac" >&2; exit 2; }
PLATFORM="${1:-}"
case "$PLATFORM" in
  ios) UDID="${2:-}"; [ -n "$UDID" ] || usage; TARGET=Prompter; SCHEME=Prompter; DEST="id=$UDID" ;;
  mac) TARGET=PrompterMac; SCHEME=PrompterMac; DEST="platform=macOS,arch=$(uname -m)" ;;
  *) usage ;;
esac
DD=build/CloudDerivedData

# Main checkout only: a linked worktree has its own git dir under the main one's.
git_dir="$(git rev-parse --path-format=absolute --git-dir)"
common_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
if [ "$git_dir" != "$common_dir" ] && [ "${DRY_RUN:-}" != "1" ]; then
  echo "build-cloud: this signs with the store team, so it runs only in the main checkout, never in a worktree." >&2
  echo "             (DRY_RUN=1 checks the settings anywhere.)" >&2
  exit 2
fi

xcodegen generate --quiet

SETTINGS="$(xcodebuild -project Prompter.xcodeproj -target "$TARGET" -configuration "$CONFIG" -showBuildSettings 2>/dev/null)"
setting_of() { printf '%s\n' "$SETTINGS" | awk -v k="$1" '$1 == k && $2 == "=" && !found { sub(/^[^=]*= ?/, ""); print; found = 1 }'; }

flags="$(setting_of PROMPTER_FLAGS)"
team="$(setting_of PROMPTER_STORE_TEAM)"
prefix="$(setting_of BUNDLE_ID_PREFIX)"
container="$(setting_of PROMPTER_CLOUD_CONTAINER)"
ship_container="$(setting_of PROMPTER_STORE_RELEASE_CONTAINER)"
bundle_id="$(setting_of PRODUCT_BUNDLE_IDENTIFIER)"
entitlements="$(setting_of CODE_SIGN_ENTITLEMENTS)"
problems=()
case " $flags " in *" PROMPTER_STORE "*) ;; *) problems+=("PROMPTER_FLAGS has no PROMPTER_STORE ('$flags')") ;; esac
case " $flags " in *" PROMPTER_CLOUD "*) ;; *) problems+=("PROMPTER_FLAGS has no PROMPTER_CLOUD ('$flags')") ;; esac
if [ -z "$team" ] || [ "$team" = ABCDE12345 ]; then problems+=("PROMPTER_STORE_DEBUG_TEAM is empty or the placeholder"); fi
case "$prefix" in ""|com.example|com.example.*|com.yourname|com.yourname.*)
  problems+=("PROMPTER_STORE_DEBUG_PREFIX is '$prefix', a placeholder") ;; esac
case "$container" in
  *.yourname.*|*.example.*) problems+=("PROMPTER_STORE_DEBUG_CONTAINER is '$container', a placeholder") ;;
  iCloud.?*) ;;
  *) problems+=("PROMPTER_STORE_DEBUG_CONTAINER is '$container', not an iCloud container ID") ;;
esac
if [ -n "$container" ] && [ "$container" = "$ship_container" ]; then
  problems+=("the dev container is the shipping container ($container): test builds must never write there")
fi
case "$bundle_id" in *.prompter.dev) ;; *) problems+=("the bundle ID is '$bundle_id', not the dev identity <prefix>.prompter.dev") ;; esac
[ -n "$entitlements" ] || problems+=("$TARGET has no entitlements file in Store Debug")
if [ ${#problems[@]} -gt 0 ]; then
  echo "build-cloud: Config/Store.xcconfig is not ready for a signed Store Debug build:" >&2
  printf '  - %s\n' "${problems[@]}" >&2
  exit 1
fi
echo "build-cloud: $TARGET as $bundle_id, container $container, team set, switches: $flags"

if [ "${CONFIRM_CONTAINER:-}" != "$container" ]; then
  if [ "${DRY_RUN:-}" = "1" ]; then
    echo "build-cloud: a real run needs CONFIRM_CONTAINER=$container (the container is permanent once created)."
  else
    echo "build-cloud: this build uses, and on first use creates, the iCloud container $container. It can never be deleted." >&2
    echo "             If that name is right, run again with CONFIRM_CONTAINER=$container" >&2
    exit 3
  fi
fi

BUILD=(xcodebuild -project Prompter.xcodeproj -scheme "$SCHEME" -configuration "$CONFIG" -destination "$DEST"
  -derivedDataPath "$DD" -allowProvisioningUpdates -allowProvisioningDeviceRegistration build)
if [ "${DRY_RUN:-}" = "1" ]; then
  printf '[dry run]'; printf ' %q' "${BUILD[@]}"; printf '\n'
  echo "build-cloud: dry run finished, nothing was built or signed."
  exit 0
fi
"${BUILD[@]}"

SIMULATOR=0
if [ "$PLATFORM" = mac ]; then
  APP="$DD/Build/Products/$CONFIG/Prompter.app"
elif [ -d "$DD/Build/Products/$CONFIG-iphonesimulator/Prompter.app" ] && grep -qF "$UDID" <<<"$(xcrun simctl list devices)"; then
  APP="$DD/Build/Products/$CONFIG-iphonesimulator/Prompter.app"
  SIMULATOR=1
else
  APP="$DD/Build/Products/$CONFIG-iphoneos/Prompter.app"
fi
[ -d "$APP" ] || { echo "build-cloud: the build finished but $APP is missing" >&2; exit 1; }

# xml_plist <file>: a plist file as XML (it may be binary), or nothing when the file is empty or not a plist.
xml_plist() { [ -s "$1" ] && plutil -convert xml1 -o - "$1" 2>/dev/null || true; }

# section_entitlements <Mach-O file>: the __TEXT,__entitlements section as XML (nothing when there is none). segedit
# copies it byte for byte but reads one architecture only, so a universal file is thinned to this Mac's first.
# (otool -s is no use here: on arm64 it prints the bytes as swapped 4-byte words.)
section_entitlements() {
  local bin="$1" tmp thin
  tmp="$(mktemp -d)"
  thin="$bin"
  if [ "$(lipo -archs "$bin" 2>/dev/null | wc -w | tr -d ' ')" -gt 1 ]; then
    lipo "$bin" -thin "$(uname -m)" -output "$tmp/thin" 2>/dev/null && thin="$tmp/thin"
  fi
  if xcrun segedit "$thin" -extract __TEXT __entitlements "$tmp/ent" >/dev/null 2>&1; then xml_plist "$tmp/ent"; fi
  rm -rf "$tmp"
}

# read_entitlements <app>: sets ENT to its entitlements as XML, from wherever this kind of build keeps them, and
# ENT_SOURCE to where that was (or every place it looked).
read_entitlements() {
  local app="$1" exe bin xcent looked=""
  ENT="" ENT_SOURCE=""
  if [ "$SIMULATOR" = 0 ]; then
    ENT="$(codesign -d --entitlements - --xml "$app" 2>/dev/null || true)"
    ENT_SOURCE="the code signature"
    return 0
  fi
  # The simulator: the main binary, or with Xcode's debug dylib the small launcher and Prompter.debug.dylib beside it.
  exe="$(app_info "$app" CFBundleExecutable)"
  for bin in "$app/${exe:-Prompter}" "$app/${exe:-Prompter}.debug.dylib"; do
    [ -f "$bin" ] || continue
    ENT="$(section_entitlements "$bin")"
    if [ -n "$ENT" ]; then ENT_SOURCE="the __TEXT,__entitlements section of $bin"; return 0; fi
    looked="$looked the __TEXT,__entitlements section of $bin;"
  done
  # Last resort: the file Xcode embeds, still in the build's intermediates.
  xcent="$({ find "$DD/Build/Intermediates.noindex" -path "*/$CONFIG-iphonesimulator/*" -name 'Prompter.app-Simulated.xcent' 2>/dev/null || true; } | head -1)"
  if [ -n "$xcent" ]; then
    ENT="$(xml_plist "$xcent")"
    if [ -n "$ENT" ]; then ENT_SOURCE="$xcent, because the binary had no entitlements section"; return 0; fi
  fi
  ENT_SOURCE="nowhere. Looked in:$looked ${xcent:-no Prompter.app-Simulated.xcent under $DD/Build/Intermediates.noindex}"
}

# The entitlements must hold the real container and key-value store, with nothing left unexpanded.
read_entitlements "$APP"
masked() { printf '%s' "$1" | sed "s/$team/<team>/g"; }
bad=0
if [ -z "$ENT" ]; then echo "build-cloud: $APP has no entitlements (read from $ENT_SOURCE)" >&2; bad=1; fi
case "$ENT" in *'$('*) echo "build-cloud: an entitlement still holds an unexpanded \$( setting" >&2; bad=1 ;; esac
case "$ENT" in *"<string>$container</string>"*) ;; *) echo "build-cloud: the container $container is not in the entitlements" >&2; bad=1 ;; esac
case "$ENT" in *"<string>$team.$bundle_id</string>"*) ;; *) echo "build-cloud: the key-value store <team>.$bundle_id is not in the entitlements" >&2; bad=1 ;; esac
echo "build-cloud: entitlements of $APP, read from $(masked "$ENT_SOURCE"):"
masked "$(printf '%s' "$ENT" | plutil -p - 2>/dev/null || printf '%s' "$ENT")"; echo
[ "$bad" = 0 ] || exit 1
echo "build-cloud: OK, $APP"
