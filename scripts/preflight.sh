#!/usr/bin/env bash
# Release preflight: the checks that most often make App Store Connect or App Review reject a build, run before an upload.
#
#   scripts/preflight.sh                 check the sources, plus any built apps it finds
#   STORE=1 scripts/preflight.sh         also demand a real bundle ID prefix and built apps (the store gate)
#   scripts/preflight.sh --self-test     run the script against a throwaway fixture (no Xcode, no network)
#
# What it checks (details: docs/release/preflight.md):
#   1. versions     one marketing version and one build number, read by the phone, watch and Mac apps alike
#   2. export       ITSAppUsesNonExemptEncryption is false in all three apps, and no third-party crypto in the sources
#   3. manifests    both privacy manifests (and the Mac one, if it exists) parse and use valid reason codes
#   4. required-reason APIs   what the sources and built binaries call matches what each manifest declares
#   5. usage strings  every permission the code can ask for has a plain, non-empty purpose string
#   6. icons        the phone and watch app icons are 1024 px with no alpha channel
#   7. denylist     the private denylist (same file as scripts/check-public.sh) does not appear inside built apps;
#                   terms print masked to their first 3 letters, never in full
#   8. prefix       with STORE=1, the bundle ID prefix is not com.example
#
# Built apps are looked for here (first match wins), or set the variable:
#   iPhone app  $PREFLIGHT_IOS_APP, build/Prompter.xcarchive/Products/Applications/Prompter.app,
#               build/DerivedData/Build/Products/{Release,Debug}-iphonesimulator/Prompter.app
#   Mac app     $PREFLIGHT_MAC_APP, build/DerivedData/Build/Products/{Release,Debug}/Prompter.app
# The watch app is read from <iPhone app>/Watch/PrompterWatch.app. With no built app the binary checks are skipped (and fail
# under STORE=1 or REQUIRE_BUILT=1). Build one first with scripts/heavy.sh --task <ID> -- scripts/build.sh.
#
# Environment: STORE=1, REQUIRE_BUILT=1, PUBLIC_DENYLIST (default <main checkout>/.inbox/public-denylist.txt),
# PREFLIGHT_ROOT (the folder holding project.yml; default is this repo).
# Exit codes: 0 all clear (warnings allowed), 1 at least one FAIL, 2 usage or setup error.
set -uo pipefail

PB=/usr/libexec/PlistBuddy
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${PREFLIGHT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

FAILS=0; WARNS=0; OKS=0; SKIPS=0
ok()   { OKS=$((OKS + 1));     echo "ok    $*"; }
fail() { FAILS=$((FAILS + 1)); echo "FAIL  $*"; }
warn() { WARNS=$((WARNS + 1)); echo "warn  $*"; }
skip() { SKIPS=$((SKIPS + 1)); echo "skip  $*"; }
section() { echo; echo "== $* =="; }

mask() { local t="$1"; printf '%s***' "${t:0:3}"; }
trim() { local v="$1"; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"; printf '%s' "$v"; }
pbget() { "$PB" -c "Print :$2" "$1" 2>/dev/null; }   # pbget <plist> <key path>

# ---------- project.yml readers (the file is plain two-space YAML; no YAML library needed) ----------

# yml_target_value <target> <key>: the value of "<key>:" inside that target's block, comment and quotes removed.
yml_target_value() {
  awk -v t="$1" -v k="$2" '
    /^targets:/ { tg = 1; next }
    /^[A-Za-z]/ { tg = 0 }
    tg && /^  [A-Za-z0-9_]+:[[:space:]]*$/ { cur = $1; sub(":", "", cur); next }
    tg && cur == t && $1 == k ":" {
      $1 = ""; v = $0
      sub(/[[:space:]]+#.*$/, "", v); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); gsub(/^"|"$/, "", v)
      print v; exit
    }' "$ROOT/project.yml"
}
# yml_target_dirs <target>: the "- path:" source folders of that target
yml_target_dirs() {
  awk -v t="$1" '
    /^targets:/ { tg = 1; next }
    /^[A-Za-z]/ { tg = 0 }
    tg && /^  [A-Za-z0-9_]+:[[:space:]]*$/ { cur = $1; sub(":", "", cur); next }
    tg && cur == t && /^[[:space:]]+-[[:space:]]+path:/ { print $3 }' "$ROOT/project.yml"
}
yml_global() { grep -E "^[[:space:]]*$1:" "$ROOT/project.yml" | head -1 | sed -E "s/^[^:]*:[[:space:]]*//; s/[[:space:]]+#.*$//; s/^\"//; s/\"$//"; }

# ---------- source scanning ----------

# scan_sources <target> <regex>: "file:line:text" for every non-comment source line of that target matching the regex.
scan_sources() {
  local target="$1" re="$2" dirs=() d
  while IFS= read -r d; do [ -d "$ROOT/$d" ] && dirs+=("$d"); done < <(yml_target_dirs "$target")
  [ "${#dirs[@]}" -eq 0 ] && return 0
  (cd "$ROOT" && grep -rnE --include='*.swift' --include='*.m' --include='*.mm' --include='*.h' --include='*.c' -e "$re" "${dirs[@]}" 2>/dev/null) |
    grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true
}

# ---------- required-reason API data ----------
CATEGORIES="UserDefaults SystemBootTime FileTimestamp DiskSpace ActiveKeyboards"
re_for() {
  case "$1" in
    UserDefaults)   echo '(^|[^A-Za-z0-9_])(NS)?UserDefaults|@AppStorage' ;;
    SystemBootTime) echo 'systemUptime|mach_absolute_time|mach_continuous_time|clock_gettime_nsec_np|CLOCK_UPTIME_RAW|KERN_BOOTTIME|kern\.boottime' ;;
    FileTimestamp)  echo 'creationDate|modificationDate|contentModificationDate|contentAccessDate|NSFileCreationDate|NSFileModificationDate|getattrlist|(^|[^A-Za-z0-9_])(f|l)?stat\([^)]*&' ;;
    DiskSpace)      echo 'volumeAvailableCapacity|volumeTotalCapacity|NSFileSystemFreeSize|NSFileSystemSize|systemFreeSize|(^|[^A-Za-z0-9_])statv?fs\(' ;;
    ActiveKeyboards) echo 'activeInputModes' ;;
  esac
}
# C symbols that betray a category inside a binary (nm -u)
syms_for() {
  case "$1" in
    SystemBootTime) echo '_mach_absolute_time _mach_continuous_time _clock_gettime_nsec_np' ;;
    FileTimestamp)  echo '_stat _fstat _lstat _fstatat _getattrlist _fgetattrlist' ;;
    DiskSpace)      echo '_statfs _statvfs _fstatfs _fstatvfs' ;;
  esac
}
valid_reasons() {
  case "$1" in
    UserDefaults)    echo 'CA92.1 1C8F.1 C56D.1 AC6B.1' ;;
    SystemBootTime)  echo '35F9.1 8FFB.1 3D61.1' ;;
    FileTimestamp)   echo 'DDA9.1 C617.1 3B52.1 0A2A.1' ;;
    DiskSpace)       echo 'E174.1 85F4.1 7D9E.1 B728.1' ;;
    ActiveKeyboards) echo '3EC4.1 54BD.1' ;;
  esac
}

# manifest_categories <file>: the declared category names, one per line (empty if none). Returns 1 if unreadable.
manifest_categories() {
  local f="$1" i=0 v
  while v=$("$PB" -c "Print :NSPrivacyAccessedAPITypes:$i:NSPrivacyAccessedAPIType" "$f" 2>/dev/null); do
    echo "${v#NSPrivacyAccessedAPICategory}"
    i=$((i + 1))
  done
  return 0
}
has_word() { case " $1 " in *" $2 "*) return 0 ;; esac; return 1; }

# ---------- finding the built apps ----------
first_dir() { local d; for d in "$@"; do [ -n "$d" ] && [ -d "$d" ] && { echo "$d"; return 0; }; done; return 1; }
IOS_APP=""; WATCH_APP=""; MAC_APP=""
find_apps() {
  local p="$ROOT/build/DerivedData/Build/Products"
  IOS_APP=$(first_dir "${PREFLIGHT_IOS_APP:-}" "$ROOT/build/Prompter.xcarchive/Products/Applications/Prompter.app" \
    "$p/Release-iphonesimulator/Prompter.app" "$p/Debug-iphonesimulator/Prompter.app") || IOS_APP=""
  MAC_APP=$(first_dir "${PREFLIGHT_MAC_APP:-}" "$p/Release/Prompter.app" "$p/Debug/Prompter.app") || MAC_APP=""
  [ -n "$IOS_APP" ] && WATCH_APP=$(first_dir "$IOS_APP/Watch/PrompterWatch.app") || WATCH_APP=""
}
built_plist() { # <target>
  case "$1" in
    Prompter) [ -n "$IOS_APP" ] && echo "$IOS_APP/Info.plist" ;;
    PrompterWatch) [ -n "$WATCH_APP" ] && echo "$WATCH_APP/Info.plist" ;;
    PrompterMac) [ -n "$MAC_APP" ] && echo "$MAC_APP/Contents/Info.plist" ;;
  esac
  return 0
}
built_dir() { # <target>
  case "$1" in Prompter) echo "$IOS_APP" ;; PrompterWatch) echo "$WATCH_APP" ;; PrompterMac) echo "$MAC_APP" ;; esac
}
APPS="Prompter PrompterWatch PrompterMac"
label() { case "$1" in Prompter) echo "iPhone app" ;; PrompterWatch) echo "watch app" ;; PrompterMac) echo "Mac app" ;; esac; }

# ---------- 1. versions ----------
check_versions() {
  section "1. versions and build numbers"
  local mv bv n t v
  mv=$(yml_global MARKETING_VERSION); bv=$(yml_global CURRENT_PROJECT_VERSION)
  for k in MARKETING_VERSION CURRENT_PROJECT_VERSION; do
    n=$(grep -cE "^[[:space:]]*$k:" "$ROOT/project.yml")
    [ "$n" = 1 ] && ok "$k is set once in project.yml" || fail "$k is set $n times in project.yml (it must be set once so every app shares it)"
  done
  [[ "$mv" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] && ok "marketing version $mv looks like a version" || fail "MARKETING_VERSION '$mv' is not 1.2 or 1.2.3"
  [[ "$bv" =~ ^[0-9]+$ ]] && ok "build number $bv is a whole number" || fail "CURRENT_PROJECT_VERSION '$bv' is not a whole number"
  for t in $APPS; do
    v=$(yml_target_value "$t" CFBundleShortVersionString)
    [ "$v" = '$(MARKETING_VERSION)' ] && ok "$(label "$t") reads the shared marketing version" || fail "$(label "$t"): CFBundleShortVersionString is '$v', want \$(MARKETING_VERSION)"
    v=$(yml_target_value "$t" CFBundleVersion)
    [ "$v" = '$(CURRENT_PROJECT_VERSION)' ] && ok "$(label "$t") reads the shared build number" || fail "$(label "$t"): CFBundleVersion is '$v', want \$(CURRENT_PROJECT_VERSION)"
  done
  local seen=0 p sv bn
  for t in $APPS; do
    p=$(built_plist "$t"); [ -n "$p" ] || continue
    seen=$((seen + 1))
    sv=$(pbget "$p" CFBundleShortVersionString); bn=$(pbget "$p" CFBundleVersion)
    if [ "$sv" = "$mv" ] && [ "$bn" = "$bv" ]; then ok "built $(label "$t") is $sv ($bn)"
    else fail "built $(label "$t") is $sv ($bn), project.yml says $mv ($bv)"; fi
  done
  [ "$seen" -eq 0 ] && skip "no built app: built version numbers not compared"
  return 0
}

# ---------- 2. export compliance ----------
check_export() {
  section "2. export compliance (ITSAppUsesNonExemptEncryption)"
  local t v p bv
  for t in $APPS; do
    v=$(yml_target_value "$t" ITSAppUsesNonExemptEncryption)
    case "$v" in
      false|NO|no|False) ok "$(label "$t"): ITSAppUsesNonExemptEncryption is false in project.yml" ;;
      '') fail "$(label "$t"): ITSAppUsesNonExemptEncryption is missing (App Store Connect would ask the export question on every build)" ;;
      *) fail "$(label "$t"): ITSAppUsesNonExemptEncryption is '$v'. Only false is right while all crypto is Apple's. See docs/release/preflight.md" ;;
    esac
    p=$(built_plist "$t")
    if [ -n "$p" ]; then
      bv=$(pbget "$p" ITSAppUsesNonExemptEncryption)
      [ "$bv" = false ] && ok "built $(label "$t") carries the key as false" || fail "built $(label "$t"): ITSAppUsesNonExemptEncryption is '${bv:-missing}'"
    fi
  done
  local third mine=0 t2 hits fw=""
  for t in $APPS; do
    third=$(scan_sources "$t" 'OpenSSL|openssl|libsodium|CryptoSwift|mbedtls|wolfSSL|BoringSSL|import[[:space:]]+(Sodium|SwiftCrypto)|AES_encrypt|EVP_')
    if [ -n "$third" ]; then
      fail "$(label "$t") has third-party or hand-written crypto, which is not exempt: $(echo "$third" | head -3 | tr '\n' ' ')"
      mine=1
    fi
    for fwk in CommonCrypto CryptoKit CloudKit StoreKit Network; do
      hits=$(scan_sources "$t" "import[[:space:]]+$fwk([[:space:]]|\$)")
      [ -n "$hits" ] && ! has_word "$fw" "$fwk" && fw="$fw $fwk"
    done
  done
  [ "$mine" -eq 0 ] && ok "no third-party crypto in the sources"
  echo "info  Apple frameworks imported that use or wrap crypto:${fw:- none}. All are exempt; re-read docs/release/preflight.md if you add another."
}

# ---------- 3 + 4. privacy manifests and required-reason APIs ----------
check_manifests() {
  section "3. privacy manifests"
  local t f cats c n i reasons r valid
  for t in $APPS; do
    f="$ROOT/$t/PrivacyInfo.xcprivacy"
    if [ ! -f "$f" ]; then
      if [ "$t" = PrompterMac ] && [ "${STORE:-}" != 1 ]; then warn "Mac app has no PrivacyInfo.xcprivacy (needed before a Mac App Store build)"
      else fail "$(label "$t") has no $t/PrivacyInfo.xcprivacy"; fi
      continue
    fi
    if ! plutil -lint "$f" >/dev/null 2>&1; then fail "$t/PrivacyInfo.xcprivacy is not a valid plist"; continue; fi
    [ "$(pbget "$f" NSPrivacyTracking)" = false ] && ok "$(label "$t"): NSPrivacyTracking is false" || fail "$(label "$t"): NSPrivacyTracking must be false (no tracking)"
    "$PB" -c 'Print :NSPrivacyTrackingDomains' "$f" >/dev/null 2>&1 && ok "$(label "$t"): NSPrivacyTrackingDomains is present" || fail "$(label "$t"): NSPrivacyTrackingDomains is missing"
    "$PB" -c 'Print :NSPrivacyCollectedDataTypes' "$f" >/dev/null 2>&1 && ok "$(label "$t"): NSPrivacyCollectedDataTypes is present" || fail "$(label "$t"): NSPrivacyCollectedDataTypes is missing"
    i=0
    while c=$(pbget "$f" "NSPrivacyAccessedAPITypes:$i:NSPrivacyAccessedAPIType"); do
      c="${c#NSPrivacyAccessedAPICategory}"
      valid=$(valid_reasons "$c")
      if [ -z "$valid" ]; then fail "$(label "$t"): unknown API category '$c' in the manifest"; i=$((i + 1)); continue; fi
      n=0; reasons=""
      while r=$(pbget "$f" "NSPrivacyAccessedAPITypes:$i:NSPrivacyAccessedAPITypeReasons:$n"); do
        reasons="$reasons $r"; n=$((n + 1))
        has_word "$valid" "$r" || fail "$(label "$t"): reason $r is not a valid $c reason (valid:$(echo " $valid"))"
      done
      [ "$n" -eq 0 ] && fail "$(label "$t"): $c is declared with no reason code"
      [ "$n" -gt 0 ] && ok "$(label "$t"): $c declared with${reasons}"
      i=$((i + 1))
    done
    local b; b=$(built_dir "$t")
    if [ -n "$b" ]; then
      local bf="$b/PrivacyInfo.xcprivacy"; [ "$t" = PrompterMac ] && bf="$b/Contents/Resources/PrivacyInfo.xcprivacy"
      [ -f "$bf" ] && ok "built $(label "$t") contains its manifest" || fail "built $(label "$t") has no PrivacyInfo.xcprivacy inside (is the file in the target's sources?)"
    fi
  done

  section "4. required-reason APIs (what the code calls vs what the manifest declares)"
  local used declared lines
  for t in $APPS; do
    f="$ROOT/$t/PrivacyInfo.xcprivacy"; [ -f "$f" ] || continue
    declared=$(manifest_categories "$f" | tr '\n' ' ')
    for c in $CATEGORIES; do
      lines=$(scan_sources "$t" "$(re_for "$c")")
      if [ -n "$lines" ]; then
        if has_word "$declared" "$c"; then ok "$(label "$t"): uses $c, declared"
        else fail "$(label "$t"): the sources use $c but the manifest does not declare it. First hit: $(echo "$lines" | head -1 | cut -c1-110)"; fi
      elif has_word "$declared" "$c"; then
        warn "$(label "$t"): the manifest declares $c but no source line uses it (fine if a framework needs it; otherwise remove it)"
      fi
    done
    local b exe sym found cat2 bin
    b=$(built_dir "$t"); [ -n "$b" ] || continue
    local bins=()
    if [ "$t" = PrompterMac ]; then bins=("$b/Contents/MacOS/Prompter"); else bins=("$b/$(pbget "$b/Info.plist" CFBundleExecutable)"); fi
    for exe in "$b"/*.debug.dylib "$b"/Contents/MacOS/*.debug.dylib; do [ -f "$exe" ] && bins+=("$exe"); done
    for bin in "${bins[@]}"; do
      [ -f "$bin" ] || continue
      found=$(nm -u "$bin" 2>/dev/null | awk '$1 == "U" { print $2 }')
      for cat2 in SystemBootTime FileTimestamp DiskSpace; do
        for sym in $(syms_for "$cat2"); do
          if printf '%s\n' "$found" | grep -qx -- "$sym"; then
            has_word "$declared" "$cat2" && ok "built $(label "$t") imports $sym ($cat2), declared" || fail "built $(label "$t") imports $sym ($cat2) and the manifest does not declare it"
          fi
        done
      done
    done
  done
}

# ---------- 5. usage strings ----------
usage_value() { # <target> <key>
  local p v; p=$(built_plist "$1")
  if [ -n "$p" ]; then pbget "$p" "$2"; else yml_target_value "$1" "$2"; fi
}
check_usage() {
  section "5. usage strings (permission prompts)"
  local t key re lines v pair
  local MAP=(
    'NSMicrophoneUsageDescription|AVAudioRecorder|requestRecordPermission|inputNode|AVCaptureDevice'
    'NSSpeechRecognitionUsageDescription|SFSpeechRecognizer|SFSpeechAudioBufferRecognitionRequest'
    'NSCameraUsageDescription|AVCaptureSession|UIImagePickerController'
    'NSPhotoLibraryUsageDescription|PHPhotoLibrary'
    'NSLocationWhenInUseUsageDescription|CLLocationManager'
    'NSContactsUsageDescription|CNContactStore'
    'NSBluetoothAlwaysUsageDescription|CBCentralManager|CBPeripheralManager'
    'NSFaceIDUsageDescription|LAContext'
    'NSMotionUsageDescription|CMMotionManager'
    'NSLocalNetworkUsageDescription|NWBrowser|NetServiceBrowser|NetService\('
  )
  for t in $APPS; do
    for pair in "${MAP[@]}"; do
      key="${pair%%|*}"; re="${pair#*|}"; re="${re//|/|}"
      lines=$(scan_sources "$t" "$re")
      v=$(usage_value "$t" "$key")
      if [ -n "$lines" ] && [ -z "$v" ]; then
        fail "$(label "$t"): the code can trigger the $key prompt but the string is missing. First hit: $(echo "$lines" | head -1 | cut -c1-100)"
      elif [ -n "$lines" ]; then
        ok "$(label "$t"): $key present"
      elif [ -n "$v" ]; then
        warn "$(label "$t"): $key is set but no source line needs it (App Review may ask why)"
      fi
    done
    # every usage string that exists must read like a sentence, not a placeholder
    local keys k
    keys=$( { grep -ohE '^[[:space:]]+NS[A-Za-z]+UsageDescription:' "$ROOT/project.yml" 2>/dev/null | tr -d ' :'
              [ -n "$(built_plist "$t")" ] && plutil -p "$(built_plist "$t")" 2>/dev/null | grep -oE 'NS[A-Za-z]+UsageDescription'; } | sort -u)
    for k in $keys; do
      v=$(usage_value "$t" "$k"); [ -n "$v" ] || continue
      if [ "${#v}" -lt 20 ] || echo "$v" | grep -qiE 'TODO|FIXME|TBD|lorem|placeholder|\$\('; then
        fail "$(label "$t"): $k reads like a placeholder: '$v'"
      fi
    done
    if [ -n "$(scan_sources "$t" 'NWBrowser|NetServiceBrowser|NWListener')" ] && [ -z "$(usage_value "$t" NSBonjourServices)$(yml_target_value "$t" NSBonjourServices)" ]; then
      # NSBonjourServices is a list in project.yml, so the one-line reader sees nothing: look for the key in the target block instead
      awk -v t="$t" '/^targets:/{tg=1;next} /^[A-Za-z]/{tg=0} tg && /^  [A-Za-z0-9_]+:[[:space:]]*$/{c=$1;sub(":","",c);next} tg && c==t && $1=="NSBonjourServices:"{f=1} END{exit !f}' "$ROOT/project.yml" \
        || fail "$(label "$t"): the code browses or listens on the network but NSBonjourServices is not set"
    fi
  done
}

# ---------- 6. app icons ----------
check_icons() {
  section "6. app icons"
  local t dir f n has w h any big
  for t in $APPS; do
    dir=$(ls -d "$ROOT/$t"/Resources/Assets.xcassets/AppIcon.appiconset 2>/dev/null | head -1)
    if [ -z "$dir" ]; then
      [ "$t" = PrompterMac ] && warn "Mac app has no AppIcon.appiconset" || fail "$(label "$t") has no AppIcon.appiconset"
      continue
    fi
    # every file named in Contents.json must exist
    local missing
    missing=$(python3 -I - "$dir" <<'PY'
import json, os, sys
d = sys.argv[1]
names = [i["filename"] for i in json.load(open(os.path.join(d, "Contents.json"))).get("images", []) if "filename" in i]
print(" ".join(n for n in names if not os.path.exists(os.path.join(d, n))))
PY
)
    [ -z "$missing" ] && ok "$(label "$t"): every icon file named in Contents.json exists" || fail "$(label "$t"): Contents.json names missing files: $missing"
    big=0; any=0
    for f in "$dir"/*.png; do
      [ -f "$f" ] || continue
      any=1
      has=$(sips -g hasAlpha "$f" 2>/dev/null | awk '/hasAlpha/ { print $2 }')
      w=$(sips -g pixelWidth "$f" 2>/dev/null | awk '/pixelWidth/ { print $2 }')
      h=$(sips -g pixelHeight "$f" 2>/dev/null | awk '/pixelHeight/ { print $2 }')
      [ "$w" = 1024 ] && [ "$h" = 1024 ] && big=1
      if [ "$t" != PrompterMac ]; then
        [ "$has" = no ] || fail "$(label "$t"): $(basename "$f") has an alpha channel (App Store Connect rejects it). Flatten it."
      fi
    done
    [ "$any" -eq 0 ] && { fail "$(label "$t"): no icon PNGs in $(basename "$dir")"; continue; }
    if [ "$t" != PrompterMac ]; then
      [ "$big" -eq 1 ] && ok "$(label "$t"): a 1024 by 1024 icon exists, no file has alpha" || fail "$(label "$t"): no 1024 by 1024 icon"
    else
      ok "$(label "$t"): icons present (alpha is allowed on the Mac)"
    fi
    local b; b=$(built_plist "$t")
    if [ -n "$b" ] && [ "$t" != PrompterMac ]; then
      plutil -p "$b" 2>/dev/null | grep -q AppIcon && ok "built $(label "$t") names its AppIcon" || fail "built $(label "$t") does not name an app icon in its Info.plist"
    fi
  done
}

# ---------- 7. private denylist inside built binaries ----------
check_denylist() {
  section "7. private denylist inside built apps"
  local dirs=() t d
  for t in $APPS; do d=$(built_dir "$t"); [ -n "$d" ] && dirs+=("$d"); done
  if [ "${#dirs[@]}" -eq 0 ]; then skip "no built app: nothing to scan"; return 0; fi
  local common denylist
  common=$(cd "$ROOT" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  denylist="${PUBLIC_DENYLIST:-${common:+$common/../.inbox/public-denylist.txt}}"
  if [ -z "$denylist" ] || [ ! -f "$denylist" ]; then
    fail "denylist not found (set PUBLIC_DENYLIST to the file scripts/check-public.sh uses); built apps were not scanned"
    return 0
  fi
  local work; work=$(mktemp -d)
  : > "$work/plain"; : > "$work/words"
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(trim "${line%$'\r'}")
    case "$line" in
      ''|'#'*|allow-path:*) ;;
      word:*) line=$(trim "${line#word:}"); [ -n "$line" ] && printf '%s\n' "$line" >> "$work/words" ;;
      *) printf '%s\n' "$line" >> "$work/plain" ;;
    esac
  done < "$denylist"
  if [ ! -s "$work/plain" ] && [ ! -s "$work/words" ]; then fail "denylist has no terms: scan not run"; rm -rf "$work"; return 0; fi

  local hits=0 files=0 f rel term base
  for d in "${dirs[@]}"; do
    base=$(basename "$d")
    while IFS= read -r -d '' f; do
      files=$((files + 1))
      rel="$base/${f#"$d"/}"
      strings -a -n 4 "$f" > "$work/s" 2>/dev/null || : > "$work/s"
      printf '%s\n' "$rel" >> "$work/s"
      local hit=0
      [ -s "$work/plain" ] && grep -qiF -f "$work/plain" "$work/s" && hit=1
      [ -s "$work/words" ] && grep -qiwF -f "$work/words" "$work/s" && hit=1
      [ "$hit" -eq 1 ] || continue
      while IFS= read -r term; do
        [ -n "$term" ] || continue
        if grep -qiF -- "$term" "$work/s"; then
          fail "private term in built file $(printf '%s' "$rel" | awk -v tf="$work/plain" 'BEGIN{while((getline l<tf)>0){if(l!="")t[++n]=tolower(l)}}{s=$0;for(i=1;i<=n;i++){o="";r=s;while((p=index(tolower(r),t[i]))>0){o=o substr(r,1,p-1) substr(r,p,3) "***";r=substr(r,p+length(t[i]))};s=o r};print s}') [$(mask "$term")]"
          hits=$((hits + 1))
        fi
      done < "$work/plain"
      while IFS= read -r term; do
        [ -n "$term" ] || continue
        if grep -qiwF -- "$term" "$work/s"; then
          fail "private word in built file $(printf '%s' "$rel" | head -c 200 | awk -v tf="$work/words" 'BEGIN{while((getline l<tf)>0){if(l!="")t[++n]=tolower(l)}}{s=$0;for(i=1;i<=n;i++){o="";r=s;while((p=index(tolower(r),t[i]))>0){o=o substr(r,1,p-1) substr(r,p,3) "***";r=substr(r,p+length(t[i]))};s=o r};print s}') [$(mask "$term")]"
          hits=$((hits + 1))
        fi
      done < "$work/words"
    done < <(find "$d" -type f -print0)
  done
  [ "$hits" -eq 0 ] && ok "scanned $files files in ${#dirs[@]} built app(s) with strings: no private term"
  rm -rf "$work"
  return 0
}

# ---------- 8. bundle ID prefix ----------
prefix_from_config() {
  local f v="" line
  for f in "$ROOT/Config/Signing.xcconfig" "$ROOT/Config/Local.xcconfig" "$ROOT/Config/Store.xcconfig"; do
    [ -f "$f" ] || continue
    line=$(grep -E '^[[:space:]]*BUNDLE_ID_PREFIX[[:space:]]*=' "$f" | tail -1 || true)
    [ -n "$line" ] && v=$(trim "$(printf '%s' "${line#*=}" | sed -E 's://.*$::')")
  done
  printf '%s' "$v"
}
check_prefix() {
  section "8. bundle ID prefix"
  local prefix t p id bad=0
  prefix=$(prefix_from_config)
  if [ "${STORE:-}" != 1 ]; then
    skip "STORE is not 1: prefix '${prefix:-empty}' is fine for a self-build (set STORE=1 for a store build)"
    return 0
  fi
  if [ -z "$prefix" ]; then fail "STORE=1 but BUNDLE_ID_PREFIX is empty"; bad=1
  elif [[ "$prefix" == com.example* ]]; then fail "STORE=1 but BUNDLE_ID_PREFIX is '$prefix'. A store build needs your own prefix in Config/Local.xcconfig"; bad=1
  fi
  for t in $APPS; do
    p=$(built_plist "$t"); [ -n "$p" ] || continue
    id=$(pbget "$p" CFBundleIdentifier)
    if [[ "$id" == com.example* ]]; then fail "built $(label "$t") has bundle ID $id"; bad=1; fi
  done
  [ "$bad" -eq 0 ] && ok "bundle ID prefix is '$prefix', not com.example"
  return 0
}

# ---------- built app structure ----------
check_built_shape() {
  section "built apps"
  if [ -z "$IOS_APP" ]; then
    if [ "${STORE:-}" = 1 ] || [ "${REQUIRE_BUILT:-}" = 1 ]; then fail "no built iPhone app found, and this run needs one (see the header of this script for where it looks)"
    else skip "no built iPhone app found: binary checks skipped (scripts/heavy.sh --task <ID> -- scripts/build.sh builds one)"; fi
    return 0
  fi
  ok "iPhone app: ${IOS_APP#"$ROOT"/}"
  if [ -z "$WATCH_APP" ]; then fail "the watch app is not embedded under Watch/ in the iPhone app"; else
    ok "watch app embedded"
    local pid wid comp
    pid=$(pbget "$IOS_APP/Info.plist" CFBundleIdentifier); wid=$(pbget "$WATCH_APP/Info.plist" CFBundleIdentifier)
    comp=$(pbget "$WATCH_APP/Info.plist" WKCompanionAppBundleIdentifier)
    [ "$wid" = "$pid.watchkitapp" ] && ok "watch bundle ID is the phone's plus .watchkitapp" || fail "watch bundle ID '$wid' is not '$pid.watchkitapp'"
    [ "$comp" = "$pid" ] && ok "watch companion ID matches the phone" || fail "WKCompanionAppBundleIdentifier '$comp' is not '$pid'"
  fi
  if [ -n "$MAC_APP" ]; then ok "Mac app: ${MAC_APP#"$ROOT"/}"
  else skip "no built Mac app found: Mac binary checks skipped"; fi
}

run_all() {
  [ -f "$ROOT/project.yml" ] || { echo "preflight: no project.yml in $ROOT" >&2; exit 2; }
  command -v plutil >/dev/null && [ -x "$PB" ] || { echo "preflight: needs macOS (plutil, PlistBuddy)" >&2; exit 2; }
  find_apps
  echo "preflight: $(yml_global MARKETING_VERSION) ($(yml_global CURRENT_PROJECT_VERSION))${STORE:+, STORE=$STORE}"
  check_built_shape
  check_versions
  check_export
  check_manifests
  check_usage
  check_icons
  check_denylist
  check_prefix
  echo
  echo "---"
  echo "ok: $OKS   warnings: $WARNS   skipped: $SKIPS   FAILED: $FAILS"
  if [ "$FAILS" -gt 0 ]; then echo "preflight: FAILED"; exit 1; fi
  echo "preflight: OK"
}

# ---------- self-test ----------
write_png() { # <path> <rgb|rgba> <size>
  python3 -I - "$1" "$2" "$3" <<'PY'
import struct, sys, zlib
path, mode, size = sys.argv[1], sys.argv[2], int(sys.argv[3])
ct, px = (6, b"\x10\x20\x30\xff") if mode == "rgba" else (2, b"\x10\x20\x30")
raw = b"".join(b"\x00" + px * size for _ in range(size))
def chunk(t, d):
    c = struct.pack(">I", len(d)) + t + d
    return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, ct, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
open(path, "wb").write(png)
PY
}

make_fixture() { # <dir>
  local r="$1" t d
  mkdir -p "$r/Prompter/Resources/Assets.xcassets/AppIcon.appiconset" "$r/PrompterWatch/Resources/Assets.xcassets/AppIcon.appiconset" \
    "$r/PrompterMac/Resources/Assets.xcassets/AppIcon.appiconset" "$r/Core" "$r/Shared" "$r/Config"
  cat > "$r/project.yml" <<'EOF'
name: Prompter
settings:
  base:
    MARKETING_VERSION: "1.2.0"
    CURRENT_PROJECT_VERSION: "7"
targets:
  Prompter:
    type: application
    sources:
      - path: Prompter
      - path: Core
      - path: Shared
    info:
      path: Prompter/Info.plist
      properties:
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        ITSAppUsesNonExemptEncryption: false
        NSMicrophoneUsageDescription: Prompter listens to your voice so the script follows you as you speak.
  PrompterWatch:
    type: application
    sources:
      - path: PrompterWatch
      - path: Shared
    info:
      path: PrompterWatch/Info.plist
      properties:
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        ITSAppUsesNonExemptEncryption: false
  PrompterMac:
    type: application
    sources:
      - path: PrompterMac
      - path: Core
      - path: Shared
    info:
      path: PrompterMac/Info.plist
      properties:
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        ITSAppUsesNonExemptEncryption: false
schemes:
  Prompter: {}
EOF
  printf 'BUNDLE_ID_PREFIX = com.example\n' > "$r/Config/Signing.xcconfig"
  for t in Prompter PrompterWatch PrompterMac; do
    cat > "$r/$t/PrivacyInfo.xcprivacy" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>NSPrivacyTracking</key><false/>
<key>NSPrivacyTrackingDomains</key><array/>
<key>NSPrivacyCollectedDataTypes</key><array/>
<key>NSPrivacyAccessedAPITypes</key><array>
<dict><key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategoryUserDefaults</string>
<key>NSPrivacyAccessedAPITypeReasons</key><array><string>CA92.1</string></array></dict>
</array></dict></plist>
EOF
    if [ "$t" = PrompterWatch ]; then
      sed -i '' -e 's/AccessedAPICategoryUserDefaults/AccessedAPICategorySystemBootTime/' -e 's/CA92.1/35F9.1/' "$r/$t/PrivacyInfo.xcprivacy"
    fi
    d="$r/$t/Resources/Assets.xcassets/AppIcon.appiconset"
    write_png "$d/icon.png" rgb 1024
    printf '{"images":[{"filename":"icon.png","size":"1024x1024"}]}\n' > "$d/Contents.json"
  done
  printf 'import Foundation\nlet d = UserDefaults.standard\n' > "$r/Core/Settings.swift"
  printf 'import Foundation\n// systemUptime is only named in a comment here\nlet x = 1\n' > "$r/Shared/Clock.swift"
  echo 'print("hi")' > "$r/Prompter/main.swift"; echo 'let t = ProcessInfo.processInfo.systemUptime' > "$r/PrompterWatch/main.swift"; echo 'print("hi")' > "$r/PrompterMac/main.swift"
  # built apps
  local ios="$r/build/Prompter.xcarchive/Products/Applications/Prompter.app" w mac="$r/build/DerivedData/Build/Products/Release/Prompter.app"
  w="$ios/Watch/PrompterWatch.app"
  mkdir -p "$w" "$mac/Contents/MacOS" "$mac/Contents/Resources"
  fixture_plist "$ios/Info.plist" com.acme.prompter Prompter "<key>NSMicrophoneUsageDescription</key><string>Prompter listens to your voice so the script follows you as you speak.</string><key>CFBundleIcons</key><dict><key>CFBundlePrimaryIcon</key><dict><key>CFBundleIconName</key><string>AppIcon</string></dict></dict>"
  fixture_plist "$w/Info.plist" com.acme.prompter.watchkitapp PrompterWatch "<key>WKCompanionAppBundleIdentifier</key><string>com.acme.prompter</string><key>CFBundleIcons</key><dict><key>CFBundlePrimaryIcon</key><dict><key>CFBundleIconName</key><string>AppIcon</string></dict></dict>"
  fixture_plist "$mac/Contents/Info.plist" com.acme.prompter.mac Prompter ""
  cp "$r/Prompter/PrivacyInfo.xcprivacy" "$ios/"; cp "$r/PrompterWatch/PrivacyInfo.xcprivacy" "$w/"; cp "$r/PrompterMac/PrivacyInfo.xcprivacy" "$mac/Contents/Resources/"
  printf 'plain program text\n' > "$ios/Prompter"; printf 'plain\n' > "$w/PrompterWatch"; printf 'plain\n' > "$mac/Contents/MacOS/Prompter"
  cat > "$r/deny.txt" <<'EOF'
# test denylist
Zebrafoo
word:Quux
allow-path: legacy/*
EOF
}
fixture_plist() { # <path> <bundle id> <executable> <extra xml>
  cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleExecutable</key><string>$3</string>
<key>CFBundleShortVersionString</key><string>1.2.0</string>
<key>CFBundleVersion</key><string>7</string>
<key>ITSAppUsesNonExemptEncryption</key><false/>
$4
</dict></plist>
EOF
}

self_test() {
  local tmp fails=0 r me
  tmp=$(mktemp -d)
  me="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
  r="$tmp/fx"; mkdir -p "$r"; make_fixture "$r"
  ( cd "$r" && git init -q . ) >/dev/null 2>&1
  local OUT RC
  run() { OUT=$(PREFLIGHT_ROOT="$r" PUBLIC_DENYLIST="$r/deny.txt" "$@" "$me" 2>&1); RC=$?; }
  runenv() { OUT=$(env PREFLIGHT_ROOT="$r" PUBLIC_DENYLIST="${PUBLIC_DENYLIST_OVERRIDE:-$r/deny.txt}" "$@" "$me" 2>&1); RC=$?; }
  pass() { echo "ok   $1"; }
  bad() { echo "FAIL $1"; fails=$((fails + 1)); }
  expect() { # <label> <want rc> [needle that must appear]
    if [ "$RC" != "$2" ]; then bad "$1 (want rc $2, got $RC)"; echo "$OUT" | grep -E '^(FAIL|warn)' | head -5 | sed 's/^/       /'; return; fi
    if [ -n "${3:-}" ] && ! printf '%s' "$OUT" | grep -qF -- "$3"; then bad "$1 (output lacks: $3)"; return; fi
    pass "$1"
  }
  local ios="$r/build/Prompter.xcarchive/Products/Applications/Prompter.app"
  local w="$ios/Watch/PrompterWatch.app" mac="$r/build/DerivedData/Build/Products/Release/Prompter.app"

  runenv; expect "clean fixture passes" 0 "preflight: OK"

  sed -i '' 's/<string>1.2.0<\/string>/<string>1.3.0<\/string>/' "$w/Info.plist"
  runenv; expect "watch version differing from project.yml fails" 1 "built watch app is 1.3.0"
  sed -i '' 's/<string>1.3.0<\/string>/<string>1.2.0<\/string>/' "$w/Info.plist"

  cp "$r/project.yml" "$tmp/project.yml.bak"
  awk '/ITSAppUsesNonExemptEncryption: false/ && !done { done = 1; next } { print }' "$tmp/project.yml.bak" > "$r/project.yml"
  runenv; expect "missing export compliance key fails" 1 "ITSAppUsesNonExemptEncryption is missing"
  cp "$tmp/project.yml.bak" "$r/project.yml"
  sed -i '' 's/ITSAppUsesNonExemptEncryption: false/ITSAppUsesNonExemptEncryption: true/' "$r/project.yml"
  runenv; expect "export compliance true fails" 1 "Only false is right"
  cp "$tmp/project.yml.bak" "$r/project.yml"

  printf 'import OpenSSL\n' > "$r/Shared/Crypto.swift"
  runenv; expect "third-party crypto fails" 1 "third-party or hand-written crypto"
  rm "$r/Shared/Crypto.swift"

  printf 'let t = try FileManager.default.attributesOfItem(atPath: p)[.modificationDate]\n' > "$r/Prompter/Dates.swift"
  runenv; expect "undeclared FileTimestamp API fails" 1 "FileTimestamp but the manifest does not declare"
  rm "$r/Prompter/Dates.swift"

  cp "$r/PrompterWatch/PrivacyInfo.xcprivacy" "$tmp/wpriv.bak"
  sed -i '' -e 's/AccessedAPICategorySystemBootTime/AccessedAPICategoryUserDefaults/' -e 's/35F9.1/CA92.1/' "$r/PrompterWatch/PrivacyInfo.xcprivacy"
  runenv; expect "watch using systemUptime without declaring it fails" 1 "use SystemBootTime but the manifest"
  cp "$tmp/wpriv.bak" "$r/PrompterWatch/PrivacyInfo.xcprivacy"

  cp "$r/Prompter/PrivacyInfo.xcprivacy" "$tmp/priv.bak"
  sed -i '' 's/CA92.1/ZZZZ.9/' "$r/Prompter/PrivacyInfo.xcprivacy"
  runenv; expect "invalid reason code fails" 1 "reason ZZZZ.9 is not a valid UserDefaults reason"
  cp "$tmp/priv.bak" "$r/Prompter/PrivacyInfo.xcprivacy"
  sed -i '' 's#<key>NSPrivacyTracking</key><false/>#<key>NSPrivacyTracking</key><true/>#' "$r/Prompter/PrivacyInfo.xcprivacy"
  runenv; expect "tracking true fails" 1 "NSPrivacyTracking must be false"
  cp "$tmp/priv.bak" "$r/Prompter/PrivacyInfo.xcprivacy"
  mv "$r/PrompterWatch/PrivacyInfo.xcprivacy" "$tmp/watchpriv.bak"
  runenv; expect "missing watch manifest fails" 1 "has no PrompterWatch/PrivacyInfo.xcprivacy"
  mv "$tmp/watchpriv.bak" "$r/PrompterWatch/PrivacyInfo.xcprivacy"

  printf 'import Speech\nlet r = SFSpeechRecognizer()\n' > "$r/Prompter/Speech.swift"
  runenv; expect "speech code without its usage string fails" 1 "NSSpeechRecognitionUsageDescription prompt but the string is missing"
  rm "$r/Prompter/Speech.swift"
  cp "$ios/Info.plist" "$tmp/info.bak"
  sed -i '' 's/Prompter listens to your voice so the script follows you as you speak./TODO/' "$ios/Info.plist"
  runenv; expect "placeholder usage string fails" 1 "reads like a placeholder"
  cp "$tmp/info.bak" "$ios/Info.plist"

  write_png "$r/Prompter/Resources/Assets.xcassets/AppIcon.appiconset/icon.png" rgba 1024
  runenv; expect "app icon with alpha fails" 1 "has an alpha channel"
  write_png "$r/Prompter/Resources/Assets.xcassets/AppIcon.appiconset/icon.png" rgb 1024

  printf 'binary junk ZEBRAFOO more junk\n' > "$ios/Prompter"
  runenv; expect "denylisted term inside a built binary fails" 1 "[Zeb***]"
  if printf '%s' "$OUT" | grep -qi 'zebrafoo'; then bad "output leaked a full term"; else pass "full term never printed"; fi
  printf 'plain program text\n' > "$ios/Prompter"
  printf 'a Quux appears\n' > "$w/PrompterWatch"
  runenv; expect "denylisted whole word inside a built binary fails" 1 "[Quu***]"
  printf 'scaleQuuxy is not the word\n' > "$w/PrompterWatch"
  runenv; expect "word term inside another word passes" 0
  printf 'plain\n' > "$w/PrompterWatch"; printf 'plain program text\n' > "$ios/Prompter"
  PUBLIC_DENYLIST_OVERRIDE="$tmp/nope.txt" runenv; expect "missing denylist fails, never passes" 1 "denylist not found"

  runenv STORE=1; expect "STORE=1 with the com.example prefix fails" 1 "BUNDLE_ID_PREFIX is 'com.example'"
  printf 'BUNDLE_ID_PREFIX = com.acme   // real\n' > "$r/Config/Signing.xcconfig"
  runenv STORE=1; expect "STORE=1 with a real prefix passes" 0 "bundle ID prefix is 'com.acme'"
  mv "$r/build" "$tmp/build.bak"
  runenv STORE=1; expect "STORE=1 with no built app fails" 1 "no built iPhone app"
  runenv; expect "no built app skips binary checks" 0 "binary checks skipped"
  mv "$tmp/build.bak" "$r/build"

  rm -rf "$tmp"
  if [ "$fails" -eq 0 ]; then echo "self-test: OK"; return 0; fi
  echo "self-test: $fails failure(s)"; return 1
}

case "${1:-}" in
  --self-test) self_test ;;
  --make-fixture) mkdir -p "$2" && make_fixture "$2" ;;   # for debugging the script itself
  '') run_all ;;
  *) echo "usage: $0 [--self-test]" >&2; exit 2 ;;
esac
