#!/usr/bin/env bash
# Increment CURRENT_PROJECT_VERSION (the build number, shared by the phone and watch apps) in project.yml and print the new number.
# Run before every TestFlight upload: App Store Connect rejects a build number it has already seen for the same version.
#   scripts/bump-build.sh              # edits ./project.yml
#   scripts/bump-build.sh path/to.yml  # edits another file (used to test the script)
# Only the new number goes to stdout, so `NEW=$(scripts/bump-build.sh)` works. Messages go to stderr.
set -euo pipefail
cd "$(dirname "$0")/.."
FILE="${1:-project.yml}"

[ -f "$FILE" ] || { echo "bump-build: $FILE not found" >&2; exit 1; }

# Exactly one `CURRENT_PROJECT_VERSION: "<digits>"` line is expected (it lives in settings.base and is shared by every target).
PATTERN='^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"?[0-9]+"?'
COUNT=$(grep -cE "$PATTERN" "$FILE" || true)
if [ "$COUNT" != "1" ]; then
  echo "bump-build: expected one CURRENT_PROJECT_VERSION line in $FILE, found $COUNT. Not changing anything." >&2
  exit 1
fi

OLD=$(grep -E "$PATTERN" "$FILE" | sed -E 's/^[^0-9]*([0-9]+).*$/\1/')
NEW=$((OLD + 1))

TMP=$(mktemp -t bump-build)
trap 'rm -f "$TMP"' EXIT
# Replace only the number (keeps the quotes and the trailing comment as they are).
sed -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*\"?)[0-9]+(\"?)/\1${NEW}\2/" "$FILE" > "$TMP"
cat "$TMP" > "$FILE"   # keeps the file's mode and ownership

echo "bump-build: build $OLD -> $NEW in $FILE (run xcodegen generate, or any scripts/*.sh, to apply it)" >&2
echo "$NEW"
