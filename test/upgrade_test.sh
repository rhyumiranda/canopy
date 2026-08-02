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
ver() { sed -n 's/^CANOPY_VERSION="\(.*\)"/\1/p' "$1/lib/common.sh" | head -1; }

echo "== canopy upgrade =="

# --- failure path: no install record ---
H0="$WORK/h0"; mkdir -p "$H0"
if HOME="$H0" bash "$CANOPY_ROOT/bin/canopy" upgrade >/dev/null 2>&1; then
  bad "upgrade with no .source should fail"
else ok "upgrade fails cleanly with no install record"; fi

# --- source checkout S = a real clone of this repo, on main, tracking a bare origin ---
S="$WORK/src"; git clone -q "$CANOPY_ROOT" "$S"; S="$(cd "$S" && pwd -P)"
git -C "$S" config user.email t@t; git -C "$S" config user.name t
git -C "$S" checkout -q -B main
ORIGIN="$WORK/origin.git"; git clone -q --bare "$S" "$ORIGIN"
git -C "$S" remote set-url origin "$ORIGIN"
git -C "$S" push -q -u origin main 2>/dev/null

# --- install from S into a sandbox HOME (records .source) ---
H="$WORK/home"; mkdir -p "$H"
CANOPY_ROOT="$S" HOME="$H" "$S/bin/canopy" setup >/dev/null 2>&1
APP="$H/.local/share/canopy"
[ "$(cat "$APP/.source" 2>/dev/null)" = "$S" ] && ok "setup records the source checkout" || bad "no/incorrect .source record"

# --- advance origin main via a second clone (bump the version) ---
C="$WORK/clone"; git clone -q "$ORIGIN" "$C"
git -C "$C" config user.email t@t; git -C "$C" config user.name t
sed -i.bak 's/^CANOPY_VERSION=.*/CANOPY_VERSION="9.9.9"/' "$C/lib/common.sh"; rm -f "$C/lib/common.sh.bak"
git -C "$C" commit -qam "bump to 9.9.9"; git -C "$C" push -q origin main

# --- upgrade from an unrelated cwd, via the installed PATH symlink ---
[ "$(ver "$S")" != "9.9.9" ] && ok "source is behind before upgrade" || bad "source already at target"
( cd "$WORK" && HOME="$H" "$H/.local/bin/canopy" upgrade >/dev/null 2>&1 ) || bad "upgrade command failed"
[ "$(ver "$S")" = "9.9.9" ]   && ok "source fast-forwarded to latest main" || bad "source not upgraded"
[ "$(ver "$APP")" = "9.9.9" ] && ok "snapshot reinstalled at new version"   || bad "snapshot not refreshed"

# --- idempotent: a second upgrade is a no-op ---
OUT="$(cd "$WORK" && HOME="$H" "$H/.local/bin/canopy" upgrade 2>&1)"
printf '%s' "$OUT" | grep -qi 'up to date' && ok "second upgrade reports up to date" || bad "expected 'up to date': $OUT"

# --- uncommitted changes in the source block the upgrade ---
echo dirty >> "$S/lib/common.sh"
if ( cd "$WORK" && HOME="$H" "$H/.local/bin/canopy" upgrade >/dev/null 2>&1 ); then
  bad "upgrade should refuse when the source has uncommitted changes"
else ok "upgrade refuses on a dirty source checkout"; fi

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
