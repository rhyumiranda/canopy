#!/usr/bin/env bash
# Guarded worker-session cleanup: the _herdr_safe_to_close chokepoint plus
# `canopy worker clean [--all]` and the CANOPY_WORKER_CLEANUP stop path. The guard
# must (A) never close a still-working worker, and (B) never leave a done+merged
# worker unclosable just because its pinned/report status staled at `working` —
# the working check reads the LIVE `agent explain` state, never the pinned status.
set -uo pipefail
# Simulate a clean/orchestrator env even when invoked from a worker shell, where
# CANOPY_ROLE=worker would otherwise refuse the orchestrator-only task setup.
unset CANOPY_ROLE 2>/dev/null || true
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; CANOPY="$ROOT/bin/canopy"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

mkdir -p "$WORK/bin"
# Fake Herdr. Ownership label + live state are both derived from the pane id
# (`p-<taskid>-<livestate>`) so a single stub serves many tasks with distinct
# states — exactly what an `--all` sweep needs.
cat > "$WORK/bin/herdr" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${HERDR_LOG:?}"
_pane_task() { local r="${1#p-}"; printf '%s' "${r%-*}"; }   # p-t1-idle -> t1
_pane_state() { local r="${1#p-}"; printf '%s' "${r##*-}"; } # p-t1-idle -> idle
case "$1 ${2:-}" in
  pane\ get)
    [ "${HERDR_PANE_GONE:-0}" = 1 ] && exit 1
    printf '%s\n' '{"result":{"pane":{"agent":"canopy-'"$(_pane_task "${3:-}")"'-claude"}}}' ;;
  tab\ get)
    printf '%s\n' '{"result":{"tab":{"label":"'"${3#tab-}"' · Claude"}}}' ;;
  agent\ explain)
    printf '%s\n' '{"result":{"agent":{"state":"'"$(_pane_state "${3:-}")"'"}}}' ;;
  wait\ agent-status) exit 1 ;;
  pane\ close|tab\ close|pane\ send-keys|agent\ send) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$WORK/bin/herdr"
# Fake gh-axi: PR #2 is still OPEN, every other PR is MERGED (drives _pr_is_merged).
cat > "$WORK/bin/gh-axi" <<'EOF'
#!/usr/bin/env bash
set -u
if [ "${3:-}" = 2 ]; then echo "state:  OPEN"; else echo "state:  MERGED"; fi
EOF
chmod +x "$WORK/bin/gh-axi"
cat > "$WORK/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$WORK/bin/launchctl"

R="$WORK/repo"; mkdir -p "$R"
( cd "$R" && git init -q && git config user.email t@t && git config user.name t && echo hi > f && git add f && git commit -qm init )
cd "$R"
ENV="HOME=$WORK/home HERDR_LOG=$WORK/herdr.log PATH=$WORK/bin:$PATH CANOPY_HERDR_BIN=$WORK/bin/herdr"
: > "$WORK/herdr.log"
eval "$ENV \"$CANOPY\" init >/dev/null 2>&1"

# seed <id> <live-state> <pr>  — a claude worker task with owned Herdr pane/tab
seed() {
  local id="$1" live="$2" pr="$3"
  eval "$ENV \"$CANOPY\" task set $id worktree $R >/dev/null 2>&1"
  eval "$ENV \"$CANOPY\" task set $id agent claude >/dev/null 2>&1"
  eval "$ENV \"$CANOPY\" task set $id herdr_pane_id p-$id-$live >/dev/null 2>&1"
  eval "$ENV \"$CANOPY\" task set $id herdr_tab_id tab-$id >/dev/null 2>&1"
  eval "$ENV \"$CANOPY\" task set $id pr $pr >/dev/null 2>&1"
}

# --- Case A: a live-WORKING worker refuses close (never kills live work) ---
IDW="$(eval "$ENV \"$CANOPY\" task add 'working worker' 2>/dev/null")"
seed "$IDW" working 1
eval "$ENV \"$CANOPY\" task status $IDW done >/dev/null 2>&1"
: > "$WORK/herdr.log"
if eval "$ENV \"$CANOPY\" worker clean $IDW >/dev/null 2>&1"; then bad 'clean must refuse a live-working worker'; else ok 'clean refuses a live-working worker'; fi
grep -q "pane close p-$IDW-working" "$WORK/herdr.log" && bad 'refused clean still closed the working pane' || ok 'refused clean never closed the pane'
[ "$(jq -r .herdr_pane_id "$R/.canopy/tasks/$IDW.json")" = "p-$IDW-working" ] && ok 'refused clean preserves pane id' || bad 'refused clean lost pane id'

# --- Case B: a merged + live-IDLE worker closes ---
IDI="$(eval "$ENV \"$CANOPY\" task add 'idle merged worker' 2>/dev/null")"
seed "$IDI" idle 1
eval "$ENV \"$CANOPY\" task status $IDI done >/dev/null 2>&1"
: > "$WORK/herdr.log"
eval "$ENV \"$CANOPY\" worker clean $IDI >/dev/null 2>&1" && ok 'clean closes a merged + live-idle worker' || bad 'clean failed on merged + idle worker'
grep -q "pane close p-$IDI-idle" "$WORK/herdr.log" && ok 'clean closes the idle pane' || bad 'clean did not close the idle pane'
grep -q "tab close tab-$IDI" "$WORK/herdr.log" && ok 'clean closes the tab' || bad 'clean did not close the tab'
[ "$(jq -r .herdr_pane_id "$R/.canopy/tasks/$IDI.json")" = "" ] && ok 'clean clears the closed pane id' || bad 'clean left a stale pane id'

# --- Case C: pinned status staled at working, but LIVE is idle -> still closes ---
# The Herdr/canopy report status is unreliable (it pins to `working` after a worker
# idles). The guard consults ONLY the live `agent explain` state, so this closes.
IDS="$(eval "$ENV \"$CANOPY\" task add 'stale working pin' 2>/dev/null")"
seed "$IDS" idle 1
eval "$ENV \"$CANOPY\" task status $IDS done >/dev/null 2>&1"
# pin a stale `working` agent_status on the task file (what a report would show)
eval "$ENV \"$CANOPY\" task set $IDS agent_status working >/dev/null 2>&1"
: > "$WORK/herdr.log"
eval "$ENV \"$CANOPY\" worker clean $IDS >/dev/null 2>&1" && ok 'stale-working pin with live-idle still closes' || bad 'stale-working pin blocked a live-idle close'
grep -q "pane close p-$IDS-idle" "$WORK/herdr.log" && ok 'stale-working pin: live state wins, pane closed' || bad 'stale-working pin wrongly consulted (pane not closed)'

# --- Case D: done but PR NOT merged (unshipped) refuses — the t23-loss regression ---
IDU="$(eval "$ENV \"$CANOPY\" task add 'unshipped worker' 2>/dev/null")"
seed "$IDU" idle 2   # PR #2 is OPEN
eval "$ENV \"$CANOPY\" task status $IDU done >/dev/null 2>&1"
: > "$WORK/herdr.log"
UERR="$(eval "$ENV \"$CANOPY\" worker clean $IDU 2>&1 >/dev/null" || true)"
grep -q "pane close" "$WORK/herdr.log" && bad 'clean closed an unshipped (PR-open) worker' || ok 'clean refuses an unshipped (PR-open) worker'
printf '%s' "$UERR" | grep -qi 'not safe to close' && ok 'refusal is actionable on stderr' || bad 'refusal message missing'

# --- Case E: not-done (still implementing) refuses ---
IDP="$(eval "$ENV \"$CANOPY\" task add 'still implementing' 2>/dev/null")"
seed "$IDP" idle 1
eval "$ENV \"$CANOPY\" task status $IDP implementing >/dev/null 2>&1"
: > "$WORK/herdr.log"
if eval "$ENV \"$CANOPY\" worker clean $IDP >/dev/null 2>&1"; then bad 'clean must refuse a not-done worker'; else ok 'clean refuses a not-done worker'; fi

# --- clean --all: closes safe workers and skips unsafe ones in one pass ---
# A fresh done+merged+idle worker that --all should close; IDW (working), IDU
# (open PR) and IDP (not done) still carry Herdr state and must be skipped.
IDF="$(eval "$ENV \"$CANOPY\" task add 'all sweep safe' 2>/dev/null")"
seed "$IDF" idle 1
eval "$ENV \"$CANOPY\" task status $IDF done >/dev/null 2>&1"
: > "$WORK/herdr.log"
ALL_OUT="$(eval "$ENV \"$CANOPY\" worker clean --all 2>/dev/null")"
grep -q "pane close p-$IDF-idle" "$WORK/herdr.log" && ok '--all closes a safe worker' || bad '--all did not close the safe worker'
grep -q "pane close p-$IDW-working" "$WORK/herdr.log" && bad '--all closed the working worker' || ok '--all skips the working worker'
grep -q "pane close p-$IDU-idle" "$WORK/herdr.log" && bad '--all closed the unshipped worker' || ok '--all skips the unshipped worker'
printf '%s' "$ALL_OUT" | grep -q '^cleaned: [1-9]' && ok '--all reports a nonzero cleaned count' || bad '--all cleaned count wrong'
printf '%s' "$ALL_OUT" | grep -q '^skipped: [1-9]' && ok '--all reports a nonzero skipped count' || bad '--all skipped count wrong'

# --- CANOPY_WORKER_CLEANUP stop path is guarded too ---
IDCW="$(eval "$ENV \"$CANOPY\" task add 'cleanup stop working' 2>/dev/null")"
seed "$IDCW" working 1
eval "$ENV \"$CANOPY\" task status $IDCW done >/dev/null 2>&1"
: > "$WORK/herdr.log"
CW_OUT="$(eval "$ENV CANOPY_WORKER_CLEANUP=1 \"$CANOPY\" worker stop $IDCW 2>/dev/null")"
grep -q "pane close p-$IDCW-working" "$WORK/herdr.log" && bad 'cleanup stop closed a working worker' || ok 'cleanup stop refuses a working worker'
printf '%s' "$CW_OUT" | grep -q '^cleaned: skipped' && ok 'cleanup stop reports skipped' || bad 'cleanup stop missing skipped report'

IDCI="$(eval "$ENV \"$CANOPY\" task add 'cleanup stop idle' 2>/dev/null")"
seed "$IDCI" idle 1
eval "$ENV \"$CANOPY\" task status $IDCI done >/dev/null 2>&1"
: > "$WORK/herdr.log"
CI_OUT="$(eval "$ENV CANOPY_WORKER_CLEANUP=1 \"$CANOPY\" worker stop $IDCI 2>/dev/null")"
grep -q "pane close p-$IDCI-idle" "$WORK/herdr.log" && ok 'cleanup stop closes a merged + idle worker' || bad 'cleanup stop did not close an idle worker'
printf '%s' "$CI_OUT" | grep -q '^cleaned: ok' && ok 'cleanup stop reports ok' || bad 'cleanup stop missing ok report'

# --- ergonomics: help on stdout (exit 0), unknown flag exits 2 ---
H="$(eval "$ENV \"$CANOPY\" worker clean --help 2>/dev/null")"; HRC=$?
{ [ "$HRC" = 0 ] && printf '%s' "$H" | grep -q 'usage: canopy worker clean'; } \
  && ok 'worker clean --help prints usage on stdout (exit 0)' || bad 'worker clean --help missing usage or nonzero'
UF_RC=0; eval "$ENV \"$CANOPY\" worker clean --bogus >/dev/null 2>&1" || UF_RC=$?
[ "$UF_RC" = 2 ] && ok 'worker clean rejects unknown flag (exit 2)' || bad "worker clean unknown flag exit $UF_RC"
MT_RC=0; eval "$ENV \"$CANOPY\" worker clean >/dev/null 2>&1" || MT_RC=$?
[ "$MT_RC" = 2 ] && ok 'worker clean without id or --all exits 2' || bad "worker clean no-arg exit $MT_RC"

printf '\n== %s passed, %s failed ==\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]
