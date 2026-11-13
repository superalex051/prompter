#!/usr/bin/env bash
# Run unit tests on the dedicated "Prompter Dev iPhone" simulator.
#   SIM="Prompter Dev iPad" scripts/test.sh     another simulator, by exact name
#   SIM_UDID=<udid> scripts/test.sh             a simulator picked by hand
#   CONFIG=Release scripts/test.sh              the shipping configuration (testability stays on so the tests can see the app)
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh
SIM="${SIM:-Prompter Dev iPhone}"
UDID="${SIM_UDID:-$(sim_udid "$SIM" iOS)}"
EXTRA=()
[ "$CONFIG" = "Release" ] && EXTRA+=(ENABLE_TESTABILITY=YES)
xcodegen generate --quiet
xcodebuild -project Prompter.xcodeproj -scheme Prompter -configuration "$CONFIG" \
  -destination "platform=iOS Simulator,id=${UDID}" -derivedDataPath build/DerivedData \
  -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO ${EXTRA[@]+"${EXTRA[@]}"} -quiet test
echo "tests OK ($CONFIG)"
