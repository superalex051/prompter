#!/usr/bin/env bash
# Run unit tests on the dedicated "Prompter Dev iPhone" simulator.
#   SIM="Prompter Dev iPad" scripts/test.sh     another simulator, by exact name
#   SIM_UDID=<udid> scripts/test.sh             a simulator picked by hand
#   CONFIG=Release scripts/test.sh              the shipping configuration (testability stays on so the tests can see the app)
#   CONFIG="Store Debug" scripts/test.sh        the store code (needs Config/Store.xcconfig; unsigned, no iCloud container)
# BuildFlagsTests checks the build is the kind this configuration should make (TEST_RUNNER_PROMPTER_EXPECTED_BUILD).
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh
SIM="${SIM:-Prompter Dev iPhone}"
UDID="${SIM_UDID:-$(sim_udid "$SIM" iOS)}"
EXTRA=()
[ "$IS_RELEASE_CONFIG" = 1 ] && EXTRA+=(ENABLE_TESTABILITY=YES)
xcodegen generate --quiet
TEST_RUNNER_PROMPTER_EXPECTED_BUILD="$EXPECTED_BUILD" \
xcodebuild -project Prompter.xcodeproj -scheme Prompter -configuration "$CONFIG" \
  -destination "platform=iOS Simulator,id=${UDID}" -derivedDataPath build/DerivedData \
  -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO "${UNSIGNED_SETTINGS[@]}" ${EXTRA[@]+"${EXTRA[@]}"} -quiet test
check_script_build "$IOS_APP_DEFAULT"
echo "tests OK ($CONFIG)"
