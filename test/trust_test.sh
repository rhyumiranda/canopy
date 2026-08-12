#!/usr/bin/env bash
# _claude_trust_path: idempotent pre-marking of a leased worktree as trusted in
# ~/.claude.json, without clobbering unrelated entries. Run: bash test/trust_test.sh
set -uo pipefail
CANOPY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

# shellcheck source=../lib/common.sh
. "$CANOPY_ROOT/lib/common.sh"

echo "== claude trust pre-mark =="

CFG="$WORK/claude.json"
export CANOPY_CLAUDE_CONFIG="$CFG"
NEW="/Users/x/.treehouse/leased/wt"

# Seed a config with an existing project + a sibling top-level key to protect.
cat > "$CFG" <<EOF
{
  "anonymousId": "keep-me",
  "projects": {
    "/existing/repo": { "hasTrustDialogAccepted": true, "allowedTools": ["Read"] }
  }
}
EOF

# 1) marks a previously-unknown path trusted
_claude_trust_path "$NEW"
[ "$(jq -r --arg p "$NEW" '.projects[$p].hasTrustDialogAccepted' "$CFG")" = true ] \
  && ok "marks new worktree path trusted" || bad "new path not marked trusted"

# 2) preserves unrelated top-level keys and the pre-existing project entry
[ "$(jq -r '.anonymousId' "$CFG")" = keep-me ] && ok "preserves unrelated top-level keys" || bad "clobbered top-level key"
[ "$(jq -r '.projects["/existing/repo"].hasTrustDialogAccepted' "$CFG")" = true ] \
  && ok "preserves existing project trust" || bad "clobbered existing project trust"
[ "$(jq -r '.projects["/existing/repo"].allowedTools[0]' "$CFG")" = Read ] \
  && ok "preserves existing project settings" || bad "clobbered existing project settings"

# 3) idempotent: a second call leaves the file byte-identical
BEFORE="$(md5 -q "$CFG" 2>/dev/null || md5sum "$CFG" | cut -d' ' -f1)"
_claude_trust_path "$NEW"
AFTER="$(md5 -q "$CFG" 2>/dev/null || md5sum "$CFG" | cut -d' ' -f1)"
[ "$BEFORE" = "$AFTER" ] && ok "idempotent: no rewrite when already trusted" || bad "rewrote file when already trusted"

# 4) creating trust for a path adds the projects map if it is missing entirely
echo '{"anonymousId":"solo"}' > "$CFG"
_claude_trust_path "$NEW"
[ "$(jq -r --arg p "$NEW" '.projects[$p].hasTrustDialogAccepted' "$CFG")" = true ] \
  && ok "creates projects map when absent" || bad "did not create projects map"
[ "$(jq -r '.anonymousId' "$CFG")" = solo ] && ok "keeps other keys when adding projects map" || bad "lost keys creating projects map"

# 5) missing config: no-op, no error, no file created
rm -f "$CFG"
_claude_trust_path "$NEW" && ok "missing config is a silent no-op" || bad "errored on missing config"
[ ! -f "$CFG" ] && ok "does not create config from nothing" || bad "created a config from scratch"

# 6) corrupt config: never clobbered
printf '%s' 'not json {' > "$CFG"
_claude_trust_path "$NEW" 2>/dev/null
[ "$(cat "$CFG")" = 'not json {' ] && ok "leaves a corrupt config untouched" || bad "clobbered corrupt config"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
