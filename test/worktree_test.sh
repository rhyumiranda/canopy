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
# Neutral prefix: this used to be a hardcoded `rhyu/`, stamping the maintainer's
# handle onto every branch in every user's repo (and this test pinned it there).
eq "branch is canopy/<id>-<slug>" "$BR" "canopy/t1-expose-postgres-port"
eq "worktree is on that branch" "$(git -C "$P" branch --show-current)" "$BR"
case "$BR" in rhyu/*) bad "branch still carries the maintainer's handle" ;; *) ok "branch carries no personal handle" ;; esac

# it must be a treehouse worktree, NOT a .claude/worktrees one (ground rule)
case "$P" in *".treehouse/"*) ok "lease is under treehouse pool" ;; *) bad "lease not under treehouse: $P" ;; esac
[ -d "$R/.claude/worktrees" ] && bad "unexpected .claude/worktrees created" || ok "no .claude/worktrees (ground rule holds)"

# path helper
eq "worktree path helper" "$("$CANOPY" worktree path "$ID" 2>/dev/null)" "$P"

# a repo with its own naming convention can override the prefix
PID="$("$CANOPY" task add "custom prefix" 2>/dev/null)"
CANOPY_BRANCH_PREFIX=feat "$CANOPY" worktree lease "$PID" >/dev/null 2>&1
eq "CANOPY_BRANCH_PREFIX overrides the default" \
   "$(jq -r '.branch' "$R/.canopy/tasks/$PID.json")" "feat/${PID}-custom-prefix"
"$CANOPY" worktree return "$PID" >/dev/null 2>&1 || true

# return (clean tree -> should succeed)
if "$CANOPY" worktree return "$ID" >/dev/null 2>&1; then ok "clean worktree returns to pool"; else bad "return failed on clean tree"; fi

# a configured base branch is what the feature branch is cut from (not main)
git -C "$R" branch develop main
echo devmarker > "$R/devfile"; git -C "$R" add -A; git -C "$R" commit -qm "develop-only commit"
git -C "$R" branch -f develop HEAD          # advance develop past main
git -C "$R" checkout -q main                # keep the pool's default on main
DEVTIP="$(git -C "$R" rev-parse develop)"
"$CANOPY" base develop >/dev/null 2>&1
ID2="$("$CANOPY" task add "cut from develop" 2>/dev/null)"
P2="$("$CANOPY" worktree lease "$ID2" 2>/dev/null)"
# no origin in this fixture -> lease anchors to the LOCAL base branch (develop)
eq "feature branch cut from the configured base (develop)" \
   "$(git -C "$P2" merge-base HEAD develop)" "$DEVTIP"
"$CANOPY" worktree return "$ID2" >/dev/null 2>&1 || true

# --- container repo detection (t17): a thin outer repo wrapping the real project
# in a nested git repo must fail fast, not silently lease the empty container ---
C="$WORK/container"; mkdir -p "$C/backend"; cd "$C"
git init -q; git config user.email t@t; git config user.name t
printf '# container\n' > AGENTS.md; git add -A; git commit -qm init; git branch -M main
printf 'max_trees = 8\nroot = "./"\n' > treehouse.toml; git add -A; git commit -qm th
# the real project: its own independent git repo in a subdirectory
( cd backend && git init -q && git config user.email t@t && git config user.name t \
  && echo code > main.go && git add -A && git commit -qm init ) >/dev/null 2>&1

"$CANOPY" init >/dev/null 2>&1
CID="$("$CANOPY" task add "build the thing" 2>/dev/null)"

COUT="$("$CANOPY" worktree lease "$CID" 2>&1)"; CRC=$?
[ "$CRC" -ne 0 ] && ok "lease fails fast on a container repo" || bad "lease did not fail on container"
case "$COUT" in *backend*) ok "error names the nested sub-repo" ;; *) bad "error omits sub-repo path: $COUT" ;; esac
case "$COUT" in *"sub-repo"*) ok "error is actionable (points at the sub-repo)" ;; *) bad "error not actionable: $COUT" ;; esac
eq "no worktree recorded when lease is refused" "$(jq -r '.worktree // empty' "$C/.canopy/tasks/$CID.json")" ""

# escape hatch: CANOPY_ALLOW_CONTAINER=1 leases the outer repo anyway
BOUT="$(CANOPY_ALLOW_CONTAINER=1 "$CANOPY" worktree lease "$CID" 2>/dev/null)"; BRC=$?
{ [ "$BRC" -eq 0 ] && [ -d "$BOUT" ]; } && ok "CANOPY_ALLOW_CONTAINER=1 bypasses detection" || bad "bypass failed (rc=$BRC): $BOUT"
"$CANOPY" worktree return "$CID" >/dev/null 2>&1 || true

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
