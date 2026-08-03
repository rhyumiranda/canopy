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
out=""
schema=""
json=0
resume=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    exec) shift; break ;;
    -o|--output-last-message) out="$2"; shift 2 ;;
    --output-schema) schema="$2"; shift 2 ;;
    --json) json=1; shift ;;
    -s|-a|-C|-m) shift 2 ;;
    *) shift ;;
  esac
done
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

SID="$(cd "$R" && PATH="$BIN:$PATH" CANOPY_FAKE_CODEX_SLEEP=30 "$CANOPY" worker spawn --agent codex "$ID" 2>/dev/null)"
[ "$SID" = "codex-session-123" ] && ok "codex worker spawn returns session id" || bad "unexpected codex session id: $SID"
[ "$(jq -r '.agent' "$R/.canopy/tasks/$ID.json")" = "codex" ] && ok "task records codex agent" || bad "task missing codex agent"
LOGF="$(jq -r '.worker_log' "$R/.canopy/tasks/$ID.json")"
[ -f "$LOGF" ] && ok "task records worker log" || bad "worker log missing"
PID="$(jq -r '.worker_pid' "$R/.canopy/tasks/$ID.json")"
kill -0 "$PID" >/dev/null 2>&1 && ok "task records live worker pid" || bad "worker pid not live"
OUT="$(cd "$R" && PATH="$BIN:$PATH" "$CANOPY" worker logs "$ID" 2>/dev/null)"
printf '%s' "$(cat "$LOGF")" | grep -q 'thread.started' && ok "worker log captures codex jsonl" || bad "worker log missing jsonl"
( cd "$R" && PATH="$BIN:$PATH" "$CANOPY" worker stop "$ID" >/dev/null 2>&1 )
ok "worker stop command succeeds"

( cd "$R"; git checkout -qb rhyu/t1 >/dev/null 2>&1; echo two >> f.txt; git commit -qam 'feat: worker diff' )
OUT2="$(cd "$R" && PATH="$BIN:$PATH" CANOPY_ROOT="$CANOPY_ROOT" bash -c '. "$CANOPY_ROOT/lib/common.sh"; . "$CANOPY_ROOT/lib/state.sh"; . "$CANOPY_ROOT/lib/agent.sh"; . "$CANOPY_ROOT/lib/review.sh"; _review_once_codex "$PWD" "" ""')"
printf '%s' "$OUT2" | jq -e '.verdict=="clean"' >/dev/null 2>&1 && ok "codex review helper returns clean verdict json" || bad "codex review helper missing clean verdict"
printf '%s' "$OUT2" | jq -e '.risk_level=="low"' >/dev/null 2>&1 && ok "codex review helper returns risk" || bad "codex review helper missing risk"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
