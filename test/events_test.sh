#!/usr/bin/env bash
# 'canopy events wait' as the TCC-independent orchestrator wake source: it drains
# the durable lifecycle queue (fed by the detached worker's idle Stop hook and the
# merge-watcher) from the session's own process. Proves it (a) returns a pre-queued
# terminal event and (b) times out cleanly when nothing is happening. Sandboxed via
# $HOME. Run: bash test/events_test.sh
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

# Guard against a leaked CANOPY_ROLE=worker from an enclosing canopy session,
# which would make watch-once's task_set fail the role gate (CI's clean env is fine).
export -n CANOPY_ROLE 2>/dev/null || true
unset CANOPY_ROLE 2>/dev/null || true

echo "== canopy events wait: primary TCC-independent wake source =="
H="$WORK/home"; mkdir -p "$H"
R="$(new_repo)"; cd "$R"; HOME="$H" "$CANOPY" init >/dev/null 2>&1

# --- (a) returns a pre-queued terminal event immediately (consume path) ---
ID="$(HOME="$H" "$CANOPY" task add "already finished" 2>/dev/null)"
HOME="$H" "$CANOPY" task status "$ID" done >/dev/null 2>&1   # enqueues a lifecycle event
OUT="$(HOME="$H" CANOPY_EVENTS_POLL_INTERVAL=1 "$CANOPY" events wait 1 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$OUT" | jq -e --arg id "$ID" '.task_id==$id and .status=="done"' >/dev/null 2>&1 \
  && ok "returns a pre-queued terminal event" || bad "should return the queued done event (rc=$rc): $OUT"

# --- (b) idle wake: the worker's Stop hook enqueues a non-terminal 'idle' event ---
R2="$(new_repo)"; cd "$R2"; HOME="$H" "$CANOPY" init >/dev/null 2>&1
ID2="$(HOME="$H" "$CANOPY" task add "worker finished a turn" 2>/dev/null)"
HOME="$H" "$CANOPY" task status "$ID2" implementing >/dev/null 2>&1
# `canopy worker idle` is exactly what the detached worker's seeded Stop hook runs.
HOME="$H" "$CANOPY" worker idle "$ID2" >/dev/null 2>&1
OUT="$(HOME="$H" CANOPY_EVENTS_POLL_INTERVAL=1 "$CANOPY" events wait 2 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$OUT" | jq -e --arg id "$ID2" '.task_id==$id and .status=="idle"' >/dev/null 2>&1 \
  && ok "idle Stop hook enqueues a wake event that events wait drains" \
  || bad "wait should return the idle event (rc=$rc): $OUT"

# --- (c) clean timeout when nothing is happening ---
R3="$(new_repo)"; cd "$R3"; HOME="$H" "$CANOPY" init >/dev/null 2>&1
HOME="$H" CANOPY_EVENTS_POLL_INTERVAL=1 "$CANOPY" events wait 1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "times out with exit 1 when no event lands" || bad "expected exit 1 on timeout, got $rc"

echo
echo "events: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
