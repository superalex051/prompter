#!/usr/bin/env bash
# Build the iOS app (which embeds the watch app) for the simulator, without code signing.
# CONFIG=Release scripts/build.sh builds the shipping configuration (the app lands in Release-iphonesimulator).
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh
xcodegen generate --quiet
xcodebuild -project Prompter.xcodeproj -scheme Prompter -configuration "$CONFIG" \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO -quiet build
echo "build OK ($CONFIG)"
