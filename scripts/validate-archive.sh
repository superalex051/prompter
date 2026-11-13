#!/usr/bin/env bash
# Validate an exported build with App Store Connect before uploading it (catches most ITMS rejections without sending anything).
#
#   scripts/validate-archive.sh [path/to/Prompter.ipa]     default: build/export/Prompter.ipa
#   scripts/validate-archive.sh --self-test
#
# Steps:
#   1. runs scripts/preflight.sh with STORE=1 on the archived app (skip with SKIP_PREFLIGHT=1),
#   2. runs `xcrun altool --validate-app` using an App Store Connect API key.
# The key is read by altool itself from ~/.private_keys/AuthKey_<ASC_KEY_ID>.p8 (or ./private_keys, ~/private_keys). This script
# never reads, prints or copies the key file. Set in your own terminal:
#   export ASC_KEY_ID=<key id>  ASC_ISSUER_ID=<issuer id>
#
# Exit codes: 0 validated, 1 validation or preflight failed, 2 usage error,
#   3 could not validate automatically (altool missing, or no API key settings). The Organizer steps are printed instead;
#   a caller that wants to continue after a manual validation can treat 3 as "do it by hand".
# DRY_RUN=1 prints the altool command instead of running it.
set -uo pipefail
cd "$(dirname "$0")/.."

organizer_steps() {
  cat <<'TXT'

Validate by hand in Xcode instead:
  1. open build/Prompter.xcarchive   (Xcode opens the Organizer on the Archives tab)
  2. Validate App, pick the same team, and leave the defaults on
  3. fix anything it lists, bump the build number (scripts/bump-build.sh), archive again
TXT
}

self_test() {
  local tmp rc=0 fails=0 out me
  me="$PWD/scripts/validate-archive.sh"
  tmp=$(mktemp -d)
  mkdir -p "$tmp/bin"
  printf 'fake ipa\n' > "$tmp/Prompter.ipa"
  # a fake xcrun that cannot find altool
  printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/xcrun"; chmod +x "$tmp/bin/xcrun"
  out=$(SKIP_PREFLIGHT=1 PATH="$tmp/bin:$PATH" bash "$me" "$tmp/Prompter.ipa" 2>&1); rc=$?
  if [ "$rc" = 3 ] && printf '%s' "$out" | grep -q 'Validate by hand'; then echo "ok   altool missing: exit 3 and Organizer steps printed"; else echo "FAIL altool missing (rc $rc)"; fails=$((fails + 1)); fi
  # a fake xcrun that finds altool, no key settings
  printf '#!/bin/sh\n[ "$1" = "--find" ] && { echo /bin/echo; exit 0; }\nexit 0\n' > "$tmp/bin/xcrun"
  out=$(SKIP_PREFLIGHT=1 ASC_KEY_ID= ASC_ISSUER_ID= PATH="$tmp/bin:$PATH" bash "$me" "$tmp/Prompter.ipa" 2>&1); rc=$?
  if [ "$rc" = 3 ] && printf '%s' "$out" | grep -q 'ASC_KEY_ID'; then echo "ok   no key settings: exit 3 and the setup is explained"; else echo "FAIL no key settings (rc $rc)"; fails=$((fails + 1)); fi
  # dry run builds the command with the key id, never a key file
  out=$(SKIP_PREFLIGHT=1 DRY_RUN=1 ASC_KEY_ID=ABC123 ASC_ISSUER_ID=issuer-1 PATH="$tmp/bin:$PATH" bash "$me" "$tmp/Prompter.ipa" 2>&1); rc=$?
  if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q -- '--validate-app' && ! printf '%s' "$out" | grep -q '\.p8'; then echo "ok   dry run prints the altool command"; else echo "FAIL dry run (rc $rc): $out"; fails=$((fails + 1)); fi
  # missing ipa
  out=$(SKIP_PREFLIGHT=1 bash "$me" "$tmp/none.ipa" 2>&1); rc=$?
  if [ "$rc" = 2 ]; then echo "ok   missing ipa: exit 2"; else echo "FAIL missing ipa (rc $rc)"; fails=$((fails + 1)); fi
  rm -rf "$tmp"
  [ "$fails" -eq 0 ] && { echo "self-test: OK"; return 0; }
  echo "self-test: $fails failure(s)"; return 1
}

if [ "${1:-}" = "--self-test" ]; then self_test; exit $?; fi

IPA="${1:-build/export/Prompter.ipa}"
if [ ! -f "$IPA" ]; then
  echo "validate-archive: $IPA not found. Run scripts/archive.sh first." >&2
  exit 2
fi

if [ "${SKIP_PREFLIGHT:-}" != 1 ]; then
  ARCHIVED_APP="build/Prompter.xcarchive/Products/Applications/Prompter.app"
  if [ -d "$ARCHIVED_APP" ]; then
    echo "validate-archive: preflight on $ARCHIVED_APP"
    if ! STORE=1 PREFLIGHT_PLATFORMS=ios PREFLIGHT_IOS_APP="$ARCHIVED_APP" scripts/preflight.sh; then
      echo "validate-archive: preflight failed. Fix the FAIL lines first." >&2
      exit 1
    fi
  else
    echo "validate-archive: no $ARCHIVED_APP, so preflight was not run on the archive (run it yourself: STORE=1 scripts/preflight.sh)" >&2
  fi
fi

ALTOOL=$(xcrun --find altool 2>/dev/null || true)
if [ -z "$ALTOOL" ]; then
  echo "validate-archive: altool is not available in this Xcode, so nothing was validated." >&2
  organizer_steps
  exit 3
fi
if [ -z "${ASC_KEY_ID:-}" ] || [ -z "${ASC_ISSUER_ID:-}" ]; then
  echo "validate-archive: set ASC_KEY_ID and ASC_ISSUER_ID (App Store Connect > Users and Access > Integrations > App Store Connect API)," >&2
  echo "and keep the AuthKey_<id>.p8 file in ~/.private_keys/. Nothing was validated." >&2
  organizer_steps
  exit 3
fi

CMD=(xcrun altool --validate-app -f "$IPA" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID")
if [ "${DRY_RUN:-}" = 1 ]; then
  printf '[dry run]'; printf ' %q' "${CMD[@]}"; printf '\n'
  exit 0
fi
"${CMD[@]}"
rc=$?
if [ "$rc" -eq 0 ]; then echo "validate-archive: $IPA validated"; exit 0; fi
echo "validate-archive: validation failed (altool exit $rc). Fix what it lists, bump the build number, archive again." >&2
exit 1
