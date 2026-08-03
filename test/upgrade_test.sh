#!/usr/bin/env bash
# canopy upgrade: from any directory, pulls the recorded source checkout to latest
# origin/main and reinstalls the snapshot. Built with git's own machinery (clone
# the repo -> bare origin) so it's platform-stable; sandboxed via $HOME.
# Run: bash test/upgrade_test.sh
set -uo pipefail
CANOPY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
command -v git >/dev/null || { echo "git required"; exit 1; }
command -v jq  >/dev/null || { echo "jq required";  exit 1; }
ver() { sed -n 's/^CANOPY_VERSION="\([^"]*\)".*/\1/p' "$1/lib/common.sh" | head -1; }

echo "== canopy upgrade =="

# --- failure path: no install record ---
H0="$WORK/h0"; mkdir -p "$H0"
if HOME="$H0" bash "$CANOPY_ROOT/bin/canopy" upgrade >/dev/null 2>&1; then
  bad "upgrade with no .source should fail"
else ok "upgrade fails cleanly with no install record"; fi

# --- source checkout S = a real clone of this repo, on main, tracking a bare origin ---
# Overlay the current working tree files so the test exercises the in-progress code,
# not just the last committed state.
S="$WORK/src"; git clone -q "$CANOPY_ROOT" "$S"; S="$(cd "$S" && pwd -P)"
tar -C "$CANOPY_ROOT" --exclude .git -cf - . | tar -C "$S" -xf -
git -C "$S" config user.email t@t; git -C "$S" config user.name t
git -C "$S" add -A
if ! git -C "$S" diff --cached --quiet; then
  git -C "$S" commit -qm "overlay current tree"
fi
git -C "$S" checkout -q -B main
sed -i.bak 's/CANOPY_VERSION="[^"]*"/CANOPY_VERSION="8.8.8"/' "$S/lib/common.sh"; rm -f "$S/lib/common.sh.bak"
git -C "$S" commit -qam "stable version"
git -C "$S" checkout -q -B rhyu/experimental-codex-package
sed -i.bak 's/CANOPY_VERSION="[^"]*"/CANOPY_VERSION="9.9.8"/' "$S/lib/common.sh"; rm -f "$S/lib/common.sh.bak"
git -C "$S" commit -qam "preview version"
ORIGIN="$WORK/origin.git"; git clone -q --bare "$S" "$ORIGIN"
git -C "$S" remote set-url origin "$ORIGIN"
git -C "$S" push -q -u origin main rhyu/experimental-codex-package 2>/dev/null
git -C "$S" checkout -q main

# --- install from S into a sandbox HOME (records .source) ---
H="$WORK/home"; mkdir -p "$H"
CANOPY_ROOT="$S" CANOPY_CHANNEL_UPSTREAM="$ORIGIN" HOME="$H" "$S/bin/canopy" setup --channel codex-preview >/dev/null 2>&1
APP="$H/.local/share/canopy"
[ "$(cat "$APP/.source" 2>/dev/null)" = "$APP/source" ] && ok "setup records the managed source checkout" || bad "no/incorrect .source record"
[ -d "$APP/source/.git" ] && ok "setup creates the managed source clone" || bad "managed source clone missing"
[ "$(cat "$APP/.channel" 2>/dev/null)" = "codex-preview" ] && ok "setup records the install channel" || bad "no/incorrect .channel record"
[ "$(cat "$APP/.channel-ref" 2>/dev/null)" = "rhyu/experimental-codex-package" ] && ok "setup records the install ref" || bad "no/incorrect .channel-ref record"
[ "$(ver "$APP")" = "9.9.8" ] && ok "preview install starts on preview branch version" || bad "preview install not on preview branch version"

# --- advance origin preview branch via a second clone (bump the version) ---
C="$WORK/clone"; git clone -q "$ORIGIN" "$C"
git -C "$C" config user.email t@t; git -C "$C" config user.name t
git -C "$C" checkout -q rhyu/experimental-codex-package
sed -i.bak 's/CANOPY_VERSION="[^"]*"/CANOPY_VERSION="9.9.9"/' "$C/lib/common.sh"; rm -f "$C/lib/common.sh.bak"
git -C "$C" commit -qam "bump preview to 9.9.9"; git -C "$C" push -q origin rhyu/experimental-codex-package

# --- upgrade from an unrelated cwd, via the installed PATH symlink ---
[ "$(ver "$APP/source")" != "9.9.9" ] && ok "managed source is behind before upgrade" || bad "source already at target"
( cd "$WORK" && HOME="$H" "$H/.local/bin/canopy" upgrade >/dev/null 2>&1 ) || bad "upgrade command failed"
[ "$(ver "$APP/source")" = "9.9.9" ]   && ok "managed source fast-forwarded to latest preview" || bad "source not upgraded"
[ "$(ver "$APP")" = "9.9.9" ] && ok "snapshot reinstalled at new version"   || bad "snapshot not refreshed"
[ "$(cat "$APP/.channel" 2>/dev/null)" = "codex-preview" ] && ok "upgrade preserves the install channel" || bad "upgrade lost install channel"

# --- idempotent: a second upgrade is a no-op ---
OUT="$(cd "$WORK" && HOME="$H" "$H/.local/bin/canopy" upgrade 2>&1)"
printf '%s' "$OUT" | grep -qi 'up to date' && ok "second upgrade reports up to date" || bad "expected 'up to date': $OUT"

# --- uncommitted changes in the source block the upgrade ---
echo dirty >> "$APP/source/lib/common.sh"
if ( cd "$WORK" && HOME="$H" "$H/.local/bin/canopy" upgrade >/dev/null 2>&1 ); then
  bad "upgrade should refuse when the source has uncommitted changes"
else ok "upgrade refuses on a dirty source checkout"; fi

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
