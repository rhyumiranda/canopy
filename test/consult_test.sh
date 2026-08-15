#!/usr/bin/env bash
# consult.sh — the headless launch path for the advisory agents (oracle,
# plan-gate). Asserts the launch argv (--allowedTools, --append-system-prompt,
# --model from frontmatter), stdout passthrough, and that a worker-role shell may
# call `canopy oracle`. Run: bash test/consult_test.sh
set -uo pipefail
CANOPY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANOPY="$CANOPY_ROOT/bin/canopy"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=[%s] got=[%s]\n' "$3" "$2"; }; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

echo "== consult (oracle / plan-gate) launch path =="

# --- unit: _agent_model parses the def's frontmatter model:, empty when absent ---
export CANOPY_ROOT
. "$CANOPY_ROOT/lib/common.sh"
. "$CANOPY_ROOT/lib/agent.sh"
. "$CANOPY_ROOT/lib/review.sh"    # _extract_json (shared)
. "$CANOPY_ROOT/lib/consult.sh"
eq "oracle model parsed from frontmatter"    "$(_agent_model oracle)"    "claude-opus-4-8"
eq "plan-gate model parsed from frontmatter" "$(_agent_model plan-gate)" "claude-haiku-4-5-20251001"
eq "worker has no model: line -> empty"      "$(_agent_model worker)"    ""

# --- stub claude: logs its argv, echoes a canned answer ---
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
[ -n "${CANOPY_ARGV_LOG:-}" ] && printf '%s\n' "$*" >> "$CANOPY_ARGV_LOG"
printf '%s\n' "ORACLE_SAYS: pick option B"
EOF
chmod +x "$BIN/claude"

R="$WORK/repo"; mkdir -p "$R"
( cd "$R"; git init -q; git config user.email t@t; git config user.name t; echo x>f; git add -A; git commit -qm i; git branch -M main )
( cd "$R" && "$CANOPY" init >/dev/null 2>&1 )

ARGV_LOG="$WORK/claude.argv"
# HOME=temp so _claude_trust_path never touches the real ~/.claude.json
OUT="$(cd "$R" && HOME="$WORK/home" PATH="$BIN:$PATH" CANOPY_ARGV_LOG="$ARGV_LOG" "$CANOPY" oracle "which approach?" 2>/dev/null)"

eq "oracle returns the stub's stdout" "$OUT" "ORACLE_SAYS: pick option B"
grep -q -- '--allowedTools Read Grep Glob' "$ARGV_LOG" && ok "oracle launches with --allowedTools Read Grep Glob" || { cat "$ARGV_LOG" >&2; bad "oracle missing --allowedTools Read Grep Glob"; }
grep -q -- '--append-system-prompt' "$ARGV_LOG" && ok "oracle passes --append-system-prompt" || bad "oracle missing --append-system-prompt"
grep -q -- '--model claude-opus-4-8' "$ARGV_LOG" && ok "oracle passes --model from frontmatter" || { cat "$ARGV_LOG" >&2; bad "oracle missing --model opus (frontmatter strip regression)"; }
# the appended system prompt IS the oracle body (frontmatter stripped) — a body
# marker must appear in the argv, proving _agent_body oracle was passed through.
grep -qi 'Canopy oracle' "$ARGV_LOG" && ok "oracle system prompt is _agent_body oracle" || bad "oracle body not in argv"
# the question reaches claude as the prompt arg
grep -q 'which approach?' "$ARGV_LOG" && ok "oracle passes the question as the prompt" || bad "oracle question missing from argv"

# --- -C/--cwd points the oracle at a worktree (still launches; trust pre-marked) ---
# Seed an existing config so _claude_trust_path rewrites it (it no-ops when the
# file is absent, since Claude treats a fresh install as trusted anyway).
: > "$ARGV_LOG"
mkdir -p "$WORK/home"; printf '%s' '{"projects":{}}' > "$WORK/home/.claude.json"
WT="$WORK/wt"; mkdir -p "$WT"
OUT2="$(cd "$R" && HOME="$WORK/home" PATH="$BIN:$PATH" CANOPY_ARGV_LOG="$ARGV_LOG" "$CANOPY" oracle -C "$WT" "read the code" 2>/dev/null)"
eq "oracle -C still returns stub stdout" "$OUT2" "ORACLE_SAYS: pick option B"
# trust was pre-marked for the passed cwd
[ "$(jq -r --arg p "$WT" '.projects[$p].hasTrustDialogAccepted // false' "$WORK/home/.claude.json" 2>/dev/null)" = true ] \
  && ok "oracle -C pre-marks the worktree trusted" || bad "oracle -C did not pre-mark folder trust"

# --- plan-gate reads .canopy/plans/<id>.md and returns extracted JSON ---
# stub emits a fenced verdict to prove _extract_json unwraps it.
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
[ -n "${CANOPY_ARGV_LOG:-}" ] && printf '%s\n' "$*" >> "$CANOPY_ARGV_LOG"
printf '```json\n{"verdict":"approve","feasible":true,"risk_level":"low","gaps":[],"summary":"ok"}\n```\n'
EOF
chmod +x "$BIN/claude"
: > "$ARGV_LOG"
mkdir -p "$R/.canopy/plans"
printf 'Plan for t1: do the thing.\n' > "$R/.canopy/plans/t1.md"
PG="$(cd "$R" && HOME="$WORK/home" PATH="$BIN:$PATH" CANOPY_ARGV_LOG="$ARGV_LOG" "$CANOPY" plan-gate t1 2>/dev/null)"
eq "plan-gate returns the verdict" "$(printf '%s' "$PG" | jq -r '.verdict')" "approve"
grep -q -- '--model claude-haiku-4-5-20251001' "$ARGV_LOG" && ok "plan-gate passes its cheap --model from frontmatter" || { cat "$ARGV_LOG" >&2; bad "plan-gate missing --model haiku"; }
grep -q 'do the thing' "$ARGV_LOG" && ok "plan-gate feeds the plan artifact into the prompt" || bad "plan-gate did not read the plan"
# missing plan artifact is a clean error, not a launch
if ( cd "$R" && HOME="$WORK/home" PATH="$BIN:$PATH" "$CANOPY" plan-gate nope ) >/dev/null 2>&1; then
  bad "plan-gate should fail on a missing plan artifact"
else
  ok "plan-gate errors when the plan artifact is missing"
fi

# --- role guard: a worker MAY call oracle/plan-gate; use env -u per AGENTS.md ---
if ( cd "$R" && env -u CANOPY_ROLE HOME="$WORK/home" PATH="$BIN:$PATH" CANOPY_ROLE=worker "$CANOPY" oracle "q" ) >/dev/null 2>&1; then
  ok "worker role is ALLOWED to run canopy oracle"
else
  bad "worker role was refused canopy oracle"
fi
if ( cd "$R" && env -u CANOPY_ROLE HOME="$WORK/home" PATH="$BIN:$PATH" CANOPY_ROLE=worker "$CANOPY" plan-gate t1 ) >/dev/null 2>&1; then
  ok "worker role is ALLOWED to run canopy plan-gate"
else
  bad "worker role was refused canopy plan-gate"
fi
# _worker_cmd_allowed direct unit (clean env, no leaked CANOPY_ROLE)
( env -u CANOPY_ROLE bash -c '. "'"$CANOPY_ROOT"'/lib/common.sh"; _worker_cmd_allowed oracle && _worker_cmd_allowed plan-gate' ) \
  && ok "_worker_cmd_allowed permits oracle and plan-gate" || bad "_worker_cmd_allowed refuses the consult commands"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
