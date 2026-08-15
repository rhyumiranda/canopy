#!/usr/bin/env bash
# reviewer-edge: `canopy review --edge` merges an adversarial second pass into the main
# reviewer's verdict (union of issues, HIGHER risk wins), auto-runs on a high-risk main
# verdict, and falls back to the main verdict when the edge pass fails — never aborts.
# Run: bash test/review_edge_test.sh
set -uo pipefail
CANOPY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANOPY="$CANOPY_ROOT/bin/canopy"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=[%s] got=[%s]\n' "$3" "$2"; }; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

echo "== reviewer-edge merge =="

# --- unit: pure merge + frontmatter-model helpers (no LLM) --------------------
export CANOPY_ROOT
. "$CANOPY_ROOT/lib/common.sh"
. "$CANOPY_ROOT/lib/agent.sh"
. "$CANOPY_ROOT/lib/review.sh"

# The edge def pins a model in frontmatter; _agent_body strips it, so a CLI launch must
# re-read it and pass --model explicitly. Assert the helper recovers the pinned model.
printf '%s' "$(_agent_frontmatter_model reviewer-edge)" | grep -q '.' \
  && ok "edge frontmatter model is recovered for explicit --model" \
  || bad "edge frontmatter model not recovered"

MAIN_LOW='{"verdict":"clean","risk_level":"low","risk_rationale":"ok","issues":[{"severity":"low","action":"no-op","where":"a.sh:1","problem":"P1","fix":"f"}],"docs_in_sync":true,"summary":"main"}'
EDGE_HIGH='{"verdict":"issues","risk_level":"high","risk_rationale":"boundary","issues":[{"severity":"high","action":"worker-fix","where":"b.sh:2","problem":"P2","fix":"g"},{"severity":"low","action":"no-op","where":"a.sh:1","problem":"P1","fix":"f"}],"docs_in_sync":false,"summary":"edge"}'
M="$(_merge_verdicts "$MAIN_LOW" "$EDGE_HIGH")"
eq "merge: verdict=issues when either pass found issues" "$(printf '%s' "$M" | jq -r '.verdict')" "issues"
eq "merge: risk_level = the HIGHER of the two (high)"    "$(printf '%s' "$M" | jq -r '.risk_level')" "high"
eq "merge: issues are the UNION, deduped by where+problem" "$(printf '%s' "$M" | jq '.issues|length')" "2"
eq "merge: docs_in_sync false if EITHER pass flags it"     "$(printf '%s' "$M" | jq -r '.docs_in_sync')" "false"
# clean+clean stays clean; higher risk still wins
M2="$(_merge_verdicts '{"verdict":"clean","risk_level":"low","issues":[],"docs_in_sync":true,"summary":"m"}' '{"verdict":"clean","risk_level":"med","issues":[],"docs_in_sync":true,"summary":"e"}')"
eq "merge: clean+clean -> clean"          "$(printf '%s' "$M2" | jq -r '.verdict')" "clean"
eq "merge: risk still climbs to the max"  "$(printf '%s' "$M2" | jq -r '.risk_level')" "med"

# --- integration: stub `claude` on PATH, serve canned main/edge JSON ----------
# The stub tells the two passes apart by the edge def's system-prompt marker
# ("edge-case reviewer"), logs which pass it served, then emits the matching JSON.
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
argv="$*"
if printf '%s' "$argv" | grep -qi 'edge-case reviewer'; then
  printf 'edge\n' >> "$CANOPY_CLAUDE_LOG"
  cat "$CANOPY_EDGE_JSON"
else
  printf 'main\n' >> "$CANOPY_CLAUDE_LOG"
  cat "$CANOPY_MAIN_JSON"
fi
EOF
chmod +x "$BIN/claude"

MAINF="$WORK/main.json"; EDGEF="$WORK/edge.json"; LOG="$WORK/claude.log"

# a repo with a real base..head diff so the reviewer path actually runs
R="$WORK/repo"; mkdir -p "$R"
(
  cd "$R"; git init -q; git config user.email t@t; git config user.name t
  echo base > f.txt; git add -A; git commit -qm init; git branch -M main
  git checkout -qb feat; echo change >> f.txt; git add -A; git commit -qm "feat: change"
)
( cd "$R" && "$CANOPY" init >/dev/null 2>&1 )

# helper: leased task pointing at the repo worktree
new_task() {
  local id; id="$(cd "$R" && "$CANOPY" task add "feat: $1" 2>/dev/null)"
  ( cd "$R" && "$CANOPY" task set "$id" worktree "$R" >/dev/null 2>&1 )
  printf '%s\n' "$id"
}
REV_OUT=""; REV_ERR=""; REV_RC=0
runrev() { # runrev <extra-args...> <id>  -> sets REV_OUT (verdict JSON), REV_RC, REV_ERR
  local err="$WORK/stderr"
  REV_OUT="$(cd "$R" && HOME="$WORK/home" PATH="$BIN:$PATH" \
        CANOPY_CLAUDE_LOG="$LOG" CANOPY_MAIN_JSON="$MAINF" CANOPY_EDGE_JSON="$EDGEF" \
        "$CANOPY" review "$@" 2>"$err")"; REV_RC=$?
  REV_ERR="$(cat "$err")"
}

# (1) --edge runs BOTH passes and the merged verdict takes the higher risk + union
printf '%s' "$MAIN_LOW"  > "$MAINF"
printf '%s' "$EDGE_HIGH" > "$EDGEF"
: > "$LOG"
ID1="$(new_task edge-both)"
runrev --edge "$ID1"; V1="$REV_OUT"
eq "--edge: main pass ran" "$(grep -c '^main$' "$LOG")" "1"
eq "--edge: edge pass ran" "$(grep -c '^edge$' "$LOG")" "1"
eq "--edge: merged verdict = issues (edge found issues)" "$(printf '%s' "$V1" | jq -r '.verdict')" "issues"
eq "--edge: merged risk = high (the higher of low+high)"  "$(printf '%s' "$V1" | jq -r '.risk_level')" "high"
eq "--edge: merged issues are the union (2)"              "$(printf '%s' "$V1" | jq '.issues|length')" "2"
eq "--edge: issues verdict exits non-zero"                "$REV_RC" "1"

# (2) without --edge only the MAIN reviewer runs (behavior unchanged)
printf '%s' "$MAIN_LOW" > "$MAINF"
printf '%s' "$EDGE_HIGH" > "$EDGEF"
: > "$LOG"
ID2="$(new_task main-only)"
runrev "$ID2"; V2="$REV_OUT"
eq "no --edge: main pass ran once" "$(grep -c '^main$' "$LOG")" "1"
eq "no --edge: edge pass did NOT run" "$(grep -c '^edge$' "$LOG")" "0"
eq "no --edge: verdict is the main reviewer's (clean)" "$(printf '%s' "$V2" | jq -r '.verdict')" "clean"
eq "no --edge: risk is the main reviewer's (low)"       "$(printf '%s' "$V2" | jq -r '.risk_level')" "low"

# (3) a high-risk MAIN verdict AUTO-runs the edge pass (defense-in-depth), no flag
MAIN_HIGH='{"verdict":"issues","risk_level":"high","risk_rationale":"auth","issues":[{"severity":"high","action":"worker-fix","where":"c.sh:3","problem":"P3","fix":"h"}],"docs_in_sync":true,"summary":"main-high"}'
printf '%s' "$MAIN_HIGH" > "$MAINF"
printf '%s' "$EDGE_HIGH" > "$EDGEF"
: > "$LOG"
ID3="$(new_task auto-high)"
runrev "$ID3"; V3="$REV_OUT"
eq "auto-high: edge pass auto-ran on high-risk main" "$(grep -c '^edge$' "$LOG")" "1"
eq "auto-high: union merges both passes' issues (3, none overlap)"  "$(printf '%s' "$V3" | jq '.issues|length')" "3"

# (4) --no-edge disables the auto-on-high edge pass
printf '%s' "$MAIN_HIGH" > "$MAINF"
printf '%s' "$EDGE_HIGH" > "$EDGEF"
: > "$LOG"
ID4="$(new_task no-edge)"
runrev --no-edge "$ID4"; V4="$REV_OUT"
eq "--no-edge: edge pass suppressed even on high risk" "$(grep -c '^edge$' "$LOG")" "0"
eq "--no-edge: verdict is the main reviewer's alone"    "$(printf '%s' "$V4" | jq '.issues|length')" "1"

# (5) FAIL-SAFE: an unparseable edge pass warns and falls back to the main verdict,
#     never aborting the review (exit code + stdout follow the main verdict).
printf '%s' "$MAIN_LOW" > "$MAINF"
printf 'not json at all — the edge model went off the rails' > "$EDGEF"
: > "$LOG"
ID5="$(new_task edge-garbage)"
runrev --edge "$ID5"; V5="$REV_OUT"
eq "fail-safe: both passes were attempted" "$(grep -c '^edge$' "$LOG")" "1"
eq "fail-safe: verdict falls back to the MAIN verdict (clean)" "$(printf '%s' "$V5" | jq -r '.verdict')" "clean"
eq "fail-safe: review still exits 0 (no abort)" "$REV_RC" "0"
printf '%s' "$REV_ERR" | grep -qi 'falling back' \
  && ok "fail-safe: emits a fallback warning" || bad "fail-safe: no fallback warning"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
