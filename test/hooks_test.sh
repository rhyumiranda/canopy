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
# orchestrator role -> full digest (playbook + board)
OUT="$(CLAUDE_PROJECT_DIR="$R" CANOPY_ROLE=orchestrator bash "$ROOT/hooks/session-start-digest.sh")"
echo "$OUT" | jq -e '.hookSpecificOutput.hookEventName=="SessionStart"' >/dev/null 2>&1 && ok "digest emits SessionStart JSON" || bad "digest bad JSON"
echo "$OUT" | jq -r '.hookSpecificOutput.additionalContext' | grep -q 'expose port' && ok "digest includes the task" || bad "digest missing task"
echo "$OUT" | jq -r '.hookSpecificOutput.additionalContext' | grep -q 'You are the orchestrator' && ok "digest includes orchestrator playbook" || bad "digest missing playbook"
LEN="$(echo "$OUT" | jq -r '.hookSpecificOutput.additionalContext' | wc -c | tr -d ' ')"
[ "$LEN" -le 10000 ] && ok "digest under 10k ($LEN)" || bad "digest too long ($LEN)"
# Codex branch (no CLAUDE_PROJECT_DIR): plain text digest from inside the repo
CTX="$(cd "$R" && CANOPY_ROLE=orchestrator bash "$ROOT/hooks/session-start-digest.sh")"
echo "$CTX" | grep -q 'expose port' && ok "codex digest is plain-text with task" || bad "codex digest missing task"
# non-orchestrator role in a canopy repo -> one-line hint only, no board/playbook
HINT="$(env -u CANOPY_ROLE CLAUDE_PROJECT_DIR="$R" bash "$ROOT/hooks/session-start-digest.sh")"
echo "$HINT" | jq -e '.hookSpecificOutput.hookEventName=="SessionStart"' >/dev/null 2>&1 && ok "hint emits valid SessionStart JSON" || bad "hint bad JSON"
HC="$(echo "$HINT" | jq -r '.hookSpecificOutput.additionalContext')"
echo "$HC" | grep -qi 'run `canopy start`' && ok "non-orchestrator gets the one-line hint" || bad "non-orchestrator missing hint"
echo "$HC" | grep -q 'expose port' && bad "hint must not leak the board" || ok "hint omits the board"
echo "$HC" | grep -q 'You are the orchestrator' && bad "hint must not claim orchestrator role" || ok "hint omits playbook"
# no-op outside a canopy repo (even as orchestrator)
EMPTY="$(CLAUDE_PROJECT_DIR="$WORK/none" CANOPY_ROLE=orchestrator bash "$ROOT/hooks/session-start-digest.sh")"
[ -z "$EMPTY" ] && ok "digest no-op outside canopy" || bad "digest should be empty outside canopy"

# --- write-guard ---
# Build a real MAIN project tree and a real LINKED worktree so the guard's
# worker-worktree exemption is exercised the way it fires in production (workers
# inherit CANOPY_ROLE=orchestrator; only their leased LINKED worktree exempts).
# NOTE: this suite itself runs inside a linked worktree, so the cwd MUST be set
# explicitly per assertion — running the guard from the suite's own cwd would be
# auto-exempted and silently pass every "should block" case.
GR="$WORK/guardrepo"; mkdir -p "$GR"; ( cd "$GR"; git init -q; git config user.email t@t; git config user.name t; echo x>f; git add -A; git commit -qm i )
GWT="$WORK/guardrepo-wt"; ( cd "$GR" && git worktree add -q -b guardfeat "$GWT" >/dev/null 2>&1 )
GTH="$WORK/.treehouse/pool/1/repo"; mkdir -p "$GTH"       # treehouse-style path (fallback signal)
GOUT="$WORK/out-of-tree.txt"                              # a path outside the project tree
# guard <cmd> [cwd]  -> runs the hook under inherited orchestrator role from <cwd> (default: main tree)
guard() { local c="$1" d="${2:-$GR}"; ( cd "$d" && printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg cc "$c" '$cc')" | CANOPY_ROLE=orchestrator bash "$ROOT/hooks/guard-project-write.sh" ); }
# --- still blocks: genuine orchestrator writes that land in the project tree ---
guard 'echo hi > app.py' && bad "should block write to app.py" || ok "blocks 'echo > app.py'"
guard "sed -i 's/a/b/' src/x.js" && bad "should block sed -i" || ok "blocks sed -i on project file"
guard 'echo hi >> app.py' && bad "should block append to app.py" || ok "blocks 'echo >> app.py'"
guard 'echo hi > src/app.py' && bad "should block nested project write" || ok "blocks write to src/app.py"
# --- still allows: read-only / CLI / state / scratch ---
guard 'canopy task set t1 status done' && ok "allows canopy CLI" || bad "should allow canopy CLI"
guard 'echo x > .canopy/note.txt' && ok "allows .canopy/ writes" || bad "should allow .canopy writes"
guard 'git status && git diff' && ok "allows read-only git" || bad "should allow read-only git"
# BUG3 fix: redirects whose TARGET is not in the project tree must be allowed
guard 'canopy task checkpoint t1 done >/dev/null' && ok "allows redirect to /dev/null" || bad "should allow >/dev/null"
guard 'echo x 2>/dev/null' && ok "allows stderr redirect to /dev/null" || bad "should allow 2>/dev/null"
guard 'echo x > /tmp/scratch.txt' && ok "allows redirect to /tmp" || bad "should allow >/tmp"
guard "echo x > $GOUT" && ok "allows redirect to out-of-tree path" || bad "should allow out-of-tree redirect"
# BUG1 fix: angle brackets / '>' inside QUOTED args are not redirects (de-quoted first)
guard "git commit -m 'add <name> field'" && ok "allows quoted <name> (single quotes)" || bad "quoted <name> must not trip guard"
guard 'git commit -m "wrap <b> tag"' && ok "allows quoted <b> (double quotes)" || bad "quoted <b> must not trip guard"
guard "canopy task add 'implement a>b compare'" && ok "allows quoted '>' in a CLI arg" || bad "quoted > must not trip guard"
# BUG2 fix: a worker in its OWN leased worktree may write it, even under the
# inherited orchestrator role — exempt via linked-worktree AND treehouse-path signals.
guard 'echo hi > app.py' "$GWT" && ok "allows write from a linked worktree (worker)" || bad "worker worktree write must be allowed"
guard "sed -i 's/a/b/' src/x.js" "$GWT" && ok "allows sed -i from a linked worktree" || bad "worker sed -i must be allowed"
guard 'echo hi > app.py' "$GTH" && ok "allows write from a treehouse-path worktree" || bad "treehouse worktree write must be allowed"
# inactive unless orchestrator role
printf '{"tool_name":"Bash","tool_input":{"command":"echo x > app.py"}}' | env -u CANOPY_ROLE bash "$ROOT/hooks/guard-project-write.sh" && ok "guard inactive without orchestrator role" || bad "guard should be inactive without role"
# BUG4 fix: stdin is drained before any early exit, so a writer under pipefail
# feeding a large payload never gets SIGPIPE (was a flaky exit 141).
sigp=0; big="$(printf 'x%.0s' $(seq 1 200000))"
for _ in $(seq 1 20); do ( set -o pipefail; printf '{"tool_name":"Bash","tool_input":{"command":"echo %s"}}' "$big" | env -u CANOPY_ROLE bash "$ROOT/hooks/guard-project-write.sh" >/dev/null 2>&1 ) || sigp=$((sigp+1)); done
[ "$sigp" -eq 0 ] && ok "drains stdin first (no SIGPIPE/141 over 20 runs)" || bad "SIGPIPE/141 on $sigp/20 runs — hook exits before draining stdin"

# --- pr-create guard: PRs must go through 'canopy pr open', not gh/gh-axi directly ---
prguard() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$1" '$c')" | CANOPY_ROLE=orchestrator bash "$ROOT/hooks/guard-pr-create.sh"; }
prguard 'gh pr create --title x --body y'      && bad "should block gh pr create"      || ok "blocks 'gh pr create'"
prguard 'gh-axi pr create --title x'           && bad "should block gh-axi pr create"  || ok "blocks 'gh-axi pr create'"
prguard 'canopy pr open t1'                    && ok "allows 'canopy pr open'"          || bad "should allow canopy pr open"
prguard 'gh pr view 5 && gh pr checks 5'       && ok "allows other gh pr subcommands"   || bad "should allow gh pr view/checks"
# inactive unless orchestrator role
printf '{"tool_name":"Bash","tool_input":{"command":"gh pr create"}}' | env -u CANOPY_ROLE bash "$ROOT/hooks/guard-pr-create.sh" && ok "pr-guard inactive without orchestrator role" || bad "pr-guard should be inactive without role"

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
# mark reviewed clean + edge-reviewed -> both review gates pass (fails later at push)
( cd "$R2" && "$CANOPY" task set "$ID" reviewed clean >/dev/null && "$CANOPY" task set "$ID" edge_reviewed clean >/dev/null )
ERR2="$(cd "$R2" && "$CANOPY" pr open "$ID" 2>&1 || true)"
echo "$ERR2" | grep -qiE 'not reviewed clean|no edge review recorded' && bad "review gates should pass once reviewed+edge clean" || ok "review gates pass once reviewed + edge clean"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
