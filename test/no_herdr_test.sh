#!/usr/bin/env bash
# Regression guard: stable (main) must NOT carry the experimental Herdr worker.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANOPY="$ROOT/bin/canopy"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# A leaked CANOPY_ROLE=worker from an enclosing canopy session would make the
# role guard (not the dispatch stub) handle `worker start` in assertion (d), and
# its message lacks the herdr-preview pointer. Clear it so we test the real stub.
export -n CANOPY_ROLE 2>/dev/null || true
unset CANOPY_ROLE 2>/dev/null || true

echo "== no-herdr regression =="

# (a) the Herdr implementation file is gone
[ ! -f "$ROOT/lib/herdr.sh" ] && ok "lib/herdr.sh removed" || bad "lib/herdr.sh still present"

# (b) no Herdr symbols remain anywhere in lib/ or bin/
if grep -RqiE '(_herdr_|canopy_herdr_|herdr_watchers_dir)' "$ROOT/lib" "$ROOT/bin"; then
  bad "Herdr symbols still referenced in lib/ or bin/"
else
  ok "no _herdr_/canopy_herdr_ symbols in lib or bin"
fi

# (c) bin/canopy no longer sources herdr.sh nor dispatches removed subcommands
if grep -q 'lib/herdr.sh' "$CANOPY"; then bad "bin/canopy still sources lib/herdr.sh"; else ok "bin/canopy does not source herdr.sh"; fi
if grep -qE 'canopy_worker_(start|attach|send|status|read|resume|reconcile|close|clean)' "$CANOPY" \
   || grep -qE 'canopy_herdr_supervise' "$CANOPY"; then
  bad "bin/canopy still dispatches a removed Herdr subcommand"
else
  ok "bin/canopy dispatch carries no removed Herdr subcommand"
fi

# (d) canopy worker start fails clearly, pointing at the herdr-preview channel
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
( cd "$WORK" && git init -q && git config user.email t@t && git config user.name t \
    && echo hi | tee f.txt >/dev/null && git add -A && git commit -qm init \
    && "$CANOPY" init >/dev/null 2>&1 )
id="$( cd "$WORK" && "$CANOPY" task add "demo" 2>/dev/null )"
err="$( cd "$WORK" && "$CANOPY" worker start "$id" 2>&1 )"; rc=$?
[ "$rc" -ne 0 ] && ok "worker start exits non-zero on stable" || bad "worker start unexpectedly succeeded"
printf '%s' "$err" | grep -q 'herdr-preview' && ok "worker start message points to herdr-preview" || bad "worker start message lacks herdr-preview pointer"

# (e) orchestrator.md keeps Herdr quarantined. Anchors pinned to the #69-merged strings.
# NOTE: the single "OFF by default ... See ... at the end" pointer at the top of the
# file names `canopy worker start` on purpose (to steer stable users AWAY from it);
# that warning is allowed outside the section. What must NOT appear outside the
# Experimental section is a *prescribed* Herdr command step. So we exclude the
# OFF-by-default warning line before asserting.
OM="$ROOT/agents/orchestrator.md"
PRE="$(sed '/^## Experimental: Herdr panes/,$d' "$OM" | grep -v 'OFF by default')"
printf '%s' "$PRE" | grep -q 'canopy worker start' \
  && bad "canopy worker start prescribed OUTSIDE the Experimental section" \
  || ok "no canopy worker start prescribed outside Experimental section"
grep -q '^## Experimental: Herdr panes (herdr-preview channel only)' "$OM" \
  && ok "Experimental Herdr section header present" \
  || bad "Experimental Herdr section header missing/renamed"
grep -q 'Spawn the worker via your Agent tool' "$OM" \
  && ok "built-in Agent-tool worker is the documented default" \
  || bad "default Agent-tool worker anchor missing"

printf '\n== no-herdr: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
