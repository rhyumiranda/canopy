#!/usr/bin/env bash
# treehouse lease/return + branch mechanics (deterministic, no LLM). Run: bash test/worktree_test.sh
set -uo pipefail
CANOPY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANOPY="$CANOPY_ROOT/bin/canopy"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=[%s] got=[%s]\n' "$3" "$2"; }; }

command -v treehouse >/dev/null || { echo "SKIP: treehouse not installed"; exit 0; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

echo "== worktree tests =="
R="$WORK/repo"; mkdir -p "$R"; cd "$R"
git init -q; git config user.email t@t; git config user.name t
echo hi > app.txt; git add -A; git commit -qm init; git branch -M main
printf 'max_trees = 8\nroot = "./"\n' > treehouse.toml; git add -A; git commit -qm th

"$CANOPY" init >/dev/null 2>&1
ID="$("$CANOPY" task add "expose postgres port" 2>/dev/null)"

# lease
P="$("$CANOPY" worktree lease "$ID" 2>/dev/null)"
[ -d "$P" ] && ok "lease returned a real dir" || bad "lease path not a dir: $P"
eq "worktree stored on task" "$(jq -r '.worktree' "$R/.canopy/tasks/$ID.json")" "$P"
BR="$(jq -r '.branch' "$R/.canopy/tasks/$ID.json")"
eq "branch is rhyu/<id>-<slug>" "$BR" "rhyu/t1-expose-postgres-port"
eq "worktree is on that branch" "$(git -C "$P" branch --show-current)" "$BR"

# it must be a treehouse worktree, NOT a .claude/worktrees one (ground rule)
case "$P" in *".treehouse/"*) ok "lease is under treehouse pool" ;; *) bad "lease not under treehouse: $P" ;; esac
[ -d "$R/.claude/worktrees" ] && bad "unexpected .claude/worktrees created" || ok "no .claude/worktrees (ground rule holds)"

# path helper
eq "worktree path helper" "$("$CANOPY" worktree path "$ID" 2>/dev/null)" "$P"

# return (clean tree -> should succeed)
if "$CANOPY" worktree return "$ID" >/dev/null 2>&1; then ok "clean worktree returns to pool"; else bad "return failed on clean tree"; fi

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
