#!/usr/bin/env bash
# repo_root() must resolve the MAIN tree from a linked worktree, so `.canopy/`
# (which lives in the main tree) is reachable when a worker runs `canopy` inside
# its leased worktree. Uses raw `git worktree` — no treehouse needed.
# Run: bash test/worktree_canopy_test.sh
set -uo pipefail
CANOPY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANOPY="$CANOPY_ROOT/bin/canopy"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=[%s] got=[%s]\n' "$3" "$2"; }; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

echo "== worktree finds main .canopy =="
R="$WORK/repo"; mkdir -p "$R"; cd "$R"
git init -q; git config user.email t@t; git config user.name t
echo hi > app.txt; git add -A; git commit -qm init; git branch -M main
"$CANOPY" init >/dev/null 2>&1
ID="$("$CANOPY" task add "demo" 2>/dev/null)"

# a LINKED worktree — what treehouse leases, here via raw git
WT="$WORK/wt"; git worktree add -q "$WT" -b feat

# a worker running canopy from inside the worktree must reach the main .canopy/
if ( cd "$WT" && "$CANOPY" task checkpoint "$ID" "wip" ) >/dev/null 2>&1; then
  ok "checkpoint from worktree succeeds"
else
  bad "checkpoint from worktree failed (repo_root not resolving the main tree)"
fi
eq "checkpoint landed in MAIN .canopy" "$(jq -r '.checkpoint.note // "MISSING"' "$R/.canopy/tasks/$ID.json")" "wip"
if ( cd "$WT" && "$CANOPY" status ) >/dev/null 2>&1; then ok "status works from worktree"; else bad "status failed from worktree"; fi

# regression guard: the main tree still resolves itself
if ( cd "$R" && "$CANOPY" status ) >/dev/null 2>&1; then ok "status works from main tree"; else bad "status failed from main tree"; fi
# ...and from a subdir of the main tree
mkdir -p "$R/sub"
if ( cd "$R/sub" && "$CANOPY" status ) >/dev/null 2>&1; then ok "status works from a subdir"; else bad "status failed from a subdir"; fi

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
