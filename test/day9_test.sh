#!/usr/bin/env bash
# Day 9: scribe -> AGENTS.md, parallel leases, canopy setup (fake HOME).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANOPY="$ROOT/bin/canopy"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

echo "== day 9: scribe + parallel + setup =="

# --- scribe -> AGENTS.md ---
R="$WORK/repo"; mkdir -p "$R"; ( cd "$R"; git init -q; git config user.email t@t; git config user.name t; echo x>f; git add -A; git commit -qm i )
( cd "$R" && "$CANOPY" init >/dev/null 2>&1 )
( cd "$R" && "$CANOPY" scribe add "Run migrations via prisma migrate deploy, never dev." >/dev/null )
[ -f "$R/AGENTS.md" ] && ok "scribe creates AGENTS.md" || bad "no AGENTS.md"
grep -q 'prisma migrate deploy' "$R/AGENTS.md" && ok "scribe recorded the fact" || bad "fact not recorded"
# AGENTS.md must be committable (NOT gitignored)
( cd "$R" && git check-ignore AGENTS.md >/dev/null 2>&1 ) && bad "AGENTS.md must not be gitignored" || ok "AGENTS.md is committable"
# dedup
( cd "$R" && "$CANOPY" scribe add "Run migrations via prisma migrate deploy, never dev." >/dev/null )
eq_count="$(grep -c 'prisma migrate deploy' "$R/AGENTS.md")"
[ "$eq_count" = "1" ] && ok "scribe dedups identical facts" || bad "scribe duplicated ($eq_count)"

# --- parallel leases: 2 tasks -> 2 distinct treehouse worktrees ---
if command -v treehouse >/dev/null; then
  R2="$WORK/repo2"; mkdir -p "$R2"; ( cd "$R2"; git init -q; git config user.email t@t; git config user.name t; echo x>f; git add -A; git commit -qm i; git branch -M main; printf 'max_trees=8\nroot="./"\n' > treehouse.toml; git add -A; git commit -qm th )
  ( cd "$R2" && "$CANOPY" init >/dev/null 2>&1 )
  IDA="$(cd "$R2" && "$CANOPY" task add "task A" 2>/dev/null)"
  IDB="$(cd "$R2" && "$CANOPY" task add "task B" 2>/dev/null)"
  PA="$(cd "$R2" && "$CANOPY" worktree lease "$IDA" 2>/dev/null)"
  PB="$(cd "$R2" && "$CANOPY" worktree lease "$IDB" 2>/dev/null)"
  [ -n "$PA" ] && [ -n "$PB" ] && [ "$PA" != "$PB" ] && ok "parallel: 2 tasks -> 2 distinct worktrees" || bad "parallel leases collided: A=$PA B=$PB"
  ( cd "$R2" && "$CANOPY" worktree return "$IDA" >/dev/null 2>&1; "$CANOPY" worktree return "$IDB" >/dev/null 2>&1 ) || true
else
  ok "SKIP parallel leases (treehouse not installed)"
fi

# --- canopy setup against a FAKE HOME (real ~/.claude untouched) ---
S="$WORK/setup-src"; git clone -q "$ROOT" "$S"; S="$(cd "$S" && pwd -P)"
tar -C "$ROOT" --exclude .git -cf - . | tar -C "$S" -xf -
git -C "$S" config user.email t@t; git -C "$S" config user.name t
git -C "$S" add -A
if ! git -C "$S" diff --cached --quiet; then
  git -C "$S" commit -qm "overlay current tree"
fi
git -C "$S" checkout -q -B main
ORIGIN="$WORK/setup-origin.git"; git clone -q --bare "$S" "$ORIGIN"
git -C "$S" remote set-url origin "$ORIGIN"
git -C "$S" push -q -u origin main 2>/dev/null
CANOPY_SETUP="$S/bin/canopy"

FAKE="$WORK/home"; mkdir -p "$FAKE"
HOME="$FAKE" CANOPY_CHANNEL_UPSTREAM="$ORIGIN" "$CANOPY_SETUP" setup >/dev/null 2>&1
[ -f "$FAKE/.claude/agents/orchestrator.md" ] && ok "setup copies agents" || bad "setup missing agents"
[ -f "$FAKE/.claude/commands/yolo.md" ] && ok "setup copies commands" || bad "setup missing commands"
[ -f "$FAKE/.claude/canopy/hooks/session-start-digest.sh" ] && ok "setup copies hooks" || bad "setup missing hooks"
[ -f "$FAKE/.codex/canopy/agents/orchestrator.md" ] && ok "setup packages codex agents" || bad "setup missing codex agents"
[ -L "$FAKE/.local/bin/canopy" ] && ok "setup symlinks canopy onto PATH" || bad "setup missing canopy symlink"
HOME="$FAKE" jq -e '.hooks.SessionStart' "$FAKE/.claude/settings.json" >/dev/null 2>&1 && ok "setup writes hooks to settings.json" || bad "setup settings missing hooks"
# setup must NOT clobber an existing settings.json
echo '{"model":"opus","hooks":{"Stop":[]}}' > "$FAKE/.claude/settings.json"
HOME="$FAKE" CANOPY_CHANNEL_UPSTREAM="$ORIGIN" "$CANOPY_SETUP" setup >/dev/null 2>&1
HOME="$FAKE" jq -e '.model=="opus"' "$FAKE/.claude/settings.json" >/dev/null 2>&1 && ok "setup preserves existing settings.json" || bad "setup clobbered settings"
[ -f "$FAKE/.claude/canopy/settings-hooks.json" ] && ok "setup drops snippet for manual merge when settings exist" || bad "setup missing snippet"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
