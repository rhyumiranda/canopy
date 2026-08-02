#!/usr/bin/env bash
# Day 8: SessionStart digest, orchestrator write-guard, block-PR-until-reviewed.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANOPY="$ROOT/bin/canopy"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }
command -v git >/dev/null || { echo "git required"; exit 1; }

echo "== day 8 hooks/guardrails =="

# --- SessionStart digest ---
R="$WORK/repo"; mkdir -p "$R"; ( cd "$R"; git init -q; git config user.email t@t; git config user.name t; echo x>f; git add -A; git commit -qm i )
( cd "$R" && "$CANOPY" init >/dev/null 2>&1 && "$CANOPY" task add "expose port" >/dev/null 2>&1 )
OUT="$(CLAUDE_PROJECT_DIR="$R" bash "$ROOT/hooks/session-start-digest.sh")"
echo "$OUT" | jq -e '.hookSpecificOutput.hookEventName=="SessionStart"' >/dev/null 2>&1 && ok "digest emits SessionStart JSON" || bad "digest bad JSON"
echo "$OUT" | jq -r '.hookSpecificOutput.additionalContext' | grep -q 'expose port' && ok "digest includes the task" || bad "digest missing task"
LEN="$(echo "$OUT" | jq -r '.hookSpecificOutput.additionalContext' | wc -c | tr -d ' ')"
[ "$LEN" -le 10000 ] && ok "digest under 10k ($LEN)" || bad "digest too long ($LEN)"
# no-op outside a canopy repo
EMPTY="$(CLAUDE_PROJECT_DIR="$WORK/none" bash "$ROOT/hooks/session-start-digest.sh")"
[ -z "$EMPTY" ] && ok "digest no-op outside canopy" || bad "digest should be empty outside canopy"

# --- write-guard ---
guard() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$1" '$c')" | CANOPY_ROLE=orchestrator bash "$ROOT/hooks/guard-project-write.sh"; }
guard 'echo hi > app.py' && bad "should block write to app.py" || ok "blocks 'echo > app.py'"
guard "sed -i 's/a/b/' src/x.js" && bad "should block sed -i" || ok "blocks sed -i on project file"
guard 'canopy task set t1 status done' && ok "allows canopy CLI" || bad "should allow canopy CLI"
guard 'echo x > .canopy/note.txt' && ok "allows .canopy/ writes" || bad "should allow .canopy writes"
guard 'git status && git diff' && ok "allows read-only git" || bad "should allow read-only git"
# inactive unless orchestrator role
printf '{"tool_name":"Bash","tool_input":{"command":"echo x > app.py"}}' | bash "$ROOT/hooks/guard-project-write.sh" && ok "guard inactive without orchestrator role" || bad "guard should be inactive without role"

# --- pr-create guard: PRs must go through 'canopy pr open', not gh/gh-axi directly ---
prguard() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$1" '$c')" | CANOPY_ROLE=orchestrator bash "$ROOT/hooks/guard-pr-create.sh"; }
prguard 'gh pr create --title x --body y'      && bad "should block gh pr create"      || ok "blocks 'gh pr create'"
prguard 'gh-axi pr create --title x'           && bad "should block gh-axi pr create"  || ok "blocks 'gh-axi pr create'"
prguard 'canopy pr open t1'                    && ok "allows 'canopy pr open'"          || bad "should allow canopy pr open"
prguard 'gh pr view 5 && gh pr checks 5'       && ok "allows other gh pr subcommands"   || bad "should allow gh pr view/checks"
# inactive unless orchestrator role
printf '{"tool_name":"Bash","tool_input":{"command":"gh pr create"}}' | bash "$ROOT/hooks/guard-pr-create.sh" && ok "pr-guard inactive without orchestrator role" || bad "pr-guard should be inactive without role"

# --- block-PR-until-reviewed ---
R2="$WORK/repo2"; mkdir -p "$R2"; ( cd "$R2"; git init -q; git config user.email t@t; git config user.name t; echo x>f; git add -A; git commit -qm i )
( cd "$R2" && "$CANOPY" init >/dev/null 2>&1 )
ID="$(cd "$R2" && "$CANOPY" task add "thing" 2>/dev/null)"
# fake a worktree + branch (real dir on a branch) so pr open reaches the review gate
WT="$WORK/wt"; mkdir -p "$WT"; ( cd "$WT"; git init -q; git config user.email t@t; git config user.name t; echo y>g; git add -A; git commit -qm i; git checkout -q -b rhyu/x )
( cd "$R2" && "$CANOPY" task set "$ID" worktree "$WT" >/dev/null && "$CANOPY" task set "$ID" branch rhyu/x >/dev/null )
# not reviewed -> pr open must refuse with the gate message
ERR="$(cd "$R2" && "$CANOPY" pr open "$ID" 2>&1 || true)"
echo "$ERR" | grep -qi 'not reviewed clean' && ok "pr open blocked until reviewed clean" || bad "pr open should block unreviewed: $ERR"
# mark reviewed clean -> the gate no longer fires (fails later at push instead)
( cd "$R2" && "$CANOPY" task set "$ID" reviewed clean >/dev/null )
ERR2="$(cd "$R2" && "$CANOPY" pr open "$ID" 2>&1 || true)"
echo "$ERR2" | grep -qi 'not reviewed clean' && bad "gate should pass once reviewed clean" || ok "gate passes once reviewed clean"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
