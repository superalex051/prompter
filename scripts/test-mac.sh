#!/usr/bin/env bash
# Run the Mac unit tests (PrompterMacTests, hosted by Prompter for Mac) on this Mac.
# CONFIG=Release runs them against the shipping configuration: testability stays on so the tests can see the app, and the
# hardened runtime is off so the ad hoc signed test bundle can load into the app.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh
EXTRA=()
[ "$CONFIG" = "Release" ] && EXTRA+=(ENABLE_TESTABILITY=YES ENABLE_HARDENED_RUNTIME=NO)
xcodegen generate --quiet
xcodebuild -project Prompter.xcodeproj -scheme PrompterMac -configuration "$CONFIG" \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath build/DerivedData \
  -collect-test-diagnostics never ${EXTRA[@]+"${EXTRA[@]}"} -quiet test
echo "mac tests OK ($CONFIG)"
