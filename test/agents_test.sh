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

# worker MUST carry the anchored-edit (Hashline-equivalent) discipline
grep -qiE 'anchor|re-?Read the (exact )?region|hunk landed' "$WF" && ok "worker states anchored/verified edit discipline" || bad "worker missing anchored-edit discipline"

# --- pre-execution + consult agents (OMO-inspired) ------------------------------
# every new agent file exists and declares name+description (uniform convention)
for a in planner plan-gate oracle researcher reviewer-edge; do
  f="$ROOT/agents/$a.md"
  [ -f "$f" ] && ok "exists: agents/$a.md" || { bad "missing agents/$a.md"; continue; }
  has "$f" '^name:' && ok "$a has name" || bad "$a missing name"
  has "$f" '^description:' && ok "$a has description" || bad "$a missing description"
  has "$f" '^tools:' && ok "$a declares a tools list" || bad "$a missing tools"
done

# planner is READ-ONLY (interview planner, no code) and asks the human
PL="$ROOT/agents/planner.md"
if has "$PL" '^tools:' && has "$PL" '^tools:.*(Edit|Write)'; then
  bad "planner tools MUST NOT include Edit/Write (read-only interview planner)"
else
  ok "planner has no Edit/Write tool (read-only)"
fi
has "$PL" 'AskUserQuestion' && ok "planner can interview the human (AskUserQuestion)" || bad "planner missing AskUserQuestion"
grep -q '\.canopy/plans/' "$PL" && ok "planner writes the plan file into .canopy/plans/" || bad "planner missing .canopy/ plan artifact path"

# plan-gate: fresh reviewer of the plan, structured approve/revise verdict, read-only
PG="$ROOT/agents/plan-gate.md"
if has "$PG" '^tools:.*(Edit|Write)'; then bad "plan-gate MUST be read-only (no Edit/Write)"; else ok "plan-gate is read-only"; fi
grep -q '"verdict"' "$PG" && ok "plan-gate emits a structured verdict" || bad "plan-gate missing verdict schema"
grep -qE '"approve"|"revise"' "$PG" && ok "plan-gate verdict is approve/revise" || bad "plan-gate missing approve/revise"
grep -qi 'feasib' "$PG" && ok "plan-gate judges feasibility" || bad "plan-gate missing feasibility"
grep -qiE 'gap|miss' "$PG" && ok "plan-gate hunts gaps (what did we miss)" || bad "plan-gate missing gap-hunting"
grep -q '\.canopy/plans/' "$PG" && ok "plan-gate reads the plan artifact from .canopy/" || bad "plan-gate missing plan-artifact path"

# oracle: read-only consultant that ADVISES (prose), not a merge verdict
OR="$ROOT/agents/oracle.md"
if has "$OR" '^tools:.*(Edit|Write)'; then bad "oracle MUST be read-only (no Edit/Write)"; else ok "oracle is read-only"; fi
grep -qiE 'advis|guidance|recommend' "$OR" && ok "oracle advises (guidance, not a gate)" || bad "oracle missing advisory framing"

# researcher: evidence-only, pinned to the cheapest model (Haiku), flags no-CLI-path
RS="$ROOT/agents/researcher.md"
if has "$RS" '^tools:.*(Edit|Write)'; then bad "researcher MUST be read-only (no Edit/Write)"; else ok "researcher is read-only"; fi
has "$RS" '^model:.*haiku' && ok "researcher pins the cheapest model (Haiku)" || bad "researcher not pinned to Haiku"
grep -qiE 'cite|evidence|source' "$RS" && ok "researcher is evidence-only (cited)" || bad "researcher missing evidence/citation requirement"
grep -qi 'strips frontmatter' "$RS" && ok "researcher flags the frontmatter-model caveat" || bad "researcher missing model-wiring caveat"

# reviewer-edge: SEPARATE adversarial reviewer, same verdict JSON as the main reviewer
RE="$ROOT/agents/reviewer-edge.md"
if has "$RE" '^tools:.*(Edit|Write)'; then bad "reviewer-edge MUST be read-only (no Edit/Write)"; else ok "reviewer-edge is read-only"; fi
grep -q '"verdict"' "$RE" && ok "reviewer-edge emits the reviewer verdict shape" || bad "reviewer-edge missing verdict"
grep -q '"risk_level"' "$RE" && ok "reviewer-edge carries risk_level" || bad "reviewer-edge missing risk_level"
grep -q '"action"' "$RE" && ok "reviewer-edge tags per-finding action" || bad "reviewer-edge missing action"

# every new agent body loads cleanly through _agent_body (frontmatter strips off)
. "$ROOT/lib/common.sh" 2>/dev/null || true
. "$ROOT/lib/agent.sh"
CANOPY_ROOT="$ROOT"
for a in planner plan-gate oracle researcher reviewer-edge; do
  body="$(_agent_body "$a")"
  [ -n "$body" ] && ok "$a body loads via _agent_body" || bad "$a body empty via _agent_body"
  printf '%s' "$body" | grep -q '^---$' && bad "$a body still contains frontmatter fence" || ok "$a body has frontmatter stripped"
done

# orchestrator references the new pre-execution flow + consults (wiring, not orphans)
grep -qi 'canopy-planner'      "$OF" && ok "orchestrator references the planner"      || bad "orchestrator missing planner wiring"
grep -qi 'canopy-plan-gate'    "$OF" && ok "orchestrator references the plan-gate"    || bad "orchestrator missing plan-gate wiring"
grep -qi 'canopy-oracle'       "$OF" && ok "orchestrator references the oracle"       || bad "orchestrator missing oracle wiring"
grep -qi 'canopy-researcher'   "$OF" && ok "orchestrator references the researcher"   || bad "orchestrator missing researcher wiring"
grep -qi 'canopy-reviewer-edge' "$OF" && ok "orchestrator references the edge reviewer" || bad "orchestrator missing edge-reviewer wiring"

# /hotfix command exists
[ -f "$ROOT/commands/hotfix.md" ] && ok "commands/hotfix.md exists" || bad "missing /hotfix command"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
