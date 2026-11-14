#!/usr/bin/env bash
# Run the Mac unit tests (PrompterMacTests, hosted by Prompter for Mac) on this Mac.
# CONFIG=Release (or "Store Release") runs them against a shipping configuration: testability stays on so the tests can see
# the app, and the hardened runtime is off so the ad hoc signed test bundle can load into the app.
# CONFIG="Store Debug" runs the store code (needs Config/Store.xcconfig) in the ad hoc selfbuild shell. MAC_FLAVOR=qa hosts
# the tests in the sandboxed qa flavor instead.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh
EXTRA=()
[ "$IS_RELEASE_CONFIG" = 1 ] && EXTRA+=(ENABLE_TESTABILITY=YES ENABLE_HARDENED_RUNTIME=NO)
xcodegen generate --quiet
TEST_RUNNER_PROMPTER_EXPECTED_BUILD="$EXPECTED_BUILD" \
xcodebuild -project Prompter.xcodeproj -scheme PrompterMac -configuration "$CONFIG" \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath build/DerivedData \
  -collect-test-diagnostics never "${MAC_UNSIGNED_SETTINGS[@]}" ${EXTRA[@]+"${EXTRA[@]}"} -quiet test
check_script_build "$MAC_APP_DEFAULT"
echo "mac tests OK ($CONFIG, $MAC_FLAVOR)"
