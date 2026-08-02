#!/usr/bin/env bash
# canopy must find its own lib/ when invoked via a symlink — `canopy setup`
# installs it as ~/.local/bin/canopy -> <repo>/bin/canopy. Run: bash test/bin_symlink_test.sh
set -uo pipefail
CANOPY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

echo "== canopy via symlink =="

ln -s "$CANOPY_ROOT/bin/canopy" "$WORK/canopy"
# invoke through the symlink, from an unrelated cwd (the real-world PATH case)
if OUT="$( cd / && "$WORK/canopy" version 2>&1 )"; then
  case "$OUT" in canopy\ *) ok "version works via symlink ($OUT)" ;; *) bad "unexpected output: $OUT" ;; esac
else
  bad "canopy failed via symlink: $OUT"
fi

# a chained symlink (symlink -> symlink -> real) must resolve too
ln -s "$WORK/canopy" "$WORK/canopy2"
if ( cd / && "$WORK/canopy2" version ) >/dev/null 2>&1; then ok "resolves a chained symlink"; else bad "chained symlink failed"; fi

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
