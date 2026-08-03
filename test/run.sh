#!/usr/bin/env bash
# Canopy test suite. Run: bash test/run.sh
set -uo pipefail

CANOPY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANOPY="$CANOPY_ROOT/bin/canopy"
PASS=0; FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
assert_eq()   { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=[%s] got=[%s]\n' "$3" "$2"; }; }
assert_file() { [ -f "$1" ] && ok "file exists: $1" || bad "missing file: $1"; }
assert_ok()   { if "$@" >/dev/null 2>&1; then ok "cmd ok: $*"; else bad "cmd failed: $*"; fi; }
assert_fail() { if "$@" >/dev/null 2>&1; then bad "cmd should have failed: $*"; else ok "cmd failed as expected: $*"; fi; }

command -v jq  >/dev/null || { echo "jq required for tests"; exit 1; }
command -v git >/dev/null || { echo "git required for tests"; exit 1; }

new_repo() {
  local d="$WORK/repo-$RANDOM"; mkdir -p "$d"; ( cd "$d"
    git init -q; git config user.email t@t; git config user.name t
    echo hi > f.txt; git add -A; git commit -qm init ) ; echo "$d"
}

echo "== canopy tests =="

# --- init ---
R="$(new_repo)"; cd "$R"
assert_ok "$CANOPY" init
assert_file "$R/.canopy/state.json"
assert_file "$R/.canopy/brief.md"
assert_file "$R/.codex/hooks.json"
assert_eq "state is valid json" "$(jq -e . "$R/.canopy/state.json" >/dev/null 2>&1 && echo yes)" "yes"
assert_eq "default mode guided" "$(jq -r .mode "$R/.canopy/state.json")" "guided"
assert_eq ".canopy gitignored" "$(grep -c '^\.canopy/$' "$R/.gitignore")" "1"
assert_eq "codex hook config valid json" "$(jq -e . "$R/.codex/hooks.json" >/dev/null 2>&1 && echo yes)" "yes"
# idempotent
assert_ok "$CANOPY" init
assert_eq "still one task list" "$(jq '.tasks|length' "$R/.canopy/state.json")" "0"

# --- task add / id / board ---
ID="$("$CANOPY" task add "expose postgres port" 2>/dev/null)"
assert_eq "first id is t1" "$ID" "t1"
assert_file "$R/.canopy/tasks/t1.json"
assert_eq "task on board" "$(jq -r '.tasks[0].title' "$R/.canopy/state.json")" "expose postgres port"
assert_eq "task starts planning" "$(jq -r '.tasks[0].status' "$R/.canopy/state.json")" "planning"
assert_eq "task detail starts with null agent" "$(jq -r '.agent // "null"' "$R/.canopy/tasks/t1.json")" "null"
assert_eq "task detail starts with null worker_pid" "$(jq -r '.worker_pid // "null"' "$R/.canopy/tasks/t1.json")" "null"
ID2="$("$CANOPY" task add "second" 2>/dev/null)"
assert_eq "second id is t2" "$ID2" "t2"

# --- status transitions + validation ---
assert_ok "$CANOPY" task status t1 reviewing
assert_eq "status updated on board" "$(jq -r '.tasks[0].status' "$R/.canopy/state.json")" "reviewing"
assert_eq "status updated in detail" "$(jq -r '.status' "$R/.canopy/tasks/t1.json")" "reviewing"
assert_fail "$CANOPY" task status t1 bogus-status
assert_fail "$CANOPY" task status t404 done   # unknown task

# --- set arbitrary field ---
assert_ok "$CANOPY" task set t1 pr 41
assert_eq "pr on board" "$(jq -r '.tasks[0].pr' "$R/.canopy/state.json")" "41"

# --- mode ---
assert_ok "$CANOPY" mode yolo
assert_eq "mode set to yolo" "$("$CANOPY" mode 2>/dev/null)" "yolo"
assert_fail "$CANOPY" mode nonsense

# --- durability: state survives 'shell restart' (fresh process reads it) ---
assert_eq "state persists" "$(bash -c "cd '$R' && '$CANOPY' status 2>&1 | grep -c t1")" "1"

# --- malformed state is caught, not silently clobbered ---
R2="$(new_repo)"; cd "$R2"; "$CANOPY" init >/dev/null 2>&1
echo 'not json{' > "$R2/.canopy/state.json"
assert_fail "$CANOPY" init

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
