#!/usr/bin/env bash
# Detached Codex worker/review flow with a fake codex binary. Run: bash test/worker_test.sh
set -uo pipefail
CANOPY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANOPY="$CANOPY_ROOT/bin/canopy"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

echo "== detached codex worker =="

BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${CANOPY_ARGV_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$CANOPY_ARGV_LOG"
fi
# record the inherited CANOPY_ROLE so tests can prove the spawn runs under worker role
if [ -n "${CANOPY_ROLE_LOG:-}" ]; then
  printf '%s\n' "${CANOPY_ROLE:-<unset>}" >> "$CANOPY_ROLE_LOG"
fi
has_bypass=0
saw_approval=0
out=""
schema=""
json=0
resume=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dangerously-bypass-approvals-and-sandbox|--yolo) has_bypass=1; shift ;;
    exec) shift; break ;;
    -o|--output-last-message) out="$2"; shift 2 ;;
    --output-schema) schema="$2"; shift 2 ;;
    --json) json=1; shift ;;
    -a|--ask-for-approval) saw_approval=1; shift 2 ;;
    -s|-C|-m) shift 2 ;;
    *) shift ;;
  esac
done
[ "$saw_approval" = 1 ] && { echo approval flag >&2; exit 42; }
[ "$has_bypass" = 1 ] || { echo missing bypass >&2; exit 43; }
if [ "${1:-}" = "resume" ]; then resume=1; shift; fi
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|--output-last-message) out="$2"; shift 2 ;;
    --output-schema) schema="$2"; shift 2 ;;
    --json) json=1; shift ;;
    -) cat >/dev/null; shift ;;
    *) shift ;;
  esac
done
if [ -n "$schema" ]; then
  printf '%s\n' '{"verdict":"clean","risk_level":"low","risk_rationale":"bounded test change","issues":[],"docs_in_sync":true,"summary":"clean from fake codex"}' > "$out"
  exit 0
fi
sid="${CANOPY_FAKE_CODEX_SESSION:-codex-session-123}"
printf '%s\n' "{\"type\":\"thread.started\",\"thread_id\":\"$sid\"}"
printf '%s\n' "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"worker ${resume}\"}}"
if [ -n "${CANOPY_FAKE_CODEX_SLEEP:-}" ]; then sleep "$CANOPY_FAKE_CODEX_SLEEP"; fi
EOF
chmod +x "$BIN/codex"

R="$WORK/repo"; mkdir -p "$R"
( cd "$R"; git init -q; git config user.email t@t; git config user.name t; echo one > f.txt; git add -A; git commit -qm init; git branch -M main )
( cd "$R" && "$CANOPY" init >/dev/null 2>&1 )
ID="$(cd "$R" && "$CANOPY" task add "feat: fake codex worker" 2>/dev/null)"
( cd "$R" && "$CANOPY" task set "$ID" worktree "$R" >/dev/null 2>&1 )
( cd "$R" && "$CANOPY" task set "$ID" brief "touch file and review it" >/dev/null 2>&1 )

ARGV_LOG="$WORK/codex.argv"
ROLE_LOG="$WORK/codex.role"
SID="$(cd "$R" && PATH="$BIN:$PATH" CANOPY_ARGV_LOG="$ARGV_LOG" CANOPY_ROLE_LOG="$ROLE_LOG" CANOPY_FAKE_CODEX_SLEEP=30 CANOPY_ROLE=orchestrator "$CANOPY" worker spawn --agent codex "$ID" 2>/dev/null)"
[ "$SID" = "codex-session-123" ] && ok "codex worker spawn returns session id" || bad "unexpected codex session id: $SID"
# regression guard: the spawn must run codex under CANOPY_ROLE=worker even when the
# orchestrator's env leaks CANOPY_ROLE=orchestrator, so it can't mutate the shared .canopy
grep -qx worker "$ROLE_LOG" && ok "codex worker spawn runs under CANOPY_ROLE=worker" || bad "codex worker spawn did not set worker role"
[ "$(grep -o -- '--dangerously-bypass-approvals-and-sandbox' "$ARGV_LOG" | wc -l | tr -d ' ')" = 1 ] && ok "codex worker spawn has one bypass flag" || bad "codex worker spawn bypass count wrong"
case " $(cat "$ARGV_LOG") " in *" -a "*|*" --ask-for-approval "*) bad "codex worker spawn should not pass approval flag" ;; *) ok "codex worker spawn omits conflicting approval flag" ;; esac
[ "$(jq -r '.agent' "$R/.canopy/tasks/$ID.json")" = "codex" ] && ok "task records codex agent" || bad "task missing codex agent"
LOGF="$(jq -r '.worker_log' "$R/.canopy/tasks/$ID.json")"
[ -f "$LOGF" ] && ok "task records worker log" || bad "worker log missing"
PID="$(jq -r '.worker_pid' "$R/.canopy/tasks/$ID.json")"
kill -0 "$PID" >/dev/null 2>&1 && ok "task records live worker pid" || bad "worker pid not live"
OUT="$(cd "$R" && PATH="$BIN:$PATH" "$CANOPY" worker logs "$ID" 2>/dev/null)"
printf '%s' "$(cat "$LOGF")" | grep -q 'thread.started' && ok "worker log captures codex jsonl" || bad "worker log missing jsonl"
( cd "$R" && STOP_CALLS="$WORK/stop.calls" CANOPY_ROOT="$CANOPY_ROOT" SID="$SID" PID="$PID" bash -c '
    set -euo pipefail
    . "$CANOPY_ROOT/lib/common.sh"
    . "$CANOPY_ROOT/lib/state.sh"
    . "$CANOPY_ROOT/lib/agent.sh"
    . "$CANOPY_ROOT/lib/worker.sh"
    . "$CANOPY_ROOT/lib/herdr.sh"
    kill() { printf "%s\\n" "$*" >> "$STOP_CALLS"; return 0; }
    _canopy_worker_stop_headless "$SID"
  ' )
grep -q "$PID" "$WORK/stop.calls" && ok "worker stop by session id reaches worker" || { cat "$WORK/stop.calls" >&2; bad "worker stop by session id did not reach worker"; }
( cd "$R" && PATH="$BIN:$PATH" "$CANOPY" worker stop "$ID" >/dev/null 2>&1 )
ok "worker stop command succeeds"

# AXI ergonomics on the shared 'stop' command (headless path)
SH="$(cd "$R" && PATH="$BIN:$PATH" "$CANOPY" worker stop --help 2>/dev/null)"; SHRC=$?
{ [ "$SHRC" = 0 ] && printf '%s' "$SH" | grep -q 'usage: canopy worker stop'; } \
  && ok "worker stop --help prints usage on stdout" || bad "worker stop --help failed (rc=$SHRC)"
UF="$(cd "$R" && PATH="$BIN:$PATH" "$CANOPY" worker stop --bogus x 2>/dev/null)"; UFRC=$?
[ "$UFRC" = 2 ] && ok "worker stop rejects unknown flag (exit 2)" || bad "worker stop unknown flag exit $UFRC"
printf '%s' "$UF" | grep -q '^error: unknown flag --bogus' && ok "worker stop unknown flag structured error on stdout" || bad "worker stop unknown flag not structured"
SO="$(cd "$R" && PATH="$BIN:$PATH" "$CANOPY" worker stop "$ID" 2>/dev/null)"; SORC=$?
[ "$SORC" = 0 ] && ok "worker stop is idempotent (exit 0)" || bad "worker stop idempotent exit $SORC"
printf '%s' "$SO" | grep -q '^stopped: ok' && ok "worker stop emits structured confirmation on stdout" || bad "worker stop missing confirmation"
printf '%s' "$SO" | grep -q '\[canopy\]' && bad "worker stop leaked logs to stdout" || ok "worker stop keeps stdout clean"

: > "$ARGV_LOG"; : > "$ROLE_LOG"
FIX_SID="$(cd "$R" && PATH="$BIN:$PATH" CANOPY_ARGV_LOG="$ARGV_LOG" CANOPY_ROLE_LOG="$ROLE_LOG" CANOPY_ROLE=orchestrator "$CANOPY" worker fix --agent codex "$ID" "fix it" 2>/dev/null)"
[ "$FIX_SID" = "codex-session-123" ] && ok "codex worker fix resumes session" || bad "unexpected codex fix session id: $FIX_SID"
grep -q -- 'exec resume' "$ARGV_LOG" && ok "codex worker fix uses resume path" || bad "codex worker fix did not resume"
grep -qx worker "$ROLE_LOG" && ok "codex worker fix/resume runs under CANOPY_ROLE=worker" || bad "codex worker fix/resume did not set worker role"
[ "$(grep -o -- '--dangerously-bypass-approvals-and-sandbox' "$ARGV_LOG" | wc -l | tr -d ' ')" = 1 ] && ok "codex worker resume has one bypass flag" || bad "codex worker resume bypass count wrong"
case " $(cat "$ARGV_LOG") " in *" -a "*|*" --ask-for-approval "*) bad "codex worker resume should not pass approval flag" ;; *) ok "codex worker resume omits conflicting approval flag" ;; esac

( cd "$R"; git checkout -qb rhyu/t1 >/dev/null 2>&1; echo two >> f.txt; git commit -qam 'feat: worker diff' )
: > "$ARGV_LOG"
OUT2="$(cd "$R" && PATH="$BIN:$PATH" CANOPY_ARGV_LOG="$ARGV_LOG" CANOPY_ROOT="$CANOPY_ROOT" bash -c '. "$CANOPY_ROOT/lib/common.sh"; . "$CANOPY_ROOT/lib/state.sh"; . "$CANOPY_ROOT/lib/agent.sh"; . "$CANOPY_ROOT/lib/review.sh"; _review_once_codex "$PWD" "" ""')"
printf '%s' "$OUT2" | jq -e '.verdict=="clean"' >/dev/null 2>&1 && ok "codex review helper returns clean verdict json" || bad "codex review helper missing clean verdict"
printf '%s' "$OUT2" | jq -e '.risk_level=="low"' >/dev/null 2>&1 && ok "codex review helper returns risk" || bad "codex review helper missing risk"
[ "$(grep -o -- '--dangerously-bypass-approvals-and-sandbox' "$ARGV_LOG" | wc -l | tr -d ' ')" = 1 ] && ok "codex review has one bypass flag" || bad "codex review bypass count wrong"
case " $(cat "$ARGV_LOG") " in *" -a "*|*" --ask-for-approval "*) bad "codex review should not pass approval flag" ;; *) ok "codex review omits conflicting approval flag" ;; esac

ID2="$(cd "$R" && PATH="$BIN:$PATH" CANOPY_ORCHESTRATOR_AGENT=codex "$CANOPY" task add 'default codex worker' 2>/dev/null)"
( cd "$R" && "$CANOPY" task set "$ID2" worktree "$R" >/dev/null 2>&1 )
SID2="$(cd "$R" && PATH="$BIN:$PATH" CANOPY_ORCHESTRATOR_AGENT=codex CANOPY_FAKE_CODEX_SLEEP=30 "$CANOPY" worker start --headless "$ID2" 2>/dev/null)"
[ "$SID2" = "codex-session-123" ] && ok "headless start follows Codex orchestrator" || bad "headless start did not use Codex"
[ "$(jq -r '.agent' "$R/.canopy/tasks/$ID2.json")" = codex ] && ok "headless start records Codex backend" || bad "headless start backend missing"
( cd "$R" && PATH="$BIN:$PATH" "$CANOPY" worker stop "$ID2" >/dev/null 2>&1 )

ID3="$(cd "$R" && "$CANOPY" task add 'recorded backend wins' 2>/dev/null)"
( cd "$R" && "$CANOPY" task set "$ID3" worktree "$R" >/dev/null 2>&1 )
( cd "$R" && "$CANOPY" task set "$ID3" agent codex >/dev/null 2>&1 )
SID3="$(cd "$R" && PATH="$BIN:$PATH" CANOPY_ORCHESTRATOR_AGENT=claude CANOPY_FAKE_CODEX_SLEEP=30 "$CANOPY" worker start --headless "$ID3" 2>/dev/null)"
[ "$SID3" = "codex-session-123" ] && ok "headless start prefers recorded task backend" || bad "headless start used orchestrator backend"
[ "$(jq -r '.agent' "$R/.canopy/tasks/$ID3.json")" = codex ] && ok "headless start preserves recorded backend" || bad "headless start changed recorded backend"
( cd "$R" && PATH="$BIN:$PATH" "$CANOPY" worker stop "$ID3" >/dev/null 2>&1 )

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
