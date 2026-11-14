#!/usr/bin/env bash
# Keep Prompter for Mac up to date on this Mac and on other Macs you own.
#
# Builds the latest commit on `main` (never the working tree, so half-done edits don't ship) and installs it in
# /Applications/Prompter.app (DEST) here and on every host in DEPLOY_HOSTS over SSH. A copy that is open is left alone and
# updated on a later run, so an update never interrupts a take. Safe to run any time: when every copy already runs the
# latest commit it only checks and exits.
#
#   DEPLOY_HOSTS="user@host other@host" scripts/deploy-mac.sh   # build if main moved, then install wherever it's out of date
#   DEPLOY_HOSTS="" scripts/deploy-mac.sh                       # this Mac only
#   DEPLOY_HOSTS=... scripts/deploy-mac.sh --install-agent      # also run it every 10 minutes in the background (LaunchAgent)
#   scripts/deploy-mac.sh --remove-agent                        # stop the background runs
#   scripts/deploy-mac.sh --check-only                          # change nothing: say whether DEST could be replaced
#
# DEPLOY_HOSTS has no default and must be set (an empty value means this Mac only): a script that copies an app onto other
# computers must never guess where. A copy is only ever replaced by a build with the same bundle ID, and never when it is
# a Mac App Store install (it has Contents/_MASReceipt). Anything else at DEST is left alone and reported.
#
# Environment: DEPLOY_HOSTS (above), DEST (default /Applications/Prompter.app, the same path on every host),
# DEPLOY_APP (the built app that --check-only compares against, default the Release build this script makes),
# AGENT_LABEL (default local.prompter-deploy).
# The log is build/deploy/deploy.log. Setup on each other Mac (once): System Settings → General → Sharing → Remote Login
# on, and this Mac's ~/.ssh/prompter_deploy.pub added to that Mac's ~/.ssh/authorized_keys.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# DEPLOY_HOSTS: space-separated user@host. No default; see the header.
KEY="$HOME/.ssh/prompter_deploy"
WORK="$REPO/build/deploy"
TREE="$WORK/source"                                              # a git worktree that follows main
APP="${DEPLOY_APP:-$WORK/DerivedData/Build/Products/Release/Prompter.app}"
DEST="${DEST:-/Applications/Prompter.app}"
STAGING="Library/Caches/prompter-deploy"                         # on the remote host, relative to home
AGENT_LABEL="${AGENT_LABEL:-local.prompter-deploy}"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
SSH_OPTS=(-i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
# The build every copy gets: plain Release, a self-build (every feature on, no iCloud; it never reads Config/Store.xcconfig),
# in the selfbuild Mac flavor (ad hoc, not sandboxed, no team, no entitlements). Keep it on one line:
# scripts/check-selfbuild.sh builds with exactly these settings and checks the app carries no entitlements.
DEPLOY_BUILD_SETTINGS=(-configuration Release PROMPTER_MAC_FLAVOR=selfbuild PROMPTER_MAC_SIGN_IDENTITY=- PROMPTER_MAC_TEAM= PROMPTER_CLOUD_CONTAINER=)

mkdir -p "$WORK"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

# The bundle ID of an app, or nothing when it has no readable Info.plist.
bundle_id_of() { [ -f "$1/Contents/Info.plist" ] && /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$1/Contents/Info.plist" 2>/dev/null; true; }

# May an app with bundle ID $1 replace what is at $2? Prints the reason and fails when not.
#   - nothing there yet: yes
#   - a Mac App Store copy (Contents/_MASReceipt): never, the store updates it
#   - a different bundle ID (or no readable one): never, it is not this app
can_replace() {
  local new_id="$1" dest="$2" old_id
  [ -e "$dest" ] || return 0
  if [ -e "$dest/Contents/_MASReceipt" ]; then
    echo "$dest is a Mac App Store copy, not replacing it"; return 1
  fi
  old_id="$(bundle_id_of "$dest")"
  if [ -z "$old_id" ]; then
    echo "$dest has no readable bundle ID, not replacing it"; return 1
  fi
  if [ "$old_id" != "$new_id" ]; then
    echo "$dest is a different app ($old_id, the build is $new_id), not replacing it"; return 1
  fi
  return 0
}

# With DEPLOY_HOSTS: required for anything that copies to other Macs.
require_hosts() {
  if [ -z "${DEPLOY_HOSTS+set}" ]; then
    echo "deploy: DEPLOY_HOSTS is not set. Set it to the other Macs to update (\"user@host other@host\"), or to an empty" >&2
    echo "        string to update this Mac only. It has no default on purpose." >&2
    exit 2
  fi
}

# The commit an installed Prompter.app was built from (empty for builds made any other way).
revision_of() { [ -f "$1/Contents/Info.plist" ] && /usr/libexec/PlistBuddy -c 'Print :PrompterRevision' "$1/Contents/Info.plist" 2>/dev/null || true; }

case "${1:-}" in
  --check-only)
    new_id="$(bundle_id_of "$APP")"
    if [ -z "$new_id" ]; then
      echo "deploy: no built app at $APP to compare with (build one first, or set DEPLOY_APP)" >&2; exit 2
    fi
    if reason="$(can_replace "$new_id" "$DEST")"; then
      echo "OK: $DEST can be replaced by $new_id"; exit 0
    fi
    echo "REFUSED: $reason"; exit 1 ;;
  --install-agent)
    require_hosts
    mkdir -p "$(dirname "$AGENT_PLIST")"
    cat > "$AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$AGENT_LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$REPO/scripts/deploy-mac.sh</string></array>
  <key>EnvironmentVariables</key><dict><key>DEPLOY_HOSTS</key><string>$DEPLOY_HOSTS</string><key>DEST</key><string>$DEST</string></dict>
  <key>StartInterval</key><integer>600</integer>
  <key>RunAtLoad</key><true/>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>StandardOutPath</key><string>$WORK/deploy.log</string>
  <key>StandardErrorPath</key><string>$WORK/deploy.log</string>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
    echo "deploy: runs every 10 minutes now (log: build/deploy/deploy.log)"
    exit 0 ;;
  --remove-agent)
    launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
    rm -f "$AGENT_PLIST"
    echo "deploy: background runs stopped"
    exit 0 ;;
  "") require_hosts ;;
  *) echo "usage: scripts/deploy-mac.sh [--install-agent | --remove-agent | --check-only]" >&2; exit 2 ;;
esac

# One run at a time (a build can outlast the 10-minute interval).
if ! mkdir "$WORK/lock" 2>/dev/null; then exit 0; fi
trap 'rmdir "$WORK/lock"' EXIT

rev="$(git -C "$REPO" rev-parse main)"
short="${rev:0:7}"

# 1. Build main if the last build is older. A commit that fails to build is tried once, not every 10 minutes.
if [ "$(revision_of "$APP")" != "$rev" ]; then
  if [ "$(cat "$WORK/failed" 2>/dev/null)" = "$rev" ]; then exit 1; fi
  log "building $short"
  if [ -d "$TREE" ]; then
    git -C "$TREE" checkout -q --force --detach "$rev"
  else
    git -C "$REPO" worktree add -q --detach "$TREE" "$rev"
  fi
  cp "$REPO/Config/Local.xcconfig" "$TREE/Config/" 2>/dev/null || true
  if ! (cd "$TREE" && xcodegen generate --quiet &&
        xcodebuild -project Prompter.xcodeproj -scheme PrompterMac "${DEPLOY_BUILD_SETTINGS[@]}" \
          -destination "generic/platform=macOS" -derivedDataPath "$WORK/DerivedData" -quiet \
          PROMPTER_REVISION="$rev" CURRENT_PROJECT_VERSION="$(git -C "$REPO" rev-list --count "$rev")" build); then
    echo "$rev" > "$WORK/failed"
    log "build of $short FAILED; fix main and commit again"
    exit 1
  fi
  log "built $short"
fi

# 2. This Mac.
dest="$DEST"
new_id="$(bundle_id_of "$APP")"
if [ "$(revision_of "$dest")" != "$rev" ]; then
  if ! reason="$(can_replace "$new_id" "$dest")"; then
    log "this Mac: $reason"
  elif pgrep -f "$dest/Contents/MacOS/Prompter" >/dev/null; then
    log "this Mac: Prompter is open, updating after it's quit"
  else
    rm -rf "$dest.new" && ditto "$APP" "$dest.new" && rm -rf "$dest" && mv "$dest.new" "$dest"
    log "this Mac: updated to $short"
  fi
fi

# 3. The other Macs. Asleep or off the network: tried again on the next run.
for host in $DEPLOY_HOSTS; do
  # Back: rev=<installed revision>, id=<its bundle ID>, and "receipt" when it is a Mac App Store copy.
  if ! remote_info="$(ssh "${SSH_OPTS[@]}" "$host" \
      "d=$DEST; echo rev=\$(/usr/libexec/PlistBuddy -c 'Print :PrompterRevision' \"\$d/Contents/Info.plist\" 2>/dev/null); echo id=\$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \"\$d/Contents/Info.plist\" 2>/dev/null); [ -e \"\$d/Contents/_MASReceipt\" ] && echo receipt; [ -e \"\$d\" ] && echo exists; mkdir -p $STAGING")"; then
    log "$host: not reachable, trying again later"
    continue
  fi
  remote_rev="$(printf '%s\n' "$remote_info" | sed -n 's/^rev=//p')"
  remote_id="$(printf '%s\n' "$remote_info" | sed -n 's/^id=//p')"
  if printf '%s\n' "$remote_info" | grep -qx receipt; then
    log "$host: $DEST is a Mac App Store copy, not replacing it"; continue
  fi
  if printf '%s\n' "$remote_info" | grep -qx exists && [ -z "$remote_id" ]; then
    log "$host: $DEST has no readable bundle ID, not replacing it"; continue
  fi
  if [ -n "$remote_id" ] && [ "$remote_id" != "$new_id" ]; then
    log "$host: $DEST is a different app ($remote_id, the build is $new_id), not replacing it"; continue
  fi
  [ "$remote_rev" = "$rev" ] && continue
  if ! rsync -a --delete -e "ssh ${SSH_OPTS[*]}" "$APP/" "$host:$STAGING/Prompter.app/"; then
    log "$host: copy failed, trying again later"
    continue
  fi
  result="$(ssh "${SSH_OPTS[@]}" "$host" /bin/bash -s <<EOF
set -e
dest=$DEST
if pgrep -f "\$dest/Contents/MacOS/Prompter" >/dev/null; then echo "Prompter is open, updating after it's quit"; exit 0; fi
rm -rf "\$dest.new" && ditto ~/$STAGING/Prompter.app "\$dest.new" && rm -rf "\$dest" && mv "\$dest.new" "\$dest"
echo "updated to $short"
EOF
  )" || result="install failed, trying again later"
  log "$host: $result"
done
