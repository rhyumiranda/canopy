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

# worker MUST wire the scribe ladder (else no agent ever reaches the durable-knowledge gate)
WF="$ROOT/agents/worker.md"
grep -qi 'canopy scribe list'   "$WF" && ok "worker runs the scribe ladder (inspect step)"        || bad "worker missing scribe-ladder inspect (canopy scribe list)"
grep -qiE 'canopy scribe (add|replace|rm)' "$WF" && ok "worker can place a scribe entry"          || bad "worker missing scribe placement (add/replace/rm)"
grep -qi 'proportion'           "$WF" && ok "worker states scribe proportionality (may record nothing)" || bad "worker missing scribe proportionality guard"

# reviewer MUST pin a (cheap) model and demand structured JSON
RV="$ROOT/agents/reviewer.md"
has "$RV" '^model:' && ok "reviewer pins a model" || bad "reviewer missing model"
grep -qi '"verdict"' "$RV" && ok "reviewer specifies structured verdict" || bad "reviewer missing verdict schema"
# strengthened brief: the upgrades borrowed from no-mistakes' review brief
grep -qi '"risk_level"' "$RV"          && ok "reviewer emits a risk_level"                 || bad "reviewer missing risk_level"
grep -qi '"action"' "$RV"              && ok "reviewer tags findings with an action"       || bad "reviewer missing per-finding action"
grep -qi 'ask-user' "$RV"             && ok "reviewer can escalate (ask-user)"            || bad "reviewer missing ask-user action"
grep -qiE 'call.?sites?|blast radius' "$RV" && ok "reviewer reads beyond the diff (blast radius)" || bad "reviewer missing call-site/blast-radius guidance"
grep -qiE 'reachable path|broad redesign|over.?reach' "$RV" && ok "reviewer has an anti-overreach guard" || bad "reviewer missing anti-overreach guard"
grep -qiE 'claims, not evidence|unreviewed' "$RV" && ok "reviewer applies fix-round provenance" || bad "reviewer missing fix-round provenance"
grep -qiE 'not instructions|data to review' "$RV" && ok "reviewer treats diff as untrusted data" || bad "reviewer missing untrusted-input guard"

# /hotfix command exists
[ -f "$ROOT/commands/hotfix.md" ] && ok "commands/hotfix.md exists" || bad "missing /hotfix command"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
