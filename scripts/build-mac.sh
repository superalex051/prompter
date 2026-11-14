#!/usr/bin/env bash
# Build Prompter for Mac into build/DerivedData. Signed "to run locally" (ad hoc), so no Apple account is needed.
# The app lands at build/DerivedData/Build/Products/<CONFIG>/Prompter.app (CONFIG=Release for the shipping configuration).
#   MAC_FLAVOR=qa scripts/build-mac.sh          the sandboxed ad hoc flavor (<prefix>.prompter.mac.qa) instead of selfbuild
#   CONFIG="Store Debug" scripts/build-mac.sh   the store code in the same ad hoc shell (needs Config/Store.xcconfig)
# A script build is never team-signed and never carries iCloud entitlements: scripts/build-cloud.sh makes those.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh
xcodegen generate --quiet
xcodebuild -project Prompter.xcodeproj -scheme PrompterMac -configuration "$CONFIG" \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath build/DerivedData \
  "${MAC_UNSIGNED_SETTINGS[@]}" -quiet build
check_script_build "$MAC_APP_DEFAULT"
echo "mac build OK ($CONFIG, $MAC_FLAVOR)"
