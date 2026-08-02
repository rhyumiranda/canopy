#!/usr/bin/env bash
# canopy upgrade: from any directory, pulls the recorded source checkout to latest
# origin/main and reinstalls the snapshot. Uses a bare origin + a source clone,
# sandboxed via $HOME. Run: bash test/upgrade_test.sh
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

# --- bare origin + a source checkout tracking it ---
ORIGIN="$WORK/origin.git"; git init -q --bare "$ORIGIN"
S="$WORK/src"; mkdir -p "$S"; S="$(cd "$S" && pwd -P)"   # physical path: canopy records CANOPY_ROOT via `cd -P` (macOS /var -> /private/var)
for d in bin lib agents commands hooks dist; do cp -R "$CANOPY_ROOT/$d" "$S/$d"; done
( cd "$S"; git init -q; git config user.email t@t; git config user.name t
  git add -A; git commit -qm init; git branch -M main
  git remote add origin "$ORIGIN"; git push -q -u origin main )

# --- install from S into a sandbox HOME (records .source) ---
H="$WORK/home"; mkdir -p "$H"
CANOPY_ROOT="$S" HOME="$H" "$S/bin/canopy" setup >/dev/null 2>&1
APP="$H/.local/share/canopy"
[ "$(cat "$APP/.source" 2>/dev/null)" = "$S" ] && ok "setup records the source checkout" || bad "no/incorrect .source record"

# --- advance origin main via a second clone (bump the version) ---
C="$WORK/clone"; git clone -q "$ORIGIN" "$C"
( cd "$C"; git config user.email t@t; git config user.name t
  sed -i.bak 's/^CANOPY_VERSION=.*/CANOPY_VERSION="9.9.9"/' lib/common.sh; rm -f lib/common.sh.bak
  git commit -qam "bump to 9.9.9"; git push -q origin main )

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
