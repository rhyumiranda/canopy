#!/usr/bin/env bash
# Herdr interactive worker flow with deterministic fake Herdr; both backends.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; CANOPY="$ROOT/bin/canopy"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

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
  workspace\ create) exit 99 ;;
  pane\ current)
    [ "${HERDR_NO_CONTEXT:-0}" = 1 ] && exit 1
    printf '%s\n' '{"jsonrpc":"2.0","id":"rpc-current","result":{"pane":{"pane_id":"current-pane","workspace_id":"ws-existing"}}}' ;;
  tab\ list) printf '%s\n' '[]' ;;
  tab\ create) printf '%s\n' '{"jsonrpc":"2.0","id":"rpc-tab","result":{"tab":{"tab_id":"tab-'"${HERDR_TAB_N:-1}"'"}}}' ;;
  tab\ get)
    [ "${HERDR_MISMATCH:-0}" = 1 ] && printf '%s\n' '{"result":{"tab":{"label":"other-task · Claude"}}}' || exit 0 ;;
  pane\ list) printf '%s\n' '[]' ;;
  pane\ get)
    [ "${HERDR_PANE_GET_FAIL:-}" = "${3:-}" ] && exit 1
    [ "${HERDR_MISMATCH:-0}" = 1 ] && printf '%s\n' '{"result":{"pane":{"agent":"canopy-other-task-claude"}}}' || exit 0 ;;
  agent\ start)
    if [ "${3:-}" = codex ]; then
      while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
      [ "${1:-}" = "--" ] && shift
      "$@" >/dev/null 2>&1 || exit $?
      printf '%s\n' '{"jsonrpc":"2.0","id":"rpc-codex","result":{"pane":{"pane_id":"pane-codex"},"agent_session_id":"herdr-codex"}}'
    else
      printf '%s\n' '{"jsonrpc":"2.0","id":"rpc-claude","result":{"pane":{"pane_id":"pane-claude"},"agent_session_id":"herdr-claude"}}'
    fi ;;
  agent\ explain) printf '%s\n' '{"state":"working","summary":"bounded worker summary"}' ;;
  agent\ read) printf '%s\n' 'full worker context' ;;
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

R="$WORK/repo"; mkdir -p "$R"; (cd "$R" && git init -q && git config user.email t@t && git config user.name t && echo hi > f && git add f && git commit -qm init)
cd "$R"
ENV="HERDR_LOG=$WORK/herdr.log CODEX_ARGV_LOG=$WORK/codex.argv CODEX_STDIN_LOG=$WORK/codex.stdin PATH=$WORK/bin:$PATH CANOPY_HERDR_BIN=$WORK/bin/herdr"
eval "$ENV \"$CANOPY\" init >/dev/null 2>&1"
ID="$(eval "$ENV \"$CANOPY\" task add 'interactive worker' 2>/dev/null")"
eval "$ENV \"$CANOPY\" task set $ID brief 'do the work' >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID worktree $R >/dev/null 2>&1"
TF="$R/.canopy/tasks/$ID.json"
eval "$ENV HERDR_TAB_N=1 \"$CANOPY\" worker start --agent claude --workspace ws-existing $ID >/dev/null 2>&1" && ok 'Claude start creates Herdr tab' || bad 'Claude start failed'
[ "$(jq -r .herdr_workspace_id "$TF")" = ws-existing ] && ok 'existing workspace id persisted' || bad 'workspace id missing'
[ "$(jq -r .herdr_tab_id "$TF")" = tab-1 ] && ok 'Claude tab id persisted' || bad 'tab id missing'
[ "$(jq -r .herdr_pane_id "$TF")" = pane-claude ] && ok 'Claude pane id persisted' || bad 'pane id missing'
jq -e '.herdr_tab_id | startswith("rpc-") | not' "$TF" >/dev/null && ok 'Claude ignores RPC tab id' || bad 'Claude stored RPC tab id'
jq -e '.herdr_pane_id | startswith("rpc-") | not' "$TF" >/dev/null && ok 'Claude ignores RPC pane id' || bad 'Claude stored RPC pane id'
[ "$(grep -c 'workspace create' "$WORK/herdr.log")" = 0 ] && ok 'never creates a workspace' || bad 'workspace was created'
grep -q 'tab create.*--workspace ws-existing' "$WORK/herdr.log" && ok 'tab reuses existing workspace' || bad 'tab did not use workspace'
grep -q -- 'agent start claude.*claude --dangerously-skip-permissions' "$WORK/herdr.log" && ok 'Claude adapter launches Claude' || bad 'Claude adapter argv wrong'
grep -q -- 'agent start claude.*--dangerously-bypass-approvals-and-sandbox' "$WORK/herdr.log" && bad 'Claude adapter should not get Codex bypass' || ok 'Claude adapter unchanged'
grep -q -- 'tab create.*--label t1 · Claude' "$WORK/herdr.log" && ok 'Claude tab label includes backend' || bad 'Claude tab label wrong'
eval "$ENV HERDR_TAB_N=1 \"$CANOPY\" worker start --agent claude --workspace ws-existing $ID >/dev/null 2>&1"
[ "$(grep -c 'agent start claude' "$WORK/herdr.log")" = 1 ] && ok 'duplicate start does not relaunch' || bad 'duplicate worker launched'

ID2="$(eval "$ENV \"$CANOPY\" task add 'codex worker' 2>/dev/null")"
eval "$ENV \"$CANOPY\" task set $ID2 worktree $R >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID2 brief 'do codex work' >/dev/null 2>&1"
eval "$ENV HERDR_TAB_N=2 \"$CANOPY\" worker start --agent codex --workspace ws-existing $ID2 >/dev/null 2>&1" && ok 'Codex start creates Herdr tab' || bad 'Codex start failed'
TF2="$R/.canopy/tasks/$ID2.json"
[ "$(jq -r .herdr_pane_id "$TF2")" = pane-codex ] && ok 'Codex pane id persisted' || bad 'Codex pane id missing'
jq -e '.herdr_tab_id | startswith("rpc-") | not' "$TF2" >/dev/null && ok 'Codex ignores RPC tab id' || bad 'Codex stored RPC tab id'
jq -e '.herdr_pane_id | startswith("rpc-") | not' "$TF2" >/dev/null && ok 'Codex ignores RPC pane id' || bad 'Codex stored RPC pane id'
grep -q -- 'agent start codex.*codex .* exec --json' "$WORK/herdr.log" && ok 'Codex adapter launches Codex' || bad 'Codex adapter argv wrong'
CODEX_START_LINE="$(grep 'agent start codex' "$WORK/herdr.log" | tail -1)"
[ "$(printf '%s\n' "$CODEX_START_LINE" | grep -o -- '--dangerously-bypass-approvals-and-sandbox' | wc -l | tr -d ' ')" = 1 ] && ok 'Codex Herdr start has one bypass flag' || bad 'Codex Herdr start bypass count wrong'
printf '%s\n' "$CODEX_START_LINE" | grep -q -- ' -a ' && bad 'Codex Herdr start should not pass approval flag' || ok 'Codex Herdr start omits approval flag'
grep -q 'Task t2: codex worker' "$WORK/codex.stdin" && ok 'Codex Herdr start stdin has task title' || bad 'Codex Herdr start stdin missing title'
grep -q 'do codex work' "$WORK/codex.stdin" && ok 'Codex Herdr start stdin has brief' || bad 'Codex Herdr start stdin missing brief'
grep -q -- 'tab create.*--label t2 · Codex' "$WORK/herdr.log" && ok 'Codex tab label includes backend' || bad 'Codex tab label wrong'
eval "$ENV \"$CANOPY\" task checkpoint $ID2 'route added, tests next' >/dev/null 2>&1"
: > "$WORK/codex.stdin"
eval "$ENV HERDR_PANE_GET_FAIL=pane-codex \"$CANOPY\" worker resume --workspace ws-existing $ID2 >/dev/null 2>&1" && ok 'Codex Herdr resume relaunches stale pane' || bad 'Codex Herdr resume failed'
CODEX_RESUME_LINE="$(grep 'agent start codex' "$WORK/herdr.log" | tail -1)"
[ "$(printf '%s\n' "$CODEX_RESUME_LINE" | grep -o -- '--dangerously-bypass-approvals-and-sandbox' | wc -l | tr -d ' ')" = 1 ] && ok 'Codex Herdr resume has one bypass flag' || bad 'Codex Herdr resume bypass count wrong'
printf '%s\n' "$CODEX_RESUME_LINE" | grep -q -- ' -a ' && bad 'Codex Herdr resume should not pass approval flag' || ok 'Codex Herdr resume omits approval flag'
grep -q 'Task t2: codex worker' "$WORK/codex.stdin" && ok 'Codex Herdr resume stdin has task title' || bad 'Codex Herdr resume stdin missing title'
grep -q 'do codex work' "$WORK/codex.stdin" && ok 'Codex Herdr resume stdin has brief' || bad 'Codex Herdr resume stdin missing brief'
grep -q 'route added, tests next' "$WORK/codex.stdin" && ok 'Codex Herdr resume stdin has checkpoint' || bad 'Codex Herdr resume stdin missing checkpoint'
STATUS="$(eval "$ENV \"$CANOPY\" worker status $ID2 2>/dev/null")"
printf '%s\n' "$STATUS" | jq -e '.task=="t2" and .backend=="codex" and .state=="working" and .summary=="bounded worker summary" and .full_context=="canopy worker read t2"' >/dev/null \
  && ok 'worker status is bounded structured data' || bad 'worker status is not structured or bounded'
eval "$ENV \"$CANOPY\" worker read $ID2 --lines 12 2>/dev/null" | grep -qx 'full worker context' \
  && ok 'worker read provides fuller context' || bad 'worker read missing fuller context'
if eval "$ENV \"$CANOPY\" worker close $ID2 >/dev/null 2>&1"; then bad 'close must require ready_for_review'; else ok 'close blocks before ready_for_review'; fi
eval "$ENV \"$CANOPY\" task checkpoint $ID2 ready_for_review >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" worker close $ID2 >/dev/null 2>&1" && ok 'close validates and closes' || bad 'close failed after ready_for_review'
[ "$(jq -r .status "$TF2")" = done ] && ok 'close marks task done' || bad 'task not done'

eval "$ENV \"$CANOPY\" task checkpoint $ID 'continue in Codex' >/dev/null 2>&1"
eval "$ENV HERDR_TAB_N=3 \"$CANOPY\" worker resume --agent codex --workspace ws-existing $ID >/dev/null 2>&1" && ok 'Claude task resumes through Codex' || bad 'Claude-to-Codex resume failed'
[ "$(jq -r .herdr_pane_id "$TF")" = pane-codex ] && ok 'backend switch replaces persisted pane' || bad 'backend switch reused old pane'
[ "$(grep -c 'agent start codex' "$WORK/herdr.log")" = 3 ] && ok 'backend switch starts requested backend' || bad 'backend switch did not start Codex'
grep -q 'continue in Codex' "$WORK/codex.stdin" && ok 'Claude-to-Codex resume carries checkpoint' || bad 'Claude-to-Codex resume lost checkpoint'

ID4="$(eval "$ENV \"$CANOPY\" task add 'identity check' 2>/dev/null")"
eval "$ENV \"$CANOPY\" task set $ID4 worktree $R >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID4 agent claude >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID4 herdr_workspace_id ws-existing >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID4 herdr_tab_id tab-stale >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID4 herdr_pane_id pane-stale >/dev/null 2>&1"
eval "$ENV HERDR_MISMATCH=1 \"$CANOPY\" worker start --agent claude --workspace ws-existing $ID4 >/dev/null 2>&1" \
  && ok 'mismatched persisted Herdr identity relaunches' || bad 'mismatched Herdr identity was reused'

R2="$WORK/no-context"; mkdir -p "$R2"; (cd "$R2" && git init -q && git config user.email t@t && git config user.name t && echo x > f && git add f && git commit -qm init && eval "$ENV \"$CANOPY\" init >/dev/null 2>&1")
ID3="$(cd "$R2" && eval "$ENV \"$CANOPY\" task add no-context 2>/dev/null")"
(cd "$R2" && eval "$ENV \"$CANOPY\" task set $ID3 worktree $R2 >/dev/null 2>&1")
if (cd "$R2" && eval "HERDR_NO_CONTEXT=1 $ENV \"$CANOPY\" worker start --agent claude $ID3 >/dev/null 2>&1"); then bad 'missing workspace context should fail'; else ok 'missing workspace context fails clearly'; fi
if (cd "$R2" && eval "$ENV \"$CANOPY\" worker start --agent claude --workspace ws-missing $ID3 >/dev/null 2>&1"); then bad 'invalid explicit workspace should fail'; else ok 'invalid explicit workspace fails clearly'; fi

printf '\n== %s passed, %s failed ==\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]
