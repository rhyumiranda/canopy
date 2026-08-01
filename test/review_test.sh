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

# reviewer agent body loads and mentions the schema
_agent_body reviewer | grep -q '"verdict"' && ok "reviewer body loads with schema" || bad "reviewer body missing"

# _default_branch on a fresh repo -> main
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
( cd "$W"; git init -q; git config user.email t@t; git config user.name t; echo x>f; git add -A; git commit -qm i; git branch -M main )
eq "default branch = main" "$(_default_branch "$W")" "main"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
