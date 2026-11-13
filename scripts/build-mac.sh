#!/usr/bin/env bash
# Build Prompter for Mac into build/DerivedData. Signed "to run locally" (ad hoc), so no Apple account is needed.
# The app lands at build/DerivedData/Build/Products/<CONFIG>/Prompter.app (CONFIG=Release for the shipping configuration).
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh
xcodegen generate --quiet
xcodebuild -project Prompter.xcodeproj -scheme PrompterMac -configuration "$CONFIG" \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath build/DerivedData -quiet build
echo "mac build OK ($CONFIG)"
