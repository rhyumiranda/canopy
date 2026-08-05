#!/usr/bin/env bash
# canopy watch hardening: status/ensure/install-plist logic + Layer-1 recover
# reconcile. Avoids touching the real launchd (never calls ensure with a plist
# present). Sandboxed via $HOME. Run: bash test/watch_test.sh
set -uo pipefail
CANOPY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANOPY="$CANOPY_ROOT/bin/canopy"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
command -v jq  >/dev/null || { echo "jq required";  exit 1; }
command -v git >/dev/null || { echo "git required"; exit 1; }
new_repo() { local d="$WORK/repo-$RANDOM"; mkdir -p "$d"; ( cd "$d"; git init -q; git config user.email t@t; git config user.name t; echo x>f; git add -A; git commit -qm i ); echo "$d"; }

echo "== canopy watch hardening =="
H="$WORK/home"; mkdir -p "$H/Library/LaunchAgents"
R="$(new_repo)"; cd "$R"; "$CANOPY" init >/dev/null 2>&1

# --- status: not installed yet ---
OUT="$(HOME="$H" "$CANOPY" watch status 2>&1)"
printf '%s' "$OUT" | grep -qi 'plist: NOT installed' && ok "status reports not-installed" || bad "status should say not installed: $OUT"

# --- ensure with no plist: safe, never touches launchd ---
HOME="$H" "$CANOPY" watch ensure >/dev/null 2>&1 && ok "ensure exits 0 with no plist" || bad "ensure should not fail"
ls "$H/Library/LaunchAgents/"*.plist >/dev/null 2>&1 && bad "ensure must not create a plist" || ok "ensure created no plist (no side effects)"

# --- install writes the plist (no --load, so no launchctl) ---
HOME="$H" "$CANOPY" watch install >/dev/null 2>&1
ls "$H/Library/LaunchAgents/"com.canopy.watch.*.plist >/dev/null 2>&1 && ok "install wrote the plist" || bad "install did not write a plist"
# plist carries the notify env + points at the stable snapshot path pattern
PL="$(ls "$H/Library/LaunchAgents/"com.canopy.watch.*.plist 2>/dev/null | head -1)"
grep -q 'CANOPY_NOTIFY' "$PL" && ok "plist sets CANOPY_NOTIFY (merges ping)" || bad "plist missing CANOPY_NOTIFY"

# --- status: now installed ---
OUT="$(HOME="$H" "$CANOPY" watch status 2>&1)"
printf '%s' "$OUT" | grep -qi 'plist: installed' && ok "status reports installed" || bad "status should say installed: $OUT"

# --- status detects a TCC block from the log ---
printf 'fatal: Unable to read current working directory: Operation not permitted\n' > "$R/.canopy/watch.log"
OUT="$(HOME="$H" "$CANOPY" watch status 2>&1)"
printf '%s' "$OUT" | grep -qi 'TCC' && ok "status flags the TCC/Full-Disk-Access block" || bad "status should flag TCC: $OUT"

# --- Layer 1: 'canopy recover' reconciles a merged PR in-session (stub gh-axi) ---
STUB="$WORK/bin"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\necho "state:  MERGED"\n' > "$STUB/gh-axi"; chmod +x "$STUB/gh-axi"
cat > "$STUB/launchctl" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${LAUNCHCTL_LOG:-/dev/null}"
case "${1:-}" in
  list) exit 1 ;;
  bootstrap|load|bootout|remove) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$STUB/launchctl"
R2="$(new_repo)"; cd "$R2"; "$CANOPY" init >/dev/null 2>&1
ID="$("$CANOPY" task add "shipped thing" 2>/dev/null)"
"$CANOPY" task set "$ID" pr 1 >/dev/null
"$CANOPY" task set "$ID" worktree "$R2" >/dev/null
"$CANOPY" task status "$ID" pr-open >/dev/null
# watch once reconciles (worktree return may fail with no treehouse — must not block the flip)
PATH="$STUB:$PATH" "$CANOPY" watch once >/dev/null 2>&1 || true
[ "$(jq -r '.tasks[0].status' "$R2/.canopy/state.json")" = "done" ] && ok "watch once flips merged -> done (return failure can't block it)" || bad "watch once did not flip"
# recover reconciles the same way (Layer 1 redundancy)
"$CANOPY" task status "$ID" pr-open >/dev/null
PATH="$STUB:$PATH" HOME="$H" "$CANOPY" recover >/dev/null 2>&1 || true
[ "$(jq -r '.tasks[0].status' "$R2/.canopy/state.json")" = "done" ] && ok "recover reconciles merged PR -> done (Layer 1)" || bad "recover did not flip"

# --- Herdr lifecycle: terminal worker state -> durable one-shot event ---
cat > "$STUB/herdr" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${HERDR_LOG:?}"
case "$1 ${2:-}" in
  pane\ current) printf '%s\n' '{"result":{"pane":{"pane_id":"supervisor-pane","workspace_id":"ws-existing"}}}' ;;
  pane\ get) [ "${HERDR_PANE_GONE:-0}" = 1 ] && exit 1; [ "${3:-}" = "pane-done" ] ;;
  agent\ explain) printf '%s\n' '{"result":{"agent":{"state":"'"${HERDR_STATE:-done}"'"}}}' ;;
  wait\ agent-status) exit 1 ;;
  notification\ show) exit 0 ;;
  agent\ send) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$STUB/herdr"
R3="$(new_repo)"; cd "$R3"; PATH="$STUB:$PATH" "$CANOPY" init >/dev/null 2>&1
ID3="$(PATH="$STUB:$PATH" "$CANOPY" task add "herdr done" 2>/dev/null)"
PATH="$STUB:$PATH" "$CANOPY" task set "$ID3" worktree "$R3" >/dev/null
PATH="$STUB:$PATH" "$CANOPY" task set "$ID3" herdr_pane_id pane-done >/dev/null
PATH="$STUB:$PATH" "$CANOPY" task set "$ID3" herdr_tab_id tab-done >/dev/null
PATH="$STUB:$PATH" "$CANOPY" task set "$ID3" herdr_agent_session_id session-done >/dev/null
PATH="$STUB:$PATH" "$CANOPY" task checkpoint "$ID3" "ready_for_review" >/dev/null
PATH="$STUB:$PATH" "$CANOPY" task status "$ID3" implementing >/dev/null
HERDR_LOG="$WORK/herdr.log" CANOPY_NOTIFY=1 CANOPY_SUPERVISOR_PANE=supervisor-pane PATH="$STUB:$PATH" "$CANOPY" watch once >/dev/null 2>&1
[ "$(jq -r '.tasks[0].status' "$R3/.canopy/state.json")" = "done" ] && ok "Herdr watch marks task done" || bad "Herdr watch did not mark done"
[ "$(jq -r '.events|length' "$R3/.canopy/events/lifecycle.json")" = "1" ] && ok "Herdr watch writes one durable event" || bad "Herdr event missing"
jq -e '.events[0] | select(.task_id=="'"$ID3"'" and .status=="done" and .pane_id=="pane-done" and .tab_id=="tab-done" and .session_id=="session-done" and .checkpoint=="ready_for_review")' "$R3/.canopy/events/lifecycle.json" >/dev/null \
  && ok "event records ids checkpoint timestamp" || bad "event payload wrong"
[ "$(grep -c 'agent send supervisor-pane' "$WORK/herdr.log")" = "1" ] && ok "live supervisor pane gets one send" || bad "supervisor send count wrong"
[ "$(grep -c 'notification show Canopy' "$WORK/herdr.log")" = "1" ] && ok "native notification sent once" || bad "notification count wrong"
HERDR_LOG="$WORK/herdr.log" CANOPY_NOTIFY=1 CANOPY_SUPERVISOR_PANE=supervisor-pane PATH="$STUB:$PATH" "$CANOPY" watch once >/dev/null 2>&1
[ "$(jq -r '.events|length' "$R3/.canopy/events/lifecycle.json")" = "1" ] && ok "rerun deduplicates same transition" || bad "duplicate event written"
[ "$(grep -c 'agent send supervisor-pane' "$WORK/herdr.log")" = "1" ] && ok "rerun does not notify again" || bad "duplicate supervisor notify"
EV="$(PATH="$STUB:$PATH" "$CANOPY" events consume 2>/dev/null)"
printf '%s' "$EV" | grep -q '"task_id":"'"$ID3"'"' && ok "events consume wakes once with event" || bad "consume did not return event"
PATH="$STUB:$PATH" "$CANOPY" events consume >/dev/null 2>&1 && bad "consumed event should not wake twice" || ok "consumed event does not wake twice"
START="$(date +%s)"
PATH="$STUB:$PATH" "$CANOPY" events wait 0 >/dev/null 2>&1 && bad "wait 0 should fail when no event" || ok "wait 0 has no endless supervisor polling"
END="$(date +%s)"
[ $((END-START)) -le 1 ] && ok "wait 0 returns quickly" || bad "wait 0 blocked too long"

for st in failed blocked; do
  R4="$(new_repo)"; cd "$R4"; PATH="$STUB:$PATH" "$CANOPY" init >/dev/null 2>&1
  ID4="$(PATH="$STUB:$PATH" "$CANOPY" task add "herdr $st" 2>/dev/null)"
  PATH="$STUB:$PATH" "$CANOPY" task set "$ID4" worktree "$R4" >/dev/null
  PATH="$STUB:$PATH" "$CANOPY" task set "$ID4" agent codex >/dev/null
  PATH="$STUB:$PATH" "$CANOPY" task set "$ID4" herdr_workspace_id ws-existing >/dev/null
  PATH="$STUB:$PATH" "$CANOPY" task set "$ID4" herdr_pane_id pane-done >/dev/null
  PATH="$STUB:$PATH" "$CANOPY" task set "$ID4" herdr_tab_id tab-done >/dev/null
  PATH="$STUB:$PATH" "$CANOPY" task set "$ID4" herdr_agent_session_id "session-$st" >/dev/null
  PATH="$STUB:$PATH" "$CANOPY" task status "$ID4" implementing >/dev/null
  HERDR_LOG="$WORK/herdr.log" LAUNCHCTL_LOG="$WORK/launchctl.log" HERDR_STATE="$st" CANOPY_NOTIFY=1 PATH="$STUB:$PATH" "$CANOPY" herdr supervise "$ID4" pane-done tab-done "session-$st" codex >/dev/null 2>&1
  [ "$(jq -r '.tasks[0].status' "$R4/.canopy/state.json")" = "$st" ] && ok "Herdr supervisor marks task $st" || bad "Herdr supervisor did not mark $st"
  [ "$(jq -r '.events[0].status' "$R4/.canopy/events/lifecycle.json")" = "$st" ] && ok "Herdr supervisor writes $st event" || bad "Herdr supervisor missing $st event"
done

R5="$(new_repo)"; cd "$R5"; PATH="$STUB:$PATH" "$CANOPY" init >/dev/null 2>&1
ID5="$(PATH="$STUB:$PATH" "$CANOPY" task add "herdr interrupted" 2>/dev/null)"
PATH="$STUB:$PATH" "$CANOPY" task set "$ID5" worktree "$R5" >/dev/null
PATH="$STUB:$PATH" "$CANOPY" task set "$ID5" agent claude >/dev/null
PATH="$STUB:$PATH" "$CANOPY" task set "$ID5" herdr_pane_id pane-done >/dev/null
PATH="$STUB:$PATH" "$CANOPY" task set "$ID5" herdr_tab_id tab-done >/dev/null
PATH="$STUB:$PATH" "$CANOPY" task set "$ID5" herdr_agent_session_id session-interrupted >/dev/null
PATH="$STUB:$PATH" "$CANOPY" task status "$ID5" implementing >/dev/null
HERDR_LOG="$WORK/herdr.log" LAUNCHCTL_LOG="$WORK/launchctl.log" HERDR_PANE_GONE=1 CANOPY_NOTIFY=1 PATH="$STUB:$PATH" "$CANOPY" herdr supervise "$ID5" pane-done tab-done session-interrupted claude >/dev/null 2>&1
[ "$(jq -r '.tasks[0].status' "$R5/.canopy/state.json")" = interrupted ] && ok "Herdr supervisor marks interrupted when pane disappears" || bad "Herdr supervisor did not mark interrupted"

R6="$(new_repo)"; cd "$R6"; PATH="$STUB:$PATH" "$CANOPY" init >/dev/null 2>&1
ID6="$(PATH="$STUB:$PATH" "$CANOPY" task add "stale watcher" 2>/dev/null)"
PATH="$STUB:$PATH" "$CANOPY" task set "$ID6" worktree "$R6" >/dev/null
PATH="$STUB:$PATH" "$CANOPY" task set "$ID6" agent codex >/dev/null
PATH="$STUB:$PATH" "$CANOPY" task set "$ID6" herdr_pane_id pane-new >/dev/null
PATH="$STUB:$PATH" "$CANOPY" task set "$ID6" herdr_tab_id tab-new >/dev/null
PATH="$STUB:$PATH" "$CANOPY" task set "$ID6" herdr_agent_session_id session-new >/dev/null
PATH="$STUB:$PATH" "$CANOPY" task status "$ID6" implementing >/dev/null
HERDR_LOG="$WORK/herdr.log" HERDR_PANE_GONE=1 PATH="$STUB:$PATH" "$CANOPY" herdr supervise "$ID6" pane-old tab-old session-old codex >/dev/null 2>&1
[ "$(jq -r '.tasks[0].status' "$R6/.canopy/state.json")" = implementing ] && ok "stale Herdr supervisor does not mark interrupted" || bad "stale Herdr supervisor changed task"
[ ! -f "$R6/.canopy/events/lifecycle.json" ] && ok "stale Herdr supervisor emits no event" || bad "stale Herdr supervisor emitted event"

PATH="$STUB:$PATH" "$CANOPY" task status "$ID3" blocked >/dev/null
OUT="$(HERDR_LOG="$WORK/herdr.log" PATH="$STUB:$PATH" HOME="$H" "$CANOPY" recover 2>/dev/null)"
printf '%s' "$OUT" | grep -q "CANOPY EVENT task $ID3 \\[blocked\\]" && ok "recover consumes durable terminal event" || bad "recover missing event"
[ "$(jq -r '[.events[]|select(.consumed_at==null)]|length' "$R3/.canopy/events/lifecycle.json")" = "0" ] && ok "recover drains event once" || bad "recover left unconsumed event"

# --- dedupe: a genuine LATER transition on the same pane/session wakes again, but a
# repeated probe of the same continuous terminal state does not (bug 3) ---
R7="$(new_repo)"; cd "$R7"; PATH="$STUB:$PATH" "$CANOPY" init >/dev/null 2>&1
ID7="$(PATH="$STUB:$PATH" "$CANOPY" task add "re-block dedupe" 2>/dev/null)"
PATH="$STUB:$PATH" "$CANOPY" task set "$ID7" worktree "$R7" >/dev/null
PATH="$STUB:$PATH" "$CANOPY" task set "$ID7" agent codex >/dev/null
PATH="$STUB:$PATH" "$CANOPY" task set "$ID7" herdr_pane_id pane-done >/dev/null
PATH="$STUB:$PATH" "$CANOPY" task set "$ID7" herdr_tab_id tab-done >/dev/null
PATH="$STUB:$PATH" "$CANOPY" task set "$ID7" herdr_agent_session_id session-reblock >/dev/null
LC="$R7/.canopy/events/lifecycle.json"
evn() { jq -r '[.events[]|select(.status=="blocked")]|length' "$LC" 2>/dev/null || echo 0; }
PATH="$STUB:$PATH" "$CANOPY" task status "$ID7" implementing >/dev/null
HERDR_LOG="$WORK/herdr.log" HERDR_STATE=blocked PATH="$STUB:$PATH" "$CANOPY" watch once >/dev/null 2>&1
[ "$(evn)" = 1 ] && ok "first block emits one event" || bad "first block event count wrong ($(evn))"
# still blocked and merely reactivated: same continuous state -> no new event
PATH="$STUB:$PATH" "$CANOPY" task status "$ID7" implementing >/dev/null
HERDR_LOG="$WORK/herdr.log" HERDR_STATE=blocked PATH="$STUB:$PATH" "$CANOPY" watch once >/dev/null 2>&1
[ "$(evn)" = 1 ] && ok "continuous block is a true duplicate (suppressed)" || bad "continuous block re-emitted ($(evn))"
# worker leaves the terminal state (healthy again) -> starts a new lifecycle phase
HERDR_LOG="$WORK/herdr.log" HERDR_STATE=working PATH="$STUB:$PATH" "$CANOPY" watch once >/dev/null 2>&1
[ "$(evn)" = 1 ] && ok "leaving terminal emits no event" || bad "leaving terminal emitted an event ($(evn))"
# genuine RE-transition into blocked on the same pane/session -> wakes again
HERDR_LOG="$WORK/herdr.log" HERDR_STATE=blocked PATH="$STUB:$PATH" "$CANOPY" watch once >/dev/null 2>&1
[ "$(evn)" = 2 ] && ok "genuine re-block on same pane/session wakes again" || bad "genuine re-block was wrongly deduplicated ($(evn))"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
