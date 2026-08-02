#!/usr/bin/env bash
# scripts/release.sh — version computation (dry-run, hermetic via CANOPY_VERSION_OVERRIDE).
# No git side effects: --dry-run exits before any tag/commit/push.
# Run: bash test/release_test.sh
set -uo pipefail
CANOPY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REL="$CANOPY_ROOT/scripts/release.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

# new_of <current> <arg> -> the "new:" version release.sh computes (dry-run)
new_of() {
  CANOPY_VERSION_OVERRIDE="$1" bash "$REL" "$2" --dry-run 2>/dev/null \
    | sed -n 's/^new: *\([0-9.]*\).*/\1/p'
}
assert_new() { local got; got="$(new_of "$1" "$2")"; [ "$got" = "$3" ] && ok "$1 + $2 -> $3" || { bad "$1 + $2"; printf '       want=%s got=%s\n' "$3" "$got"; }; }

echo "== release.sh version bump =="

# SemVer component bumps
assert_new "0.1.0"     patch "0.1.1"
assert_new "0.1.0"     minor "0.2.0"
assert_new "0.1.0"     major "1.0.0"
assert_new "1.2.3"     patch "1.2.4"
assert_new "1.9.9"     minor "1.10.0"

# a -dev/-pre suffix is stripped before bumping
assert_new "0.1.0-dev" patch "0.1.1"
assert_new "0.1.0-dev" minor "0.2.0"

# explicit version passes through verbatim
assert_new "0.1.0"     2.3.4 "2.3.4"

# dry-run must not create tags or commits (it exits before git)
before="$(git -C "$CANOPY_ROOT" rev-parse HEAD 2>/dev/null || echo none)"
CANOPY_VERSION_OVERRIDE=9.9.9 bash "$REL" patch --dry-run >/dev/null 2>&1
after="$(git -C "$CANOPY_ROOT" rev-parse HEAD 2>/dev/null || echo none)"
[ "$before" = "$after" ] && ok "dry-run makes no commit" || bad "dry-run moved HEAD"

# bad args fail loudly
if bash "$REL" 2>/dev/null;            then bad "no-arg should fail"; else ok "no-arg fails"; fi
if bash "$REL" bogus --dry-run 2>/dev/null; then bad "bad arg should fail"; else ok "bad arg fails"; fi

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
