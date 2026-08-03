#!/usr/bin/env bash
# Herdr interactive worker flow with a deterministic fake Herdr binary.
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
printf '%s\n' "$*" >> "${HERDR_LOG:?}"
case "$1 ${2:-}" in
  workspace\ create) printf '%s\n' '{"id":"ws-1"}' ;;
  tab\ create) printf '%s\n' '{"id":"tab-1"}' ;;
  agent\ start) case "$*" in *codex*) printf '%s\n' '{"pane_id":"pane-codex","agent_session_id":"herdr-codex"}' ;; *) printf '%s\n' '{"pane_id":"pane-claude","agent_session_id":"herdr-claude"}' ;; esac ;;
  agent\ explain) printf '%s\n' '{"state":"working","agent":"claude"}' ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$WORK/bin/herdr"
R="$WORK/repo"; mkdir -p "$R"; (cd "$R" && git init -q && git config user.email t@t && git config user.name t && echo hi > f && git add f && git commit -qm init)
cd "$R"
HOME="$WORK/home" HERDR_LOG="$WORK/herdr.log" PATH="$WORK/bin:$PATH" "$CANOPY" init >/dev/null 2>&1
ID="$(HOME="$WORK/home" HERDR_LOG="$WORK/herdr.log" PATH="$WORK/bin:$PATH" "$CANOPY" task add 'interactive worker' 2>/dev/null)"
HOME="$WORK/home" HERDR_LOG="$WORK/herdr.log" PATH="$WORK/bin:$PATH" "$CANOPY" task set "$ID" brief 'do the work' >/dev/null 2>&1
HOME="$WORK/home" HERDR_LOG="$WORK/herdr.log" PATH="$WORK/bin:$PATH" "$CANOPY" task set "$ID" worktree "$R" >/dev/null 2>&1
HOME="$WORK/home" HERDR_LOG="$WORK/herdr.log" PATH="$WORK/bin:$PATH" "$CANOPY" worker start --agent claude "$ID" >/dev/null 2>&1 && ok 'start creates Herdr worker' || bad 'start failed'
TF="$R/.canopy/tasks/$ID.json"
[ "$(jq -r .herdr_workspace_id "$TF")" = ws-1 ] && ok 'workspace id persisted' || bad 'workspace id missing'
[ "$(jq -r .herdr_tab_id "$TF")" = tab-1 ] && ok 'tab id persisted' || bad 'tab id missing'
[ "$(jq -r .herdr_pane_id "$TF")" = pane-claude ] && ok 'pane id persisted' || bad 'pane id missing'
[ "$(grep -c 'workspace create' "$WORK/herdr.log")" = 1 ] && ok 'one shared workspace created' || bad 'workspace duplicated'
[ "$(grep -c -- '--no-focus' "$WORK/herdr.log")" -ge 2 ] && ok 'worker tabs are non-focused' || bad 'worker tab focused'
ID2="$(HOME="$WORK/home" HERDR_LOG="$WORK/herdr.log" PATH="$WORK/bin:$PATH" "$CANOPY" task add 'codex worker' 2>/dev/null)"
HOME="$WORK/home" HERDR_LOG="$WORK/herdr.log" PATH="$WORK/bin:$PATH" "$CANOPY" task set "$ID2" worktree "$R" >/dev/null 2>&1
HOME="$WORK/home" HERDR_LOG="$WORK/herdr.log" PATH="$WORK/bin:$PATH" "$CANOPY" worker start --agent codex "$ID2" >/dev/null 2>&1 && ok 'Codex gets its own Herdr tab' || bad 'Codex start failed'
[ "$(grep -c 'tab create' "$WORK/herdr.log")" = 2 ] && ok 'Claude and Codex tabs stay separate' || bad 'worker tabs not separate'
HOME="$WORK/home" HERDR_LOG="$WORK/herdr.log" PATH="$WORK/bin:$PATH" "$CANOPY" worker start "$ID" >/dev/null 2>&1
[ "$(grep -c 'tab create' "$WORK/herdr.log")" = 2 ] && ok 'duplicate start reuses tab' || bad 'duplicate tab created'
HOME="$WORK/home" HERDR_LOG="$WORK/herdr.log" PATH="$WORK/bin:$PATH" "$CANOPY" worker send "$ID" 'continue' >/dev/null 2>&1 && ok 'send succeeds' || bad 'send failed'
HOME="$WORK/home" HERDR_LOG="$WORK/herdr.log" PATH="$WORK/bin:$PATH" "$CANOPY" worker attach "$ID" >/dev/null 2>&1 && ok 'attach succeeds' || bad 'attach failed'
HOME="$WORK/home" HERDR_LOG="$WORK/herdr.log" PATH="$WORK/bin:$PATH" "$CANOPY" worker status "$ID" >/dev/null 2>&1 && ok 'status succeeds' || bad 'status failed'
if HOME="$WORK/home" HERDR_LOG="$WORK/herdr.log" PATH="$WORK/bin:$PATH" "$CANOPY" worker close "$ID" >/dev/null 2>&1; then bad 'close must require ready_for_review'; else ok 'close blocks before ready_for_review'; fi
HOME="$WORK/home" HERDR_LOG="$WORK/herdr.log" PATH="$WORK/bin:$PATH" "$CANOPY" task checkpoint "$ID" ready_for_review >/dev/null 2>&1
HOME="$WORK/home" HERDR_LOG="$WORK/herdr.log" PATH="$WORK/bin:$PATH" "$CANOPY" worker close "$ID" >/dev/null 2>&1 && ok 'close validates and closes' || bad 'close failed after ready_for_review'
[ "$(jq -r .status "$TF")" = done ] && ok 'close marks task done' || bad 'task not done'
printf '\n== %s passed, %s failed ==\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]
