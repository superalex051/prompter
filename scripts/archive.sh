#!/usr/bin/env bash
# Archive Prompter (the iOS app with the watch app embedded) and export an .ipa for App Store Connect / TestFlight.
#
#   TEAM_ID=<your 10-character team ID> scripts/archive.sh                the store build (Store Release)
#   REHEARSAL=1 TEAM_ID=<your 10-character team ID> scripts/archive.sh    the self-build (plain Release)
#
# By default it archives Store Release: Pro is sold through the App Store and iCloud is on, with the team, prefix and
# container from the git-ignored Config/Store.xcconfig (PROMPTER_STORE_RELEASE_*). It refuses to archive anything that is
# not a store build, so a self-build (Pro on for everyone, no iCloud) can't reach the App Store by mistake. REHEARSAL=1
# archives plain Release instead: the self-build, for an upload rehearsal or for sharing your own build with your testers
# through your own TestFlight. It is never the store app.
#
# This SIGNS the build, so it is run by the owner, never by an unattended session. It needs:
#   - TEAM_ID in the environment (your 10-character Apple Developer team ID; refuses to run without it). For a store build
#     it must be the team in PROMPTER_STORE_RELEASE_TEAM,
#   - you signed in to Xcode with that team (Xcode > Settings > Accounts), because -allowProvisioningUpdates lets
#     xcodebuild create the App Store profiles for <prefix>.prompter and <prefix>.prompter.watchkitapp.
# Set VALIDATE=1 to run scripts/validate-archive.sh on the .ipa after the export.
# Set DRY_RUN=1 to run the checks and print the xcodebuild commands (and write build/ExportOptions.plist) without running them.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

if [ -z "${TEAM_ID:-}" ]; then
  echo "archive: TEAM_ID is not set. Run it as:  TEAM_ID=<your team id> scripts/archive.sh" >&2
  exit 1
fi
if ! [[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "archive: TEAM_ID '$TEAM_ID' does not look like an Apple team ID (10 capital letters or digits)." >&2
  exit 1
fi

if [ "${REHEARSAL:-}" = "1" ]; then
  ARCHIVE_CONFIG=Release
  echo "archive: REHEARSAL=1, archiving the self-build (plain Release: Pro on, no iCloud). It is not the store app."
else
  ARCHIVE_CONFIG="Store Release"
fi

# setting_of <name>: a resolved build setting of the Prompter target in ARCHIVE_CONFIG (empty when unset).
setting_of() {
  xcodebuild -project Prompter.xcodeproj -target Prompter -configuration "$ARCHIVE_CONFIG" -showBuildSettings 2>/dev/null |
    awk -v k="$1" '$1 == k && $2 == "=" && !found { sub(/^[^=]*= ?/, ""); print; found = 1 }'
}

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

# Generated even in a dry run: the checks below read the project's build settings.
xcodegen generate --quiet

# A store archive: the switches and the Store Release values must be in Config/Store.xcconfig before anything is signed.
if [ "$ARCHIVE_CONFIG" = "Store Release" ]; then
  if [ ! -f Config/Store.xcconfig ]; then
    echo "archive: Config/Store.xcconfig is missing, so Store Release would be a self-build. Copy Config/Store.xcconfig.example" >&2
    echo "         and fill in the Store Release values, or set REHEARSAL=1 to archive the self-build." >&2
    exit 1
  fi
  flags="$(setting_of PROMPTER_FLAGS)"
  case " $flags " in
    *" PROMPTER_STORE "*) ;;
    *) echo "archive: Store Release has no PROMPTER_STORE switch (PROMPTER_FLAGS is '$flags'). Refusing." >&2; exit 1 ;;
  esac
  prefix="$(setting_of BUNDLE_ID_PREFIX)"
  case "$prefix" in
    ""|com.example|com.example.*|com.yourname|com.yourname.*)
      echo "archive: PROMPTER_STORE_RELEASE_PREFIX is '$prefix', a placeholder. Set the shipping prefix in Config/Store.xcconfig." >&2
      exit 1 ;;
  esac
  if [ "$(setting_of PROMPTER_STORE_TEAM)" != "$TEAM_ID" ]; then
    echo "archive: TEAM_ID is not the team in PROMPTER_STORE_RELEASE_TEAM (Config/Store.xcconfig). Refusing." >&2
    exit 1
  fi
  case " $flags " in
    *" PROMPTER_CLOUD "*)
      container="$(setting_of PROMPTER_CLOUD_CONTAINER)"
      case "$container" in
        *.yourname.*|*.example.*)
          echo "archive: PROMPTER_STORE_RELEASE_CONTAINER is '$container', a placeholder. Refusing." >&2; exit 1 ;;
        iCloud.?*) ;;
        *) echo "archive: iCloud is on but PROMPTER_STORE_RELEASE_CONTAINER is '$container'. Set the store container in Config/Store.xcconfig." >&2
           exit 1 ;;
      esac ;;
  esac
  echo "archive: store build, switches: $flags, bundle ID $(setting_of PRODUCT_BUNDLE_IDENTIFIER)"
fi

VERSION=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([0-9.]+)"?.*/\1/p' project.yml | head -1)
BUILD=$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"?([0-9]+)"?.*/\1/p' project.yml | head -1)
echo "archive: Prompter $VERSION ($BUILD), $ARCHIVE_CONFIG, team $TEAM_ID"
echo "archive: if App Store Connect already has build $BUILD of $VERSION, run scripts/bump-build.sh first."

# build/ may not exist yet (a fresh clone, or a dry run before any build): the export options are written into it below.
mkdir -p build
run rm -rf "$ARCHIVE" "$EXPORT_DIR" "$EXPORT_OPTIONS"

# 1. Archive (generic iOS device; the watch app is built and embedded by the Prompter scheme).
run xcodebuild -project Prompter.xcodeproj -scheme Prompter -configuration "$ARCHIVE_CONFIG" \
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
  # The archived app itself says what it is (PrompterBuildFlags). Only a store build goes on to the export, unless REHEARSAL=1.
  check_archived_app "$APP" "$ARCHIVE_CONFIG"
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
  # VALIDATE=1: check the .ipa with App Store Connect before you upload it (scripts/validate-archive.sh).
  if [ "${VALIDATE:-}" = "1" ]; then
    scripts/validate-archive.sh "$IPA"
  fi
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
