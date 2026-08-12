#!/usr/bin/env bash
# 'canopy events wait' as the PRIMARY, TCC-independent orchestrator wake source.
# Proves it (a) returns a pre-queued terminal event, (b) ACTIVELY probes live
# Herdr panes itself and enqueues+returns a terminal outcome with NO launchd
# supervisor/watcher in play (the TCC-blocked case), and (c) times out cleanly
# when nothing is happening. Sandboxed via $HOME + a stub `herdr` on PATH.
# Run: bash test/events_test.sh
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

# --- (b) ACTIVE PROBE: no launchd at all, event only exists because wait probed ---
# Stub `herdr` on PATH so _herdr_probe_state reports the worker done.
STUB="$WORK/bin"; mkdir -p "$STUB"
cat > "$STUB/herdr" <<'EOF'
#!/usr/bin/env bash
set -u
case "$1 ${2:-}" in
  "pane get") exit 0 ;;                                   # pane still exists
  "agent explain") printf '{"result":{"agent":{"status":"done"}}}\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$STUB/herdr"

R2="$(new_repo)"; cd "$R2"; HOME="$H" "$CANOPY" init >/dev/null 2>&1
ID2="$(HOME="$H" "$CANOPY" task add "live worker finishing" 2>/dev/null)"
HOME="$H" "$CANOPY" task status "$ID2" implementing >/dev/null 2>&1   # active, so watch-once probes it
HOME="$H" "$CANOPY" task set "$ID2" herdr_pane_id "wA:p1" >/dev/null 2>&1
# Nothing is queued yet; the ONLY path to an event is wait actively probing the pane.
QN="$(HOME="$H" "$CANOPY" events list 2>/dev/null | wc -l | tr -d ' ')"
[ "$QN" = "0" ] && ok "no event queued before wait (launchd path absent)" || bad "expected empty queue, got $QN"
OUT="$(PATH="$STUB:$PATH" HOME="$H" CANOPY_EVENTS_POLL_INTERVAL=1 "$CANOPY" events wait 5 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$OUT" | jq -e --arg id "$ID2" '.task_id==$id and .status=="done"' >/dev/null 2>&1 \
  && ok "wait actively probes the pane and returns the terminal event (TCC-independent)" \
  || bad "wait should self-probe and return done (rc=$rc): $OUT"
# and it flipped the board status as a side effect of the probe
ST="$(HOME="$H" "$CANOPY" task show "$ID2" 2>/dev/null | jq -r '.status')"
[ "$ST" = "done" ] && ok "probe flipped the task to done" || bad "task should be done, is $ST"

# --- (c) clean timeout when nothing is happening and no Herdr is available ---
R3="$(new_repo)"; cd "$R3"; HOME="$H" "$CANOPY" init >/dev/null 2>&1
HOME="$H" CANOPY_EVENTS_POLL_INTERVAL=1 "$CANOPY" events wait 1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "times out with exit 1 when no event lands" || bad "expected exit 1 on timeout, got $rc"

echo
echo "events: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
