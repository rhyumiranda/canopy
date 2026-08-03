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
. "$CANOPY_ROOT/lib/worker.sh"   # _agent_body
. "$CANOPY_ROOT/lib/review.sh"

echo "== review pure-helper tests =="

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

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
