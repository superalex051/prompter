#!/usr/bin/env bash
# Fail if the public repo holds a private term.
#
# Checks, against a private denylist:
#   1. the committed contents of every file in HEAD (not the working tree, so local edits can't hide a term),
#   2. file paths in HEAD,
#   3. every line added by a commit not yet on origin/main, even if a later commit removed it
#      (a push publishes all of them),
#   4. the message of every commit not yet on origin/main (git log origin/main..HEAD).
# It warns (never fails) about em or en dashes in those messages and about private terms in author
# or committer identity. Fix a dash warning before pushing.
# A git error (bad allow-path, etc.) exits 2 and never counts as a pass.
#
# The denylist is git-ignored and lives at
#   $(git rev-parse --git-common-dir)/../.inbox/public-denylist.txt
# (override the path with PUBLIC_DENYLIST). Format: one term per line, "#" starts a comment,
# matching is case-insensitive and literal. A line "word: <term>" matches whole words only (for a
# short name that sits inside other words). A line "allow-path: <glob>" exempts matching files from
# the content, path and history checks (for historical files the owner chose to keep); "*" crosses "/".
#
# Output shows file:line and the term masked to its first 3 letters, never the matched text.
#
# Usage: scripts/check-public.sh            run the check, exit 1 on hits
#        scripts/check-public.sh --self-test   run against a temp repo and temp denylist
set -euo pipefail

EM=$(printf '\xe2\x80\x94')
EN=$(printf '\xe2\x80\x93')

mask() { local t="$1"; printf '%s***' "${t:0:3}"; }
trim() { local v="$1"; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"; printf '%s' "$v"; }

# Replace every denylisted term inside stdin lines with its masked form (so a path never leaks a term).
scrub() {
  awk -v tf="$SCRUB_TERMS" 'BEGIN{n=0;while((getline l<tf)>0){t[++n]=tolower(l);m[n]=substr(l,1,3)"***"}}
    {s=$0;for(i=1;i<=n;i++){out="";rest=s;while((p=index(tolower(rest),t[i]))>0){out=out substr(rest,1,p-1) m[i];rest=substr(rest,p+length(t[i]))};s=out rest};print s}'
}

# true if $1 matches one of the allow-path globs
is_allowed() {
  local a
  [ "${#ALLOWS[@]}" -eq 0 ] && return 1
  for a in "${ALLOWS[@]}"; do
    # shellcheck disable=SC2254
    case "$1" in $a) return 0 ;; esac
  done
  return 1
}

run_check() {
  local top common denylist work
  top=$(git rev-parse --show-toplevel)
  cd "$top"
  common=$(cd "$(git rev-parse --git-common-dir)" && pwd)
  denylist="${PUBLIC_DENYLIST:-$common/../.inbox/public-denylist.txt}"
  if [ ! -f "$denylist" ]; then
    echo "check-public: denylist not found: $denylist" >&2
    return 2
  fi

  TERMS=(); KINDS=(); ALLOWS=()
  local line kind
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line=$(trim "$line")
    case "$line" in
      ''|'#'*) continue ;;
      allow-path:*) line=$(trim "${line#allow-path:}"); [ -n "$line" ] && ALLOWS+=("$line") ;;
      word:*) line=$(trim "${line#word:}"); [ -n "$line" ] && { TERMS+=("$line"); KINDS+=("w"); } ;;
      *) TERMS+=("$line"); KINDS+=("f") ;;
    esac
  done < "$denylist"
  if [ "${#TERMS[@]}" -eq 0 ]; then
    echo "check-public: denylist has no terms: $denylist" >&2
    return 2
  fi

  work=$(mktemp -d)
  trap 'rm -rf "$work"' RETURN
  SCRUB_TERMS="$work/terms"
  printf '%s\n' "${TERMS[@]}" > "$SCRUB_TERMS"

  local pathspec=(".") a
  if [ "${#ALLOWS[@]}" -gt 0 ]; then
    for a in "${ALLOWS[@]}"; do pathspec+=(":(exclude)$a"); done
  fi

  local hits=0 i term flags out rc n
  echo "== files in HEAD (committed content; commit or stash edits first) =="
  for i in "${!TERMS[@]}"; do
    term="${TERMS[$i]}"; flags="-F"; [ "${KINDS[$i]}" = w ] && flags="-w -F"
    rc=0
    # shellcheck disable=SC2086
    out=$(git grep -n -a -i $flags -e "$term" HEAD -- "${pathspec[@]}" 2>"$work/err") || rc=$?
    if [ "$rc" -gt 1 ]; then
      echo "check-public: git grep failed (rc $rc): $(scrub < "$work/err")" >&2
      return 2
    fi
    [ "$rc" -eq 1 ] && continue
    while IFS= read -r line; do
      case "$line" in HEAD:*) ;; *) continue ;; esac
      line="${line#HEAD:}"
      echo "$(printf '%s' "$line" | cut -d: -f1,2 | scrub) [$(mask "$term")]"
      hits=$((hits + 1))
    done <<< "$out"
  done

  echo "== file paths in HEAD =="
  git -c core.quotepath=off ls-tree -r --name-only HEAD > "$work/paths"
  for i in "${!TERMS[@]}"; do
    term="${TERMS[$i]}"; flags="-F"; [ "${KINDS[$i]}" = w ] && flags="-w -F"
    # shellcheck disable=SC2086
    while IFS= read -r line; do
      is_allowed "$line" && continue
      echo "path: $(printf '%s' "$line" | scrub) [$(mask "$term")]"
      hits=$((hits + 1))
    done < <(grep -i $flags -e "$term" "$work/paths" || true)
  done

  local range
  if git rev-parse --verify -q refs/remotes/origin/main >/dev/null; then
    range="origin/main..HEAD"
  else
    echo "(no origin/main ref: checking every commit reachable from HEAD)"
    range="HEAD"
  fi

  echo "== lines added by unpushed commits (even if a later commit removed them) =="
  git log -p -U0 --no-color --format='@@C %h' "$range" 2>/dev/null | awk -v meta="$work/meta" -v text="$work/text" '
    /^@@C /{c=$2;next}
    /^\+\+\+ /{f=substr($0,7);next}
    /^\+/{print c ":" f > meta; print substr($0,2) > text}' || true
  : >> "$work/meta"; : >> "$work/text"
  for i in "${!TERMS[@]}"; do
    term="${TERMS[$i]}"; flags="-F"; [ "${KINDS[$i]}" = w ] && flags="-w -F"
    # shellcheck disable=SC2086
    for n in $(grep -n -i $flags -e "$term" "$work/text" | cut -d: -f1 || true); do
      sed -n "${n}p" "$work/meta"
    done | sort -u > "$work/hit.$i"
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      is_allowed "${line#*:}" && continue
      echo "commit ${line%%:*} file $(printf '%s' "${line#*:}" | scrub) (added line) [$(mask "$term")]"
      hits=$((hits + 1))
    done < "$work/hit.$i"
  done

  echo "== unpushed commit messages =="
  local c msg dashwarn=0 idwarn=0 ident
  for c in $(git rev-list "$range"); do
    msg=$(git log -1 --format=%B "$c")
    for i in "${!TERMS[@]}"; do
      term="${TERMS[$i]}"; flags="-F"; [ "${KINDS[$i]}" = w ] && flags="-w -F"
      # shellcheck disable=SC2086
      for n in $(printf '%s\n' "$msg" | grep -n -i $flags -e "$term" | cut -d: -f1 || true); do
        echo "commit $(git rev-parse --short "$c"):$n [$(mask "$term")]"
        hits=$((hits + 1))
      done
    done
    if printf '%s\n' "$msg" | grep -q -F -e "$EM" -e "$EN"; then
      echo "warning: commit $(git rev-parse --short "$c") has an em or en dash in its message (fix before pushing)"
      dashwarn=$((dashwarn + 1))
    fi
    ident=$(git log -1 --format='%an %ae %cn %ce' "$c")
    for i in "${!TERMS[@]}"; do
      term="${TERMS[$i]}"; flags="-F"; [ "${KINDS[$i]}" = w ] && flags="-w -F"
      # shellcheck disable=SC2086
      if printf '%s\n' "$ident" | grep -q -i $flags -e "$term"; then
        echo "warning: commit $(git rev-parse --short "$c") author or committer identity holds a private term [$(mask "$term")]"
        idwarn=$((idwarn + 1))
      fi
    done
  done

  echo "---"
  echo "hits: $hits   dash warnings: $dashwarn   identity warnings: $idwarn"
  if [ "$hits" -gt 0 ]; then
    echo "check-public: FAILED"
    return 1
  fi
  echo "check-public: OK"
}

self_test() {
  local tmp fails=0
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  (
    cd "$tmp"
    git init -q -b main repo
    cd repo
    git config user.email t@example.com
    git config user.name t
    printf 'hello world\n' > a.txt
    git add a.txt
    git commit -q -m "first"
    git update-ref refs/remotes/origin/main HEAD
  )
  cat > "$tmp/deny.txt" <<'EOF'
# comment
  Zebrafoo  
word:Quux
allow-path: legacy/*
EOF
  export PUBLIC_DENYLIST="$tmp/deny.txt"
  cd "$tmp/repo"

  ok() { echo "ok   $1"; }
  bad() { echo "FAIL $1"; fails=$((fails + 1)); }
  expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want rc $2, got $3)"; fi; }
  chk() { set +e; OUT=$(run_check 2>&1); RC=$?; set -e; }
  noleak() { if printf '%s' "$OUT" | grep -q -i -e zebrafoo -e quux; then bad "output leaked a full term: $OUT"; else ok "full term never printed ($1)"; fi; }
  commit() { git add -A; git commit -q -m "$1"; }

  chk; expect "clean repo passes" 0 "$RC"

  printf 'a line with ZEBRAFOO inside\n' > b.txt
  commit "add b"
  chk; expect "committed file with term (any case) fails" 1 "$RC"
  case "$OUT" in *"b.txt:1 [Zeb***]"*) ok "hit shows file:line and masked term" ;; *) bad "hit format: $OUT" ;; esac
  noleak content

  git update-ref refs/remotes/origin/main HEAD
  mkdir legacy
  git mv b.txt legacy/b.txt
  git commit -q -m "move b"
  chk; expect "allow-path glob exempts the file (content and history)" 0 "$RC"
  git rm -q -f legacy/b.txt; git commit -q -m "drop b"

  printf 'Quux\n' > w1.txt; printf "Quux's thing\n" > w2.txt; printf 'scaleQuuxy\n' > w3.txt
  commit "words"
  chk; expect "word term hits Quux and Quux's but not an embedded match" 1 "$RC"
  case "$OUT" in *"w1.txt:1 [Quu***]"*"w2.txt:1 [Quu***]"*) ok "word hits listed" ;; *) bad "word hits: $OUT" ;; esac
  case "$OUT" in *"w3.txt"*) bad "word term matched inside another word" ;; *) ok "word term ignores embedded text" ;; esac
  git rm -q -f w1.txt w2.txt w3.txt; git commit -q -m "drop words"

  git update-ref refs/remotes/origin/main HEAD
  printf 'leak ZebraFoo\n' > c.txt; commit "add c"
  git rm -q c.txt; git commit -q -m "remove c again"
  chk; expect "term added then removed in later unpushed commit still fails" 1 "$RC"
  case "$OUT" in *"(added line) [Zeb***]"*) ok "history hit shown masked" ;; *) bad "history hit format: $OUT" ;; esac
  noleak history
  git update-ref refs/remotes/origin/main HEAD

  printf 'clean\n' > d.txt; commit "add d"
  git update-ref refs/remotes/origin/main HEAD
  printf 'zebrafoo\n' > d.txt; git commit -q -am "d leaks"
  git update-ref refs/remotes/origin/main HEAD
  printf 'clean again\n' > d.txt
  chk; expect "dirty working tree cannot hide a committed term" 1 "$RC"
  git checkout -q d.txt
  git rm -q d.txt; git commit -q -m "drop d"; git update-ref refs/remotes/origin/main HEAD

  printf 'x\n' > zebrafoo-notes.txt; commit "add notes file"
  chk; expect "tracked file name with term fails" 1 "$RC"
  noleak path
  git rm -q zebrafoo-notes.txt; git commit -q -m "drop notes"; git update-ref refs/remotes/origin/main HEAD

  printf 'bin\0zebrafoo\0\n' > e.bin; commit "binary"
  chk; expect "binary file with term fails" 1 "$RC"
  git rm -q e.bin; git commit -q -m "drop bin"; git update-ref refs/remotes/origin/main HEAD

  git commit -q --allow-empty -m "add zebrafoo support"
  chk; expect "unpushed commit message with term fails" 1 "$RC"
  case "$OUT" in *"commit "*"[Zeb***]"*) ok "commit hit is masked" ;; *) bad "commit hit format: $OUT" ;; esac
  noleak message
  git commit -q --allow-empty --amend -m "plain message"
  git update-ref refs/remotes/origin/main HEAD

  git commit -q --allow-empty -m "a message with a dash $EM here"
  chk; expect "dash in message only warns" 0 "$RC"
  case "$OUT" in *"warning: commit"*) ok "dash warning printed" ;; *) bad "no dash warning: $OUT" ;; esac
  git commit -q --allow-empty --amend -m "now fine"
  git update-ref refs/remotes/origin/main HEAD

  git commit -q --allow-empty -m "old term zebrafoo, already described"
  git update-ref refs/remotes/origin/main HEAD
  chk; expect "terms in already-pushed messages are ignored" 0 "$RC"

  printf 'allow-path: ../outside\n' >> "$tmp/deny.txt"
  printf 'zebrafoo\n' > f.txt; commit "add f"
  chk; expect "bad allow-path makes the check error out (rc 2), not pass" 2 "$RC"
  git rm -q f.txt; git commit -q -m "drop f"; git update-ref refs/remotes/origin/main HEAD

  printf '# only a comment\n' > "$tmp/empty.txt"
  PUBLIC_DENYLIST="$tmp/empty.txt" chk; expect "denylist with no terms exits 2" 2 "$RC"
  PUBLIC_DENYLIST="$tmp/nope.txt" chk; expect "missing denylist exits 2" 2 "$RC"

  unset PUBLIC_DENYLIST
  if [ "$fails" -eq 0 ]; then echo "self-test: OK"; return 0; fi
  echo "self-test: $fails failure(s)"
  return 1
}

case "${1:-}" in
  --self-test) self_test ;;
  '') run_check ;;
  *) echo "usage: $0 [--self-test]" >&2; exit 2 ;;
esac
