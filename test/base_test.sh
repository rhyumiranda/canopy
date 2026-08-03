#!/usr/bin/env bash
# base branch control: get/set the integration branch worktrees are cut from
# and PRs/reviews target. Deterministic (no LLM, no treehouse). Run: bash test/base_test.sh
set -uo pipefail
CANOPY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANOPY="$CANOPY_ROOT/bin/canopy"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=[%s] got=[%s]\n' "$3" "$2"; }; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

echo "== base branch control =="

R="$WORK/repo"; mkdir -p "$R"; cd "$R"
git init -q; git config user.email t@t; git config user.name t
echo hi > f; git add -A; git commit -qm init; git branch -M main
git branch develop

# unconfigured -> effective base is the detected default (main)
"$CANOPY" init >/dev/null 2>&1
eq "unconfigured base falls back to default" "$("$CANOPY" base 2>/dev/null)" "main"
eq "state has no base yet" "$(jq -r '.base // "unset"' "$R/.canopy/state.json")" "unset"

# set an explicit base
"$CANOPY" base develop >/dev/null 2>&1
eq "getter returns configured base" "$("$CANOPY" base 2>/dev/null)" "develop"
eq "base persisted in state.json" "$(jq -r '.base' "$R/.canopy/state.json")" "develop"

# base_branch helper honours the config, ignoring auto-detect
CANOPY_ROOT="$CANOPY_ROOT"; export CANOPY_ROOT
. "$CANOPY_ROOT/lib/common.sh"
. "$CANOPY_ROOT/lib/state.sh"
. "$CANOPY_ROOT/lib/review.sh"   # _default_branch (fallback)
( cd "$R" && [ "$(base_branch "$R")" = "develop" ] ) && ok "base_branch() returns the configured base" || bad "base_branch() ignored config"

# setting a nonexistent base warns but still records it (fetched later at lease)
"$CANOPY" base nope-not-here >/dev/null 2>&1
eq "unknown base still recorded" "$(jq -r '.base' "$R/.canopy/state.json")" "nope-not-here"

# init --base on a fresh repo sets it in one shot
R2="$WORK/repo2"; mkdir -p "$R2"; cd "$R2"
git init -q; git config user.email t@t; git config user.name t
echo hi > f; git add -A; git commit -qm init; git branch -M main; git branch develop
"$CANOPY" init --base develop >/dev/null 2>&1
eq "init --base sets the base" "$(jq -r '.base' "$R2/.canopy/state.json")" "develop"

# unknown init flag is rejected
if "$CANOPY" init --bogus >/dev/null 2>&1; then bad "init should reject unknown flags"; else ok "init rejects unknown flags"; fi

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
