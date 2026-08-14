#!/usr/bin/env bash
# Worker role isolation: a worker shares the orchestrator's .canopy (via
# git-common-dir), so a worker-role `canopy` invocation must NOT be able to
# mutate the orchestrator board/tasks. Regression for the observed stall where a
# worker nulled its own herdr_pane_id/herdr_tab_id/worker_session in the LIVE
# orchestrator state, so the orchestrator lost the worker and hung.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANOPY="$ROOT/bin/canopy"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }
command -v git >/dev/null || { echo "git required"; exit 1; }

echo "== worker role isolation guard =="

R="$WORK/repo"; mkdir -p "$R"
( cd "$R"; git init -q; git config user.email t@t; git config user.name t; echo x>f; git add -A; git commit -qm i )
( cd "$R" && "$CANOPY" init >/dev/null 2>&1 )
ID="$(cd "$R" && "$CANOPY" task add "task about canopy" 2>/dev/null)"
# seed the exact Herdr-identity fields the orchestrator relies on to track a worker
( cd "$R" && "$CANOPY" task set "$ID" herdr_pane_id "wF:p5" >/dev/null 2>&1 )

SF="$R/.canopy/state.json"; TF="$R/.canopy/tasks/$ID.json"
STATE_BEFORE="$(cat "$SF")"; TASK_BEFORE="$(cat "$TF")"

# --- the core regression: the command that caused the stall must be refused ---
if ( cd "$R" && CANOPY_ROLE=worker "$CANOPY" task set "$ID" herdr_pane_id "" ) >/dev/null 2>&1; then
  bad "worker 'task set' should be refused"
else
  ok "worker 'task set' refused (exit non-zero)"
fi
[ "$(cat "$TF")" = "$TASK_BEFORE" ] && ok "task detail file untouched by refused worker command" || bad "worker mutated the task detail file"
[ "$(cat "$SF")" = "$STATE_BEFORE" ] && ok "orchestrator board untouched by refused worker command" || bad "worker mutated the board"
[ "$(jq -r '.herdr_pane_id' "$TF")" = "wF:p5" ] && ok "herdr_pane_id survives worker command" || bad "herdr_pane_id was clobbered"

# --- every other orchestrator-only mutation is refused under worker role ---
refused() { ( cd "$R" && CANOPY_ROLE=worker "$CANOPY" "$@" ) >/dev/null 2>&1; }
for c in "task status $ID done" "task add sneaky" "worker spawn $ID" \
         "worktree lease $ID" "pr open $ID" "mode yolo" "base main" "init" "recover"; do
  # shellcheck disable=SC2086
  if refused $c; then bad "worker should be refused: canopy $c"; else ok "worker refused: canopy $c"; fi
done

# --- worker-safe commands (reads + verify + its own progress notes) still work ---
allowed() { ( cd "$R" && CANOPY_ROLE=worker "$CANOPY" "$@" ) >/dev/null 2>&1; }
allowed task checkpoint "$ID" "left off here" && ok "worker allowed: task checkpoint" || bad "worker task checkpoint should work"
allowed task show "$ID"                        && ok "worker allowed: task show"       || bad "worker task show should work"
allowed status                                  && ok "worker allowed: status"          || bad "worker status should work"
allowed events list                             && ok "worker allowed: events list"     || bad "worker events list should work"
allowed version                                 && ok "worker allowed: version"         || bad "worker version should work"
# checkpoint touches only the worker's own detail file, never the board
[ "$(cat "$SF")" = "$STATE_BEFORE" ] && ok "worker checkpoint left the board untouched" || bad "worker checkpoint mutated the board"

# --- the guard is a strict no-op for the orchestrator (and a plain shell) ---
( cd "$R" && CANOPY_ROLE=orchestrator "$CANOPY" task set "$ID" pr 7 ) >/dev/null 2>&1 \
  && ok "orchestrator role can still mutate tasks" || bad "orchestrator must not be blocked"
( cd "$R" && env -u CANOPY_ROLE "$CANOPY" task set "$ID" pr 8 ) >/dev/null 2>&1 \
  && ok "plain shell (no role) can still mutate tasks" || bad "unset role must not be blocked"

# --- detached workers are launched with CANOPY_ROLE=worker (guard is inert otherwise) ---
grep -q 'CANOPY_ROLE=worker claude --bg' "$ROOT/lib/worker.sh" && ok "headless claude worker launched as CANOPY_ROLE=worker" || bad "headless claude launch missing CANOPY_ROLE=worker"
grep -q 'CANOPY_ROLE=worker codex' "$ROOT/lib/worker.sh" && ok "headless codex worker launched as CANOPY_ROLE=worker" || bad "headless codex launch missing CANOPY_ROLE=worker"

# --- the PR-create guard also fires under worker role (workers never open PRs) ---
prguard() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$1" '$c')" | CANOPY_ROLE=worker bash "$ROOT/hooks/guard-pr-create.sh"; }
prguard 'gh pr create --title x' && bad "worker should be blocked from gh pr create" || ok "worker blocked from 'gh pr create'"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
