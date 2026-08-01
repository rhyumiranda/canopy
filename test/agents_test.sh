#!/usr/bin/env bash
# Validate Canopy agent + command definitions. Run: bash test/agents_test.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

# frontmatter block (between the first two --- lines)
fm() { awk 'NR==1&&$0=="---"{f=1;next} f&&$0=="---"{exit} f{print}' "$1"; }
has() { fm "$1" | grep -qiE "$2"; }

echo "== agent/command definition tests =="

for a in orchestrator worker reviewer; do
  f="$ROOT/agents/$a.md"
  [ -f "$f" ] && ok "exists: agents/$a.md" || { bad "missing agents/$a.md"; continue; }
  has "$f" '^name:' && ok "$a has name" || bad "$a missing name"
  has "$f" '^description:' && ok "$a has description" || bad "$a missing description"
done

# orchestrator MUST NOT have Edit or Write in its tools (scoped edit-deny)
OF="$ROOT/agents/orchestrator.md"
if fm "$OF" | grep -qi '^tools:'; then
  if fm "$OF" | grep -i '^tools:' | grep -qwE 'Edit|Write'; then
    bad "orchestrator tools MUST NOT include Edit/Write"
  else
    ok "orchestrator has no Edit/Write tool (scoped deny)"
  fi
else
  bad "orchestrator must declare a restricted tools list"
fi

# worker MUST forbid -w / worktree isolation in its prompt
grep -qiE '\-w|worktree isolation|git worktree add|EnterWorktree' "$ROOT/agents/worker.md" \
  && ok "worker prompt addresses the no-extra-worktree rule" || bad "worker prompt missing worktree rule"

# reviewer MUST pin a (cheap) model and demand structured JSON
has "$ROOT/agents/reviewer.md" '^model:' && ok "reviewer pins a model" || bad "reviewer missing model"
grep -qi '"verdict"' "$ROOT/agents/reviewer.md" && ok "reviewer specifies structured verdict" || bad "reviewer missing verdict schema"

# /hotfix command exists
[ -f "$ROOT/commands/hotfix.md" ] && ok "commands/hotfix.md exists" || bad "missing /hotfix command"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
