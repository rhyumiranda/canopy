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
    [ "${HERDR_EMPTY_GET:-0}" = 1 ] && exit 0
    [ "${HERDR_MALFORMED_GET:-0}" = 1 ] && printf '%s\n' '{' && exit 0
    [ "${HERDR_AMBIGUOUS_GET:-0}" = 1 ] && printf '%s\n' '{"result":{"tab":{"label":"t1 · Claude"},"label":"other"}}' && exit 0
    [ -n "${HERDR_EXPECTED_TASK:-}" ] && printf '%s\n' '{"result":{"tab":{"label":"'"${HERDR_EXPECTED_TASK}"' · Claude"}}}' && exit 0
    [ "${HERDR_MISMATCH:-0}" = 1 ] && printf '%s\n' '{"result":{"tab":{"label":"other-task · Claude"}}}' || case "${3:-}" in
      tab-1) printf '%s\n' '{"result":{"tab":{"label":"t1 · Claude"}}}' ;;
      tab-2) printf '%s\n' '{"result":{"tab":{"label":"t2 · Codex"}}}' ;;
      legacy-tab) printf '%s\n' '{"result":{"tab":{"label":"t7 · Claude"}}}' ;;
      tab-partial) printf '%s\n' '{"result":{"tab":{"label":"t11 · Codex"}}}' ;;
      tab-attach) printf '%s\n' '{"result":{"tab":{"label":"t8 · Codex"}}}' ;;
      *) printf '%s\n' '{"result":{"tab":{"label":"t4 · Claude"}}}' ;;
    esac ;;
  pane\ list)
    [ "${HERDR_FOUND_PANE:-0}" = 1 ] && printf '%s\n' '{"result":{"panes":[{"pane_id":"pane-found","agent":"canopy-t8-codex"}]}}' || printf '%s\n' '[]' ;;
  pane\ get)
    [ "${HERDR_PANE_GET_FAIL:-}" = "${3:-}" ] && exit 1
    [ "${HERDR_EMPTY_GET:-0}" = 1 ] && exit 0
    [ "${HERDR_MALFORMED_GET:-0}" = 1 ] && printf '%s\n' '{' && exit 0
    [ "${HERDR_AMBIGUOUS_GET:-0}" = 1 ] && printf '%s\n' '{"result":{"pane":{"agent":"canopy-t1-claude"},"agent":"other"}}' && exit 0
    [ -n "${HERDR_EXPECTED_TASK:-}" ] && printf '%s\n' '{"result":{"pane":{"agent":"canopy-'"${HERDR_EXPECTED_TASK}"'-claude"}}}' && exit 0
    [ "${HERDR_MISMATCH:-0}" = 1 ] && printf '%s\n' '{"result":{"pane":{"agent":"canopy-other-task-claude"}}}' || case "${3:-}" in
      pane-claude) printf '%s\n' '{"result":{"pane":{"agent":"canopy-t1-claude"}}}' ;;
      pane-codex) printf '%s\n' '{"result":{"pane":{"agent":"canopy-t2-codex"}}}' ;;
      legacy-pane) printf '%s\n' '{"result":{"pane":{"agent":"canopy-t7-claude"}}}' ;;
      pane-partial) printf '%s\n' '{"result":{"pane":{"agent":"canopy-t11-codex"}}}' ;;
      pane-attach) printf '%s\n' '{"result":{"pane":{"agent":"canopy-t8-codex"}}}' ;;
      *) printf '%s\n' '{"result":{"pane":{"agent":"canopy-t4-claude"}}}' ;;
    esac ;;
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
  agent\ attach|agent\ send) exit 0 ;;
  pane\ close) [ "${HERDR_CLOSE_PANE_FAIL:-0}" = 1 ] && exit 7 || exit 0 ;;
  tab\ close) [ "${HERDR_CLOSE_TAB_FAIL:-0}" = 1 ] && exit 8 || exit 0 ;;
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
eval "$ENV \"$CANOPY\" task checkpoint $ID2 'live pane checkpoint' >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" worker resume --workspace ws-existing $ID2 >/dev/null 2>&1" \
  && ok 'live Herdr pane resume succeeds' || bad 'live Herdr pane resume failed'
grep -q 'agent send pane-codex Continue from checkpoint: live pane checkpoint' "$WORK/herdr.log" \
  && ok 'live Herdr resume sends checkpoint continuation' || bad 'live Herdr resume lost checkpoint continuation'
if eval "$ENV \"$CANOPY\" worker close $ID2 >/dev/null 2>&1"; then bad 'close must require ready_for_review'; else ok 'close blocks before ready_for_review'; fi
eval "$ENV \"$CANOPY\" task checkpoint $ID2 ready_for_review >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" worker close $ID2 >/dev/null 2>&1" && ok 'close validates and closes' || bad 'close failed after ready_for_review'
[ "$(jq -r .status "$TF2")" = done ] && ok 'close marks task done' || bad 'task not done'

eval "$ENV \"$CANOPY\" task checkpoint $ID 'continue in Codex' >/dev/null 2>&1"
eval "$ENV HERDR_TAB_N=3 \"$CANOPY\" worker resume --agent codex --workspace ws-existing $ID >/dev/null 2>&1" && ok 'Claude task resumes through Codex' || bad 'Claude-to-Codex resume failed'
[ "$(jq -r .herdr_pane_id "$TF")" = pane-codex ] && ok 'backend switch replaces persisted pane' || bad 'backend switch reused old pane'
[ "$(grep -c 'agent start codex' "$WORK/herdr.log")" = 3 ] && ok 'backend switch starts requested backend' || bad 'backend switch did not start Codex'
grep -q 'continue in Codex' "$WORK/codex.stdin" && ok 'Claude-to-Codex resume carries checkpoint' || bad 'Claude-to-Codex resume lost checkpoint'
grep -q 'pane send-keys pane-claude CTRL-C' "$WORK/herdr.log" && ok 'backend switch stops old pane' || bad 'backend switch left old pane running'
grep -q 'pane close pane-claude' "$WORK/herdr.log" && ok 'backend switch closes old pane' || bad 'backend switch left old pane open'
grep -q 'tab close tab-1' "$WORK/herdr.log" && ok 'backend switch closes old tab' || bad 'backend switch left old tab open'

ID4="$(eval "$ENV \"$CANOPY\" task add 'identity check' 2>/dev/null")"
eval "$ENV \"$CANOPY\" task set $ID4 worktree $R >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID4 agent claude >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID4 herdr_workspace_id ws-existing >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID4 herdr_tab_id tab-stale >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID4 herdr_pane_id pane-stale >/dev/null 2>&1"
eval "$ENV HERDR_MISMATCH=1 \"$CANOPY\" worker start --agent claude --workspace ws-existing $ID4 >/dev/null 2>&1" \
  && ok 'mismatched persisted Herdr identity relaunches' || bad 'mismatched Herdr identity was reused'

ID12="$(eval "$ENV \"$CANOPY\" task add 'unsafe backend switch' 2>/dev/null")"
eval "$ENV \"$CANOPY\" task set $ID12 worktree $R >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID12 agent claude >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID12 herdr_tab_id tab-old >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID12 herdr_pane_id pane-old >/dev/null 2>&1"
SWITCH_ERR="$(eval "$ENV HERDR_MISMATCH=1 \"$CANOPY\" worker resume --agent codex --workspace ws-existing $ID12 2>&1 >/dev/null" || true)"
echo "$SWITCH_ERR" | grep -qi 'reconciled safely' && ok 'unsafe backend switch requires reconciliation' || bad 'unsafe backend switch launched'

ID5="$(eval "$ENV \"$CANOPY\" task add 'strict identity' 2>/dev/null")"
eval "$ENV \"$CANOPY\" task set $ID5 worktree $R >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID5 agent claude >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID5 herdr_workspace_id ws-existing >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID5 herdr_tab_id tab-empty >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID5 herdr_pane_id pane-empty >/dev/null 2>&1"
eval "$ENV HERDR_EMPTY_GET=1 \"$CANOPY\" worker start --agent claude --workspace ws-existing $ID5 >/dev/null 2>&1" \
  && ok 'empty Herdr identity relaunches' || bad 'empty Herdr identity was reused'

for mode in HERDR_MALFORMED_GET HERDR_AMBIGUOUS_GET; do
  if ( HERDR_LOG="$WORK/herdr.log" env "$mode=1" PATH="$WORK/bin:$PATH" CANOPY_HERDR_BIN="$WORK/bin/herdr" CANOPY_ROOT="$ROOT" \
       bash -c '. "$1/lib/common.sh"; . "$1/lib/state.sh"; . "$1/lib/agent.sh"; . "$1/lib/herdr.sh"; _herdr_id_matches tab probe "t1 · Claude"' _ "$ROOT" ); then
    bad "$mode Herdr identity was accepted"
  else
    ok "$mode Herdr identity is rejected"
  fi
done

ID8="$(eval "$ENV \"$CANOPY\" task add 'reuse backend identity' 2>/dev/null")"
eval "$ENV \"$CANOPY\" task set $ID8 worktree $R >/dev/null 2>&1"
eval "$ENV HERDR_FOUND_PANE=1 \"$CANOPY\" worker start --agent codex --workspace ws-existing $ID8 >/dev/null 2>&1" \
  && ok 'matching discovered pane reuses' || bad 'matching discovered pane did not reuse'
[ "$(jq -r .agent "$R/.canopy/tasks/$ID8.json")" = codex ] && ok 'reused pane persists requested backend' || bad 'reused pane lost requested backend'

ID9="$(eval "$ENV \"$CANOPY\" task add 'legacy herdr state' 2>/dev/null")"
eval "$ENV \"$CANOPY\" task set $ID9 worktree $R >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID9 herdr_tab_id legacy-tab >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID9 herdr_pane_id legacy-pane >/dev/null 2>&1"
LEGACY_ERR="$(eval "$ENV \"$CANOPY\" worker start --agent codex --workspace ws-existing $ID9 2>&1 >/dev/null" || true)"
echo "$LEGACY_ERR" | grep -qi 'legacy Herdr state' && ok 'legacy Herdr state requires reconciliation' || bad 'legacy Herdr state was reused'
eval "$ENV \"$CANOPY\" worker reconcile --agent claude $ID9 >/dev/null 2>&1" \
  && ok 'legacy Herdr state reconciles explicitly' || bad 'legacy Herdr reconciliation failed'
[ "$(jq -r '.herdr_tab_id + .herdr_pane_id + (.agent // "")' "$R/.canopy/tasks/$ID9.json")" = "" ] \
  && ok 'reconciliation clears legacy identities' || bad 'reconciliation left legacy identities'

ID13="$(eval "$ENV \"$CANOPY\" task add 'attach send ownership' 2>/dev/null")"
eval "$ENV \"$CANOPY\" task set $ID13 worktree $R >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID13 agent codex >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID13 herdr_tab_id tab-attach >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID13 herdr_pane_id pane-attach >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" worker attach $ID13 >/dev/null 2>&1" \
  && ok 'attach validates and calls owned Herdr pane' || bad 'attach rejected owned Herdr pane'
eval "$ENV \"$CANOPY\" worker send $ID13 'hello worker' >/dev/null 2>&1" \
  && ok 'send validates and calls owned Herdr pane' || bad 'send rejected owned Herdr pane'
ATTACH_CALLS="$(grep -c 'agent attach pane-attach' "$WORK/herdr.log")"; SEND_CALLS="$(grep -c 'agent send pane-attach hello worker' "$WORK/herdr.log")"
eval "$ENV HERDR_MISMATCH=1 \"$CANOPY\" worker attach $ID13 >/dev/null 2>&1" && bad 'attach used mismatched Herdr pane' || ok 'attach rejects mismatched Herdr pane'
eval "$ENV HERDR_MISMATCH=1 \"$CANOPY\" worker send $ID13 'blocked' >/dev/null 2>&1" && bad 'send used mismatched Herdr pane' || ok 'send rejects mismatched Herdr pane'
[ "$(grep -c 'agent attach pane-attach' "$WORK/herdr.log")" = "$ATTACH_CALLS" ] && ok 'attach makes no backend call after mismatch' || bad 'attach called backend after mismatch'
[ "$(grep -c 'agent send pane-attach blocked' "$WORK/herdr.log")" = 0 ] && ok 'send makes no backend call after mismatch' || bad 'send called backend after mismatch'

ID10="$(eval "$ENV \"$CANOPY\" task add 'strict stop close' 2>/dev/null")"
eval "$ENV \"$CANOPY\" task set $ID10 worktree $R >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID10 agent codex >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID10 herdr_pane_id pane-stop >/dev/null 2>&1"
STOP_ERR="$(eval "$ENV HERDR_MISMATCH=1 \"$CANOPY\" worker stop $ID10 2>&1 >/dev/null" || true)"
echo "$STOP_ERR" | grep -qi 'refusing to stop' && ok 'stop rejects mismatched pane identity' || bad 'stop used mismatched pane'
if grep -q 'pane send-keys pane-stop' "$WORK/herdr.log"; then bad 'stop sent keys to mismatched pane'; else ok 'stop did not mutate mismatched pane'; fi
for mode in HERDR_EMPTY_GET HERDR_MALFORMED_GET HERDR_AMBIGUOUS_GET; do
  STOP_ERR="$(eval "$ENV $mode=1 \"$CANOPY\" worker stop $ID10 2>&1 >/dev/null" || true)"
  echo "$STOP_ERR" | grep -qi 'refusing to stop' && ok "stop rejects $mode identity" || bad "stop accepted $mode identity"
done

ID11="$(eval "$ENV \"$CANOPY\" task add 'strict close' 2>/dev/null")"
eval "$ENV \"$CANOPY\" task set $ID11 worktree $R >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID11 agent codex >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID11 herdr_pane_id pane-close >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID11 herdr_tab_id tab-close >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task checkpoint $ID11 ready_for_review >/dev/null 2>&1"
CLOSE_ERR="$(eval "$ENV HERDR_MISMATCH=1 \"$CANOPY\" worker close $ID11 2>&1 >/dev/null" || true)"
echo "$CLOSE_ERR" | grep -qi 'refusing to close' && ok 'close rejects mismatched Herdr identity' || bad 'close used mismatched Herdr identity'
if grep -qE 'pane close pane-close|tab close tab-close' "$WORK/herdr.log"; then bad 'close mutated mismatched Herdr object'; else ok 'close did not mutate mismatched Herdr object'; fi
for mode in HERDR_EMPTY_GET HERDR_MALFORMED_GET HERDR_AMBIGUOUS_GET; do
  CLOSE_ERR="$(eval "$ENV $mode=1 \"$CANOPY\" worker close $ID11 2>&1 >/dev/null" || true)"
  echo "$CLOSE_ERR" | grep -qi 'refusing to close' && ok "close rejects $mode identity" || bad "close accepted $mode identity"
done

ID14="$(eval "$ENV \"$CANOPY\" task add 'retryable close' 2>/dev/null")"
eval "$ENV \"$CANOPY\" task set $ID14 worktree $R >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID14 agent codex >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID14 herdr_pane_id pane-partial >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID14 herdr_tab_id tab-partial >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task checkpoint $ID14 ready_for_review >/dev/null 2>&1"
PARTIAL_ERR="$(eval "$ENV HERDR_CLOSE_TAB_FAIL=1 \"$CANOPY\" worker close $ID14 2>&1 >/dev/null" || true)"
echo "$PARTIAL_ERR" | grep -qi 'close incomplete' && ok 'close reports partial Herdr failure' || bad 'close hid partial Herdr failure'
[ "$(jq -r '.status' "$R/.canopy/tasks/$ID14.json")" != done ] && ok 'partial close leaves task retryable' || bad 'partial close marked task done'
[ "$(jq -r '.herdr_pane_id' "$R/.canopy/tasks/$ID14.json")" = "" ] && [ "$(jq -r '.herdr_tab_id' "$R/.canopy/tasks/$ID14.json")" = tab-partial ] \
  && ok 'partial close clears only closed pane' || bad 'partial close state is not retryable'
eval "$ENV \"$CANOPY\" worker close $ID14 >/dev/null 2>&1" \
  && ok 'partial close retries successfully' || bad 'partial close retry failed'
[ "$(jq -r '.status' "$R/.canopy/tasks/$ID14.json")" = done ] && ok 'retry closes remaining Herdr tab' || bad 'retry did not finish close'

ID15="$(eval "$ENV \"$CANOPY\" task add 'failed backend cleanup' 2>/dev/null")"
eval "$ENV \"$CANOPY\" task set $ID15 worktree $R >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID15 agent claude >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID15 herdr_tab_id tab-old-cleanup >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID15 herdr_pane_id pane-old-cleanup >/dev/null 2>&1"
SWITCH_STARTS="$(grep -c 'agent start codex' "$WORK/herdr.log")"
SWITCH_ERR="$(eval "$ENV HERDR_EXPECTED_TASK=$ID15 HERDR_CLOSE_TAB_FAIL=1 \"$CANOPY\" worker resume --agent codex --workspace ws-existing $ID15 2>&1 >/dev/null" || true)"
echo "$SWITCH_ERR" | grep -qi 'cleanup incomplete' && ok 'backend switch reports failed cleanup' || bad 'backend switch hid failed cleanup'
[ "$(jq -r '.herdr_tab_id + .herdr_pane_id' "$R/.canopy/tasks/$ID15.json")" = tab-old-cleanuppane-old-cleanup ] \
  && ok 'backend switch preserves IDs after cleanup failure' || bad 'backend switch cleared IDs after cleanup failure'
[ "$(grep -c 'agent start codex' "$WORK/herdr.log")" = "$SWITCH_STARTS" ] \
  && ok 'backend switch does not launch after cleanup failure' || bad 'backend switch launched after cleanup failure'

ID16="$(eval "$ENV \"$CANOPY\" task add 'failed legacy cleanup' 2>/dev/null")"
eval "$ENV \"$CANOPY\" task set $ID16 worktree $R >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID16 herdr_tab_id legacy-tab >/dev/null 2>&1"
eval "$ENV \"$CANOPY\" task set $ID16 herdr_pane_id legacy-pane >/dev/null 2>&1"
RECON_ERR="$(eval "$ENV HERDR_EXPECTED_TASK=$ID16 HERDR_CLOSE_PANE_FAIL=1 \"$CANOPY\" worker reconcile --agent claude $ID16 2>&1 >/dev/null" || true)"
echo "$RECON_ERR" | grep -qi 'cleanup incomplete' && ok 'legacy reconciliation reports failed cleanup' || bad 'legacy reconciliation hid failed cleanup'
[ "$(jq -r '.herdr_tab_id + .herdr_pane_id' "$R/.canopy/tasks/$ID16.json")" = legacy-tablegacy-pane ] \
  && ok 'legacy reconciliation preserves IDs after cleanup failure' || bad 'legacy reconciliation cleared IDs after cleanup failure'

R2="$WORK/no-context"; mkdir -p "$R2"; (cd "$R2" && git init -q && git config user.email t@t && git config user.name t && echo x > f && git add f && git commit -qm init && eval "$ENV \"$CANOPY\" init >/dev/null 2>&1")
ID3="$(cd "$R2" && eval "$ENV \"$CANOPY\" task add no-context 2>/dev/null")"
(cd "$R2" && eval "$ENV \"$CANOPY\" task set $ID3 worktree $R2 >/dev/null 2>&1")
if (cd "$R2" && eval "HERDR_NO_CONTEXT=1 $ENV \"$CANOPY\" worker start --agent claude $ID3 >/dev/null 2>&1"); then bad 'missing workspace context should fail'; else ok 'missing workspace context fails clearly'; fi
if (cd "$R2" && eval "$ENV \"$CANOPY\" worker start --agent claude --workspace ws-missing $ID3 >/dev/null 2>&1"); then bad 'invalid explicit workspace should fail'; else ok 'invalid explicit workspace fails clearly'; fi

printf '\n== %s passed, %s failed ==\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]
