#!/usr/bin/env bash
# Archive Prompter (the iOS app with the watch app embedded) and export an .ipa for App Store Connect / TestFlight.
#
#   TEAM_ID=<your 10-character team ID> scripts/archive.sh
#
# This SIGNS the build, so it is run by the owner, never by an unattended session. It needs:
#   - TEAM_ID in the environment (your 10-character Apple Developer team ID; refuses to run without it),
#   - you signed in to Xcode with that team (Xcode > Settings > Accounts), because -allowProvisioningUpdates lets
#     xcodebuild create the App Store profiles for <BUNDLE_ID_PREFIX>.prompter and <BUNDLE_ID_PREFIX>.prompter.watchkitapp.
# Set DRY_RUN=1 to print the xcodebuild commands (and write build/ExportOptions.plist) without running them.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${TEAM_ID:-}" ]; then
  echo "archive: TEAM_ID is not set. Run it as:  TEAM_ID=<your team id> scripts/archive.sh" >&2
  exit 1
fi
if ! [[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "archive: TEAM_ID '$TEAM_ID' does not look like an Apple team ID (10 capital letters or digits)." >&2
  exit 1
fi

ARCHIVE=build/Prompter.xcarchive
EXPORT_DIR=build/export
EXPORT_OPTIONS=build/ExportOptions.plist

run() {
  if [ "${DRY_RUN:-}" = "1" ]; then
    printf '[dry run]'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

run xcodegen generate --quiet

VERSION=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([0-9.]+)"?.*/\1/p' project.yml | head -1)
BUILD=$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"?([0-9]+)"?.*/\1/p' project.yml | head -1)
echo "archive: Prompter $VERSION ($BUILD), team $TEAM_ID"
echo "archive: if App Store Connect already has build $BUILD of $VERSION, run scripts/bump-build.sh first."

# build/ may not exist yet (a fresh clone, or a dry run before any build): the export options are written into it below.
mkdir -p build
run rm -rf "$ARCHIVE" "$EXPORT_DIR" "$EXPORT_OPTIONS"

# 1. Archive (Release, generic iOS device; the watch app is built and embedded by the Prompter scheme).
run xcodebuild -project Prompter.xcodeproj -scheme Prompter -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/DerivedDataArchive \
  -archivePath "$ARCHIVE" -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" archive

if [ "${DRY_RUN:-}" != "1" ]; then
  APP="$ARCHIVE/Products/Applications/Prompter.app"
  [ -d "$APP/Watch/PrompterWatch.app" ] || { echo "archive: the watch app is missing from $APP/Watch. Stopping." >&2; exit 1; }
  PB=/usr/libexec/PlistBuddy
  version_of() { echo "$($PB -c 'Print :CFBundleShortVersionString' "$1") ($($PB -c 'Print :CFBundleVersion' "$1"))"; }
  PHONE_VERSION=$(version_of "$APP/Info.plist")
  WATCH_VERSION=$(version_of "$APP/Watch/PrompterWatch.app/Info.plist")
  echo "archive: phone app $($PB -c 'Print :CFBundleIdentifier' "$APP/Info.plist")  $PHONE_VERSION"
  echo "archive: watch app $($PB -c 'Print :CFBundleIdentifier' "$APP/Watch/PrompterWatch.app/Info.plist")  $WATCH_VERSION"
  if [ "$PHONE_VERSION" != "$WATCH_VERSION" ]; then
    echo "archive: the phone and watch versions differ, App Store Connect would reject this. Stopping." >&2
    exit 1
  fi
fi

# 2. Export options: the template has no team ID in it; it is written here at run time.
cp scripts/ExportOptions.plist "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c "Set :teamID $TEAM_ID" "$EXPORT_OPTIONS"

# 3. Export an App Store Connect .ipa (destination "export" = write it to disk, do not upload).
run xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS" -allowProvisioningUpdates

if [ "${DRY_RUN:-}" != "1" ]; then
  IPA="$EXPORT_DIR/Prompter.ipa"
  [ -f "$IPA" ] || { echo "archive: export finished but $IPA is missing. Look in $EXPORT_DIR." >&2; exit 1; }
  echo
  echo "archive: done. Built $IPA"
else
  echo
  echo "archive: dry run finished, nothing was archived."
fi

cat <<EOF

Next steps (full list: docs/testflight-checklist.md)
  Upload with Transporter:  open the Transporter app (Mac App Store), sign in, drag in build/export/Prompter.ipa, Deliver.
  Or with Xcode Organizer:  open $ARCHIVE   (Window > Organizer > Archives), Distribute App > TestFlight & App Store (older Xcodes: App Store Connect) > Distribute.
  Then in App Store Connect > TestFlight, wait for "Processing" to finish (5 to 30 minutes), add the build to your
  internal testing group, and install it from the TestFlight app on the iPhone. The watch app arrives through the
  Watch app on the iPhone.
  Next upload of the same version needs a new build number:  scripts/bump-build.sh
EOF
