#!/usr/bin/env bash
# canopy scribe: inspect-then-update ladder — add appends, list numbers, replace
# rewrites in place, rm deletes, dedup skips, the self-governing bar is seeded,
# and bad indices fail loudly. Run: bash test/scribe_test.sh
set -uo pipefail
CANOPY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANOPY="$CANOPY_ROOT/bin/canopy"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
assert_eq()   { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=[%s] got=[%s]\n' "$3" "$2"; }; }
assert_ok()   { if "$@" >/dev/null 2>&1; then ok "cmd ok: $*"; else bad "cmd failed: $*"; fi; }
assert_fail() { if "$@" >/dev/null 2>&1; then bad "cmd should have failed: $*"; else ok "cmd failed as expected: $*"; fi; }
command -v git >/dev/null || { echo "git required"; exit 1; }

new_repo() {
  local d="$WORK/repo-$RANDOM"; mkdir -p "$d"; ( cd "$d"
    git init -q; git config user.email t@t; git config user.name t
    echo hi > f.txt; git add -A; git commit -qm init ) ; echo "$d"
}
entries() { grep -c '^- ' "$1/AGENTS.md" 2>/dev/null || echo 0; }
nth()     { awk -v n="$2" '/^- /{ if(++i==n){ print substr($0,3); exit } }' "$1/AGENTS.md"; }

echo "== canopy scribe =="
R="$(new_repo)"; cd "$R"

# --- add creates the file, seeds the self-governing bar, records the entry ---
assert_ok "$CANOPY" scribe add "first durable fact"
[ -f "$R/AGENTS.md" ] && ok "AGENTS.md created" || bad "AGENTS.md missing"
assert_eq "self-governing bar seeded" "$(grep -c '^## Maintaining this file$' "$R/AGENTS.md")" "1"
assert_eq "one entry" "$(entries "$R")" "1"

# --- dedup: identical add is skipped, not duplicated ---
assert_ok "$CANOPY" scribe add "first durable fact"
assert_eq "dedup keeps one entry" "$(entries "$R")" "1"

# --- add more, list numbers them ---
assert_ok "$CANOPY" scribe add "second fact"
assert_ok "$CANOPY" scribe add "third fact"
assert_eq "three entries" "$(entries "$R")" "3"
assert_eq "list numbers 3 entries" "$("$CANOPY" scribe list 2>/dev/null | grep -c '^ *[0-9]')" "3"

# --- replace rewrites entry 2 in place, count unchanged ---
assert_ok "$CANOPY" scribe replace 2 "second fact, rewritten"
assert_eq "entry 2 rewritten" "$(nth "$R" 2)" "second fact, rewritten"
assert_eq "replace keeps count" "$(entries "$R")" "3"

# --- replace preserves a literal backslash in the fact (ENVIRON, not awk -v) ---
assert_ok "$CANOPY" scribe replace 3 'uses a literal backslash \n here'
assert_eq "backslash kept literally" "$(nth "$R" 3)" 'uses a literal backslash \n here'

# --- rm deletes entry 1, remaining shift down ---
assert_ok "$CANOPY" scribe rm 1
assert_eq "two entries after rm" "$(entries "$R")" "2"
assert_eq "entry 1 is now the old #2" "$(nth "$R" 1)" "second fact, rewritten"

# --- bad indices fail loudly, don't touch the file ---
assert_fail "$CANOPY" scribe replace 9 "nope"
assert_fail "$CANOPY" scribe rm 0
assert_fail "$CANOPY" scribe replace abc "nope"
assert_eq "still two entries after bad ops" "$(entries "$R")" "2"

# --- legacy file with bare bullets and no bar: add self-heals the bar ---
R2="$(new_repo)"; cd "$R2"
printf '# AGENTS.md\n\n- pre-existing legacy entry\n' > "$R2/AGENTS.md"
assert_ok "$CANOPY" scribe add "new fact into legacy file"
assert_eq "bar added to legacy file" "$(grep -c '^## Maintaining this file$' "$R2/AGENTS.md")" "1"
assert_eq "legacy + new = two entries" "$(entries "$R2")" "2"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
