#!/usr/bin/env bash
# checkpoint + recovery (no LLM). Run: bash test/recover_test.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANOPY="$ROOT/bin/canopy"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

echo "== checkpoint + recovery =="
R="$WORK/repo"; mkdir -p "$R"; ( cd "$R"; git init -q; git config user.email t@t; git config user.name t; echo x>f; git add -A; git commit -qm i )
cd "$R"; "$CANOPY" init >/dev/null 2>&1

ID="$("$CANOPY" task add "add health endpoint" 2>/dev/null)"
"$CANOPY" task set "$ID" brief "Add GET /health returning 200 ok" >/dev/null
"$CANOPY" task status "$ID" implementing >/dev/null

# checkpoint records where the worker left off
"$CANOPY" task checkpoint "$ID" "route added, tests next" >/dev/null
CK="$(jq -r '.checkpoint.note' "$R/.canopy/tasks/$ID.json")"
[ "$CK" = "route added, tests next" ] && ok "checkpoint recorded on task" || bad "checkpoint not recorded: $CK"
jq -e '.checkpoint.updated' "$R/.canopy/tasks/$ID.json" >/dev/null && ok "checkpoint has timestamp" || bad "checkpoint missing timestamp"

# recover list includes the in-flight task
"$CANOPY" recover list 2>/dev/null | grep -qx "$ID" && ok "recover list includes in-flight task" || bad "recover list missing task"

# recover brief includes intent + checkpoint + resume instruction
BRIEF="$("$CANOPY" recover "$ID" 2>/dev/null)"
echo "$BRIEF" | grep -q "RESUME task $ID" && ok "recover emits resume header" || bad "no resume header"
echo "$BRIEF" | grep -q "Add GET /health" && ok "recover includes original intent" || bad "recover missing intent"
echo "$BRIEF" | grep -q "route added, tests next" && ok "recover includes last checkpoint" || bad "recover missing checkpoint"
echo "$BRIEF" | grep -qi "continue from the checkpoint" && ok "recover says CONTINUE not restart" || bad "recover missing continue instruction"

# a done task is NOT recoverable
ID2="$("$CANOPY" task add "old task" 2>/dev/null)"
"$CANOPY" task status "$ID2" done >/dev/null
"$CANOPY" recover list 2>/dev/null | grep -qx "$ID2" && bad "done task should not be recoverable" || ok "done task excluded from recovery"

# nothing-in-flight case
( cd "$R" && "$CANOPY" task status "$ID" done >/dev/null )
OUT="$("$CANOPY" recover 2>&1)"
echo "$OUT" | grep -qi "nothing in flight" && ok "recover clean when nothing in flight" || bad "recover should report nothing in flight"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
