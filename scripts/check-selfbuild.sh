#!/usr/bin/env bash
# The free self-build gate. What someone gets from a fresh clone, with no Config/Local.xcconfig and no Config/Store.xcconfig
# (prefix com.example, no team), must still build, carry no entitlements and be a self-build: Pro on, no iCloud. Run it in
# every merge slot, through scripts/heavy.sh (it builds three times and boots a simulator):
#
#   scripts/heavy.sh --task <ID> -- scripts/check-selfbuild.sh
#   SIM="Prompter Dev iPad" scripts/check-selfbuild.sh     the hosted iOS test on another simulator (SIM_UDID works too)
#
# It copies the files git would commit (tracked and new, not ignored, local edits included; website/ left out) into
# build/selfbuild-check/src, so this checkout's own Local.xcconfig and Store.xcconfig can't leak in. Then:
#   1. build settings in all four configurations: bundle IDs, entitlements, Mac flavor. The watch app and the test targets
#      never get entitlements, and no watch code reads a store switch.
#   2. an unsigned iOS device build (Debug), as Xcode builds it for a free Personal Team: com.example IDs, the watch app
#      inside, no switches, no iCloud container, nothing signed.
#   3. the Mac build Xcode makes when you press Run (no settings passed): ad hoc, not sandboxed, and no entitlement except
#      the get-task-allow Xcode adds to every Debug build.
#   4. the Mac Release build scripts/deploy-mac.sh makes (its DEPLOY_BUILD_SETTINGS): no entitlements at all.
#   5. hosted tests on the iPhone simulator and on the Mac (BuildFlagsTests, CloudConfigurationTests), told to expect a
#      self-build: no switches, Pro on without a purchase, iCloud off.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
export CONFIG=Debug MAC_FLAVOR=selfbuild
. scripts/lib.sh

WORK="$REPO/build/selfbuild-check"
SRC="$WORK/src"
DD="$WORK/DerivedData"
LOGS="$WORK/logs"
ARCH="$(uname -m)"

step() { echo; echo "== $*"; }
fail() { echo "check-selfbuild: FAIL: $*" >&2; exit 1; }
blank() { [ -z "$(echo $1)" ]; }

# --- The clean copy ---
step "Copying the files git would commit into $SRC"
rm -rf "$SRC" "$LOGS"
mkdir -p "$SRC" "$LOGS"
while IFS= read -r -d '' f; do
  case "$f" in website/*) continue ;; esac
  [ -f "$f" ] && printf '%s\0' "$f"
done < <(git ls-files -z --cached --others --exclude-standard) | tar -c --null -T - -f - | tar -x -f - -C "$SRC"
for private in Config/Local.xcconfig Config/Store.xcconfig; do
  [ ! -e "$SRC/$private" ] || fail "$private was copied into the clean tree"
done
(cd "$SRC" && xcodegen generate --quiet)
echo "copied $(find "$SRC" -type f | wc -l | tr -d ' ') files; no Local.xcconfig, no Store.xcconfig"

# --- 1. Build settings ---
step "1. Build settings in Debug, Release, Store Debug and Store Release"
(cd "$SRC" && for config in Debug Release "Store Debug" "Store Release"; do
  xcodebuild -project Prompter.xcodeproj -alltargets -configuration "$config" -showBuildSettings -json 2>/dev/null |
    CONFIG_NAME="$config" python3 -I -c 'import json, os, sys; print(json.dumps({"config": os.environ["CONFIG_NAME"], "targets": json.load(sys.stdin)}))'
done) > "$LOGS/settings.jsonl"
python3 -I - "$LOGS/settings.jsonl" <<'PY'
import json, sys
problems = []
for line in open(sys.argv[1]):
    entry = json.loads(line)
    config, store = entry["config"], entry["config"].startswith("Store")
    targets = {t["target"]: t["buildSettings"] for t in entry["targets"]}
    def get(target, key): return targets[target].get(key, "").strip()
    def expect(target, key, want):
        got = get(target, key)
        if got != want: problems.append(f"{config} {target} {key} is {got!r}, expected {want!r}")
    app_id = {"Debug": "com.example.prompter", "Release": "com.example.prompter",
              "Store Debug": "com.example.prompter.dev", "Store Release": "com.example.prompter"}[config]
    expect("Prompter", "PRODUCT_BUNDLE_IDENTIFIER", app_id)
    expect("PrompterWatch", "PRODUCT_BUNDLE_IDENTIFIER", app_id + ".watchkitapp")
    expect("Prompter", "CODE_SIGN_ENTITLEMENTS", "Config/Entitlements/Prompter.entitlements" if store else "")
    for target in ("PrompterWatch", "PrompterTests", "PrompterMacTests"):
        expect(target, "CODE_SIGN_ENTITLEMENTS", "")
    if store:
        expect("PrompterMac", "PRODUCT_BUNDLE_IDENTIFIER", app_id)
        expect("PrompterMac", "CODE_SIGN_ENTITLEMENTS", "Config/Entitlements/PrompterMac.entitlements")
        expect("PrompterMac", "ENABLE_APP_SANDBOX", "YES")
        expect("PrompterMac", "CODE_SIGN_IDENTITY", "Apple Development")
    else:
        expect("PrompterMac", "PRODUCT_BUNDLE_IDENTIFIER", "com.example.prompter.mac")
        expect("PrompterMac", "CODE_SIGN_ENTITLEMENTS", "")
        expect("PrompterMac", "ENABLE_APP_SANDBOX", "NO")
        expect("PrompterMac", "CODE_SIGN_IDENTITY", "-")
        expect("PrompterMac", "DEVELOPMENT_TEAM", "")
        expect("PrompterMacTests", "CODE_SIGN_IDENTITY", "-")
    # No Config/Store.xcconfig here, so no configuration has a switch or a container.
    for target, settings in targets.items():
        conditions = settings.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "")
        if "PROMPTER_" in conditions: problems.append(f"{config} {target} has switches without Store.xcconfig: {conditions!r}")
        if settings.get("PROMPTER_CLOUD_CONTAINER", "").strip():
            problems.append(f"{config} {target} names an iCloud container without Store.xcconfig")
    print(f"  {config}: {app_id}, Mac {get('PrompterMac', 'PRODUCT_BUNDLE_IDENTIFIER')}"
          f" (sandbox {get('PrompterMac', 'ENABLE_APP_SANDBOX')}), entitlements only on"
          f" {', '.join(t for t in ('Prompter', 'PrompterMac') if get(t, 'CODE_SIGN_ENTITLEMENTS')) or 'nothing'}")
if problems:
    print("\n".join("  " + p for p in problems), file=sys.stderr)
    sys.exit(1)
PY
if grep -rn -e PROMPTER_STORE -e PROMPTER_CLOUD "$SRC/PrompterWatch" "$SRC/Shared" >/dev/null; then
  grep -rn -e PROMPTER_STORE -e PROMPTER_CLOUD "$SRC/PrompterWatch" "$SRC/Shared" >&2
  fail "watch code reads a store switch (the watch app must be the same in every configuration)"
fi
echo "  the watch app and the test targets carry no entitlements; no watch code reads a store switch"

# --- 2. Unsigned iOS device build ---
step "2. Unsigned iOS device build (Debug)"
(cd "$SRC" && xcodebuild -project Prompter.xcodeproj -scheme Prompter -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO -quiet build)
APP="$DD/Build/Products/Debug-iphoneos/Prompter.app"
WAPP="$APP/Watch/PrompterWatch.app"
[ -d "$WAPP" ] || fail "no watch app inside $APP"
[ "$(app_bundle_id "$APP")" = com.example.prompter ] || fail "iPhone app is $(app_bundle_id "$APP")"
[ "$(app_bundle_id "$WAPP")" = com.example.prompter.watchkitapp ] || fail "watch app is $(app_bundle_id "$WAPP")"
[ "$(app_info "$WAPP" WKCompanionAppBundleIdentifier)" = com.example.prompter ] || fail "watch app's companion is not com.example.prompter"
blank "$(app_info "$APP" PrompterBuildFlags)" || fail "iPhone app has switches: $(app_info "$APP" PrompterBuildFlags)"
blank "$(app_info "$APP" PrompterCloudContainer)" || fail "iPhone app names an iCloud container"
for bundle in "$APP" "$WAPP"; do
  if codesign -d "$bundle" >/dev/null 2>&1; then fail "$bundle is signed"; fi
  [ ! -e "$bundle/embedded.mobileprovision" ] || fail "$bundle has a provisioning profile"
done
echo "  com.example.prompter with com.example.prompter.watchkitapp inside; no switches, no container, unsigned"

# --- 3. Mac build as Xcode's Run makes it ---
step "3. Mac Debug build with no settings passed (Xcode's Run)"
(cd "$SRC" && xcodebuild -project Prompter.xcodeproj -scheme PrompterMac -configuration Debug \
  -destination "platform=macOS,arch=$ARCH" -derivedDataPath "$DD" -quiet build)
MAC="$DD/Build/Products/Debug/Prompter.app"
# entitlement_keys <app>: the keys of its signed entitlements, one per line (nothing when it has none).
entitlement_keys() {
  codesign -d --entitlements - --xml "$1" 2>/dev/null |
    python3 -I -c 'import plistlib, sys; d = sys.stdin.buffer.read(); [print(k) for k in (plistlib.loads(d) if d.strip() else {})]'
}
check_mac() {
  local app="$1" allowed="$2" keys extra
  [ "$(app_bundle_id "$app")" = com.example.prompter.mac ] || fail "$app is $(app_bundle_id "$app")"
  blank "$(app_info "$app" PrompterBuildFlags)" || fail "$app has switches: $(app_info "$app" PrompterBuildFlags)"
  blank "$(app_info "$app" PrompterCloudContainer)" || fail "$app names an iCloud container"
  codesign -dv "$app" 2>&1 | grep -q '^Signature=adhoc' || fail "$app is not signed ad hoc"
  codesign -dv "$app" 2>&1 | grep -q '^TeamIdentifier=not set' || fail "$app is signed with a team"
  keys="$(entitlement_keys "$app")"
  extra="$(printf '%s\n' "$keys" | grep -v -x -e '' ${allowed:+-e "$allowed"} || true)"
  [ -z "$extra" ] || fail "$app carries entitlements: $(echo $extra)"
  echo "  $(app_bundle_id "$app"), ad hoc, no team, entitlements: $(echo ${keys:-none})"
}
check_mac "$MAC" com.apple.security.get-task-allow

# --- 4. The deploy-mac.sh build ---
step "4. Mac Release build with scripts/deploy-mac.sh's settings"
line="$(grep -E '^DEPLOY_BUILD_SETTINGS=\(' "$SRC/scripts/deploy-mac.sh")" || fail "no DEPLOY_BUILD_SETTINGS line in scripts/deploy-mac.sh"
eval "$line"
echo "  settings: ${DEPLOY_BUILD_SETTINGS[*]}"
case " ${DEPLOY_BUILD_SETTINGS[*]} " in *" -configuration Release "*) ;; *) fail "scripts/deploy-mac.sh does not build plain Release" ;; esac
(cd "$SRC" && xcodebuild -project Prompter.xcodeproj -scheme PrompterMac "${DEPLOY_BUILD_SETTINGS[@]}" \
  -destination "generic/platform=macOS" -derivedDataPath "$DD" -quiet build)
check_mac "$DD/Build/Products/Release/Prompter.app" ""

# --- 5. Hosted tests that expect a self-build ---
step "5. Hosted tests, told to expect a self-build"
UDID="${SIM_UDID:-$(sim_udid "${SIM:-Prompter Dev iPhone}" iOS)}" || exit 1
# ran_as_selfbuild <log>: the self-build test ran and saw the expectation (the line BuildFlagsTests prints).
ran_as_selfbuild() { grep -F "BuildFlagsTests: expected build 'selfbuild', switches []" "$1" >/dev/null; }
if ! (cd "$SRC" && TEST_RUNNER_PROMPTER_EXPECTED_BUILD=selfbuild xcodebuild -project Prompter.xcodeproj -scheme Prompter \
    -configuration Debug -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DD" \
    -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO \
    -only-testing:PrompterTests/BuildFlagsTests -only-testing:PrompterTests/CloudConfigurationTests test) > "$LOGS/ios-test.log" 2>&1; then
  tail -40 "$LOGS/ios-test.log" >&2; fail "iOS hosted tests failed (log: $LOGS/ios-test.log)"
fi
ran_as_selfbuild "$LOGS/ios-test.log" || fail "the iOS self-build test did not run or did not see PROMPTER_EXPECTED_BUILD (log: $LOGS/ios-test.log)"
echo "  iPhone simulator $UDID: BuildFlagsTests and CloudConfigurationTests passed as a self-build"
if ! (cd "$SRC" && TEST_RUNNER_PROMPTER_EXPECTED_BUILD=selfbuild xcodebuild -project Prompter.xcodeproj -scheme PrompterMac \
    -configuration Debug -destination "platform=macOS,arch=$ARCH" -derivedDataPath "$DD" \
    -collect-test-diagnostics never -only-testing:PrompterMacTests/BuildFlagsTests test) > "$LOGS/mac-test.log" 2>&1; then
  tail -40 "$LOGS/mac-test.log" >&2; fail "Mac hosted tests failed (log: $LOGS/mac-test.log)"
fi
ran_as_selfbuild "$LOGS/mac-test.log" || fail "the Mac self-build test did not run or did not see PROMPTER_EXPECTED_BUILD (log: $LOGS/mac-test.log)"
echo "  Mac: BuildFlagsTests passed as a self-build"

echo
echo "check-selfbuild: OK. A fresh clone builds for iPhone and Mac with no entitlements, and it is a self-build (Pro on, no iCloud)."
