#!/usr/bin/env bash
# Worker model pin: the Opus-4.8 default is passed as a real --model flag at launch
# (frontmatter model is a no-op for canopy-launched agents). Run: bash test/worker_model_test.sh
set -uo pipefail
CANOPY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANOPY="$CANOPY_ROOT/bin/canopy"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=[%s] got=[%s]\n' "$3" "$2"; }; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

echo "== worker model pin =="

# --- unit: _worker_model_for resolves the pin, honors the override, empty for codex
export CANOPY_ROOT
. "$CANOPY_ROOT/lib/common.sh"
. "$CANOPY_ROOT/lib/state.sh"
. "$CANOPY_ROOT/lib/agent.sh"
. "$CANOPY_ROOT/lib/worker.sh"
( unset CANOPY_WORKER_MODEL; eq "default worker model is Opus 4.8" "$(_worker_model_for claude)" "claude-opus-4-8" )
eq "CANOPY_WORKER_MODEL overrides the pin" "$(CANOPY_WORKER_MODEL=claude-sonnet-4-5 _worker_model_for claude)" "claude-sonnet-4-5"
eq "codex worker model empty unless set" "$(unset CANOPY_CODEX_WORKER_MODEL; _worker_model_for codex)" ""
eq "CANOPY_CODEX_WORKER_MODEL sets codex worker" "$(CANOPY_CODEX_WORKER_MODEL=gpt-x _worker_model_for codex)" "gpt-x"

# --- integration: `canopy worker spawn` (default claude) passes --model at launch
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
[ -n "${CANOPY_ARGV_LOG:-}" ] && printf '%s\n' "$*" >> "$CANOPY_ARGV_LOG"
# emit a line _parse_bg_id can read (contains "backgrounded" + a hex token)
echo "Agent session abc123def456 backgrounded"
EOF
chmod +x "$BIN/claude"

R="$WORK/repo"; mkdir -p "$R"
( cd "$R"; git init -q; git config user.email t@t; git config user.name t; echo one > f.txt; git add -A; git commit -qm init; git branch -M main )
( cd "$R" && "$CANOPY" init >/dev/null 2>&1 )
ID="$(cd "$R" && "$CANOPY" task add "feat: model-pinned worker" 2>/dev/null)"
( cd "$R" && "$CANOPY" task set "$ID" worktree "$R" >/dev/null 2>&1 )

ARGV_LOG="$WORK/claude.argv"
# HOME=temp so _claude_trust_path never touches the real ~/.claude.json
SID="$(cd "$R" && HOME="$WORK/home" PATH="$BIN:$PATH" CANOPY_ARGV_LOG="$ARGV_LOG" "$CANOPY" worker spawn "$ID" 2>/dev/null)"
[ "$SID" = "abc123def456" ] && ok "claude worker spawn returns session id" || bad "unexpected claude session id: $SID"
grep -q -- '--model claude-opus-4-8' "$ARGV_LOG" && ok "claude worker spawn passes --model claude-opus-4-8" || { cat "$ARGV_LOG" >&2; bad "claude worker spawn missing --model opus pin"; }

# override travels through the launch path too
: > "$ARGV_LOG"
ID2="$(cd "$R" && "$CANOPY" task add "feat: override model" 2>/dev/null)"
( cd "$R" && "$CANOPY" task set "$ID2" worktree "$R" >/dev/null 2>&1 )
( cd "$R" && HOME="$WORK/home" PATH="$BIN:$PATH" CANOPY_ARGV_LOG="$ARGV_LOG" CANOPY_WORKER_MODEL=claude-sonnet-4-5 "$CANOPY" worker spawn "$ID2" >/dev/null 2>&1 )
grep -q -- '--model claude-sonnet-4-5' "$ARGV_LOG" && ok "CANOPY_WORKER_MODEL override reaches the launch" || { cat "$ARGV_LOG" >&2; bad "override did not reach the launch"; }

# The empty-model guard (no stray --model flag) only fires on the codex worker path,
# where _worker_model_for has no default; the claude path always carries the Opus
# default. The unit assertion above ("codex worker model empty unless set") covers it.

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
