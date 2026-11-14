#!/usr/bin/env bash
# Build the iOS app (which embeds the watch app) for the simulator, without code signing.
# CONFIG=Release scripts/build.sh builds the shipping configuration (the app lands in Release-iphonesimulator).
# CONFIG="Store Debug" or "Store Release" builds the store code (needs Config/Store.xcconfig), still unsigned and with no
# iCloud container (see UNSIGNED_SETTINGS in scripts/lib.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh
xcodegen generate --quiet
xcodebuild -project Prompter.xcodeproj -scheme Prompter -configuration "$CONFIG" \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO "${UNSIGNED_SETTINGS[@]}" -quiet build
check_script_build "$IOS_APP_DEFAULT"
echo "build OK ($CONFIG)"
