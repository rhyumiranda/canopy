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

# Herdr-backed Codex tasks recover through worker resume with the stored workspace/backend.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/herdr" <<'EOF'
#!/usr/bin/env bash
set -u
for arg in "$@"; do
  printf '%s ' "$(printf '%s' "$arg" | tr '\n' ' ')" >> "${HERDR_LOG:?}"
done
printf '\n' >> "${HERDR_LOG:?}"
case "$1 ${2:-}" in
  workspace\ get) [ "${3:-}" = ws-existing ] ;;
  tab\ get) printf '%s\n' '{"result":{"tab":{"label":"t2 · Codex"}}}' ;;
  pane\ get) [ "${HERDR_PANE_GET_FAIL:-}" = "${3:-}" ] && exit 1 || printf '%s\n' '{"result":{"pane":{"agent":"canopy-t2-codex"}}}' ;;
  pane\ list) printf '%s\n' '[]' ;;
  agent\ start)
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
    [ "${1:-}" = "--" ] && shift
    "$@" >/dev/null 2>&1 || exit $?
    printf '%s\n' '{"jsonrpc":"2.0","id":"rpc-codex","result":{"pane":{"pane_id":"pane-codex"},"agent_session_id":"herdr-codex"}}' ;;
  agent\ explain) printf '%s\n' '{"state":"working"}' ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$WORK/bin/herdr"
cat > "$WORK/bin/codex" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "${CODEX_ARGV_LOG:?}"
cat >> "${CODEX_STDIN_LOG:?}"
printf '\n' >> "${CODEX_STDIN_LOG:?}"
printf '%s\n' '{"type":"thread.started","thread_id":"codex-thread"}'
EOF
chmod +x "$WORK/bin/codex"

IDH="$("$CANOPY" task add "herdr codex task" 2>/dev/null)"
"$CANOPY" task set "$IDH" brief "resume through Herdr" >/dev/null
"$CANOPY" task set "$IDH" worktree "$R" >/dev/null
"$CANOPY" task set "$IDH" agent codex >/dev/null
"$CANOPY" task set "$IDH" herdr_workspace_id ws-existing >/dev/null
"$CANOPY" task set "$IDH" herdr_tab_id tab-existing >/dev/null
"$CANOPY" task set "$IDH" herdr_pane_id pane-stale >/dev/null
"$CANOPY" task status "$IDH" implementing >/dev/null
"$CANOPY" task checkpoint "$IDH" "fresh review fix next" >/dev/null
BRIEFH="$("$CANOPY" recover "$IDH" 2>/dev/null)"
echo "$BRIEFH" | grep -q "Resume the stored Herdr codex backend" && ok "Herdr recover names stored backend" || bad "Herdr recover missing backend"
echo "$BRIEFH" | grep -q "canopy worker resume --workspace ws-existing $IDH" && ok "Herdr recover uses worker resume with stored workspace" || bad "Herdr recover missing worker resume command"
echo "$BRIEFH" | grep -q "Re-spawn a worker" && bad "Herdr recover should not use generic respawn" || ok "Herdr recover avoids generic respawn"
ENV="HERDR_LOG=$WORK/herdr.log CODEX_ARGV_LOG=$WORK/codex.argv CODEX_STDIN_LOG=$WORK/codex.stdin PATH=$WORK/bin:$PATH CANOPY_HERDR_BIN=$WORK/bin/herdr"
eval "$ENV HERDR_PANE_GET_FAIL=pane-stale \"$CANOPY\" worker resume --workspace ws-existing $IDH >/dev/null 2>&1" && ok "Herdr recover command resumes Codex worker" || bad "Herdr recover command failed"
CODEX_RESUME_LINE="$(tail -1 "$WORK/codex.argv")"
[ "$(printf '%s\n' "$CODEX_RESUME_LINE" | grep -o -- '--dangerously-bypass-approvals-and-sandbox' | wc -l | tr -d ' ')" = 1 ] && ok "Herdr recover Codex resume has one bypass flag" || bad "Herdr recover Codex resume bypass count wrong"
printf '%s\n' "$CODEX_RESUME_LINE" | grep -q -- ' -a ' && bad "Herdr recover Codex resume should not pass approval flag" || ok "Herdr recover Codex resume omits approval flag"
grep -q "fresh review fix next" "$WORK/codex.stdin" && ok "Herdr recover Codex resume includes checkpoint" || bad "Herdr recover Codex resume missing checkpoint"

# a done task is NOT recoverable
ID2="$("$CANOPY" task add "old task" 2>/dev/null)"
"$CANOPY" task status "$ID2" done >/dev/null
"$CANOPY" recover list 2>/dev/null | grep -qx "$ID2" && bad "done task should not be recoverable" || ok "done task excluded from recovery"

# nothing-in-flight case
( cd "$R" && "$CANOPY" task status "$ID" done >/dev/null )
( cd "$R" && "$CANOPY" task status "$IDH" done >/dev/null )
OUT="$("$CANOPY" recover 2>&1)"
echo "$OUT" | grep -qi "nothing in flight" && ok "recover clean when nothing in flight" || bad "recover should report nothing in flight"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
