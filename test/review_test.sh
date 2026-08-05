#!/usr/bin/env bash
# review.sh pure helpers (no LLM): JSON extraction + default-branch. Run: bash test/review_test.sh
set -uo pipefail
CANOPY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=[%s] got=[%s]\n' "$3" "$2"; }; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

# source just what we need
CANOPY_ROOT="$CANOPY_ROOT"; export CANOPY_ROOT
. "$CANOPY_ROOT/lib/common.sh"
. "$CANOPY_ROOT/lib/agent.sh"    # _agent_body
. "$CANOPY_ROOT/lib/review.sh"

echo "== review pure-helper tests =="

# reviewer follows the orchestrator harness unless explicitly overridden
unset CANOPY_ORCHESTRATOR_AGENT
eq "reviewer defaults to Claude" "$(_reviewer_agent_default)" "claude"
CANOPY_ORCHESTRATOR_AGENT=codex
eq "reviewer follows Codex orchestrator" "$(_reviewer_agent_default)" "codex"
CANOPY_ORCHESTRATOR_AGENT=claude
eq "reviewer follows Claude orchestrator" "$(_reviewer_agent_default)" "claude"
unset CANOPY_ORCHESTRATOR_AGENT

# _extract_json: bare JSON
eq "bare json" "$(printf '{"verdict":"clean","x":1}' | _extract_json)" '{"verdict":"clean","x":1}'

# _extract_json: fenced json (```json ... ```)
FENCED=$'```json\n{"verdict":"issues","issues":[]}\n```'
eq "fenced json" "$(printf '%s' "$FENCED" | _extract_json | jq -c '.verdict')" '"issues"'

# _extract_json: json with chatty prose around it
CHATTY=$'Here is my verdict:\n{"verdict":"clean","issues":[]}\nThanks!'
eq "chatty json verdict" "$(printf '%s' "$CHATTY" | _extract_json | jq -r '.verdict')" 'clean'

# reviewer agent body loads and mentions the schema (incl. the new fields)
_agent_body reviewer | grep -q '"verdict"'    && ok "reviewer body loads with schema" || bad "reviewer body missing"
_agent_body reviewer | grep -q '"risk_level"' && ok "reviewer body carries risk_level" || bad "reviewer body missing risk_level"
_agent_body reviewer | grep -q '"action"'     && ok "reviewer body carries per-finding action" || bad "reviewer body missing action"

# _review_intent_section: empty when no intent; includes goal+why when present
eq "intent empty when none" "$(_review_intent_section '' '')" ''
INT="$(_review_intent_section 'add /health endpoint' 'LB needs a liveness probe')"
printf '%s' "$INT" | grep -qi 'add /health endpoint' && ok "intent section carries the goal" || bad "intent section missing goal"
printf '%s' "$INT" | grep -qi 'liveness probe'        && ok "intent section carries the why"  || bad "intent section missing why"

# _review_prompt: always includes the diff; folds in intent + provenance when given
P="$(_review_prompt abc123 def456 "$INT" '' 'diff --git a b')"
printf '%s' "$P" | grep -q 'diff --git a b'    && ok "prompt includes the diff"      || bad "prompt missing diff"
printf '%s' "$P" | grep -qi 'add /health'      && ok "prompt folds in intent"        || bad "prompt missing intent"

# _default_branch on a fresh repo -> main
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
( cd "$W"; git init -q; git config user.email t@t; git config user.name t; echo x>f; git add -A; git commit -qm i; git branch -M main )
eq "default branch = main" "$(_default_branch "$W")" "main"

# _review_provenance: empty on first review (no prior head); lists fix commits after
eq "provenance empty w/o prior head" "$(_review_provenance "$W" '')" ''
PREV="$(git -C "$W" rev-parse HEAD)"
eq "provenance empty when head unchanged" "$(_review_provenance "$W" "$PREV")" ''
( cd "$W"; echo y>f; git commit -qam "fix: address review finding" )
PROV="$(_review_provenance "$W" "$PREV")"
printf '%s' "$PROV" | grep -qi 'RE-REVIEW'                 && ok "provenance flags a re-review" || bad "provenance missing re-review flag"
printf '%s' "$PROV" | grep -qi 'address review finding'    && ok "provenance lists the fix commit" || bad "provenance missing fix commit"
eq "provenance empty for unknown prior sha" "$(_review_provenance "$W" 0000000000000000000000000000000000000000)" ''

# _review_base: diff base is the CONFIGURED canopy base, not origin/HEAD (main).
# Reproduces the incident: a task stacked on a configured base (`dev`) got reviewed
# against main, pulling in already-merged commits — the wrong scope.
. "$CANOPY_ROOT/lib/state.sh"   # state_base (canopy base)
CANOPY_BIN="$CANOPY_ROOT/bin/canopy"
RB="$(mktemp -d)"; trap 'rm -rf "$W" "$RB"' EXIT
(
  cd "$RB"
  git init -q; git config user.email t@t; git config user.name t
  echo base0 > f; git add -A; git commit -qm init; git branch -M main
  # dev = the real integration branch tasks stack onto; main gets bloat commits.
  git branch dev
  echo bloat > g; git add -A; git commit -qm "bloat: merged into main, NOT in scope"
  git checkout -q dev
  echo devwork > h; git add -A; git commit -qm "dev: prior work already on the base"
  git checkout -qb feat
  echo featwork > i; git add -A; git commit -qm "feat: the only change under review"
  # origin/HEAD points at main (the auto-detect default) to prove config wins.
  git symbolic-ref refs/remotes/origin/HEAD refs/heads/main
  "$CANOPY_BIN" init >/dev/null 2>&1
  "$CANOPY_BIN" base dev >/dev/null 2>&1
)
DEV_TIP="$(git -C "$RB" rev-parse dev)"
MAIN_MB="$(git -C "$RB" merge-base feat main)"
GOT_BASE="$(cd "$RB" && git checkout -q feat && _review_base "$RB")"
eq "review base = configured base tip (dev), not main" "$GOT_BASE" "$DEV_TIP"
[ "$GOT_BASE" != "$MAIN_MB" ] && ok "review base is NOT the main merge-base (no bloat)" || bad "review base fell back to main"
# The reviewed diff shows only the feature commit, none of the main-only bloat.
DIFF="$(git -C "$RB" diff "$GOT_BASE..feat")"
printf '%s' "$DIFF" | grep -q 'featwork' && ok "review diff contains the change under review" || bad "review diff missing the change"
printf '%s' "$DIFF" | grep -q 'bloat'    && bad "review diff leaked already-merged bloat" || ok "review diff excludes already-merged bloat"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
