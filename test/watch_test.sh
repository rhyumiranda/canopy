#!/usr/bin/env bash
# canopy watch hardening: status/ensure/install-plist logic + Layer-1 recover
# reconcile. Avoids touching the real launchd (never calls ensure with a plist
# present). Sandboxed via $HOME. Run: bash test/watch_test.sh
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

echo "== canopy watch hardening =="
H="$WORK/home"; mkdir -p "$H/Library/LaunchAgents"
R="$(new_repo)"; cd "$R"; "$CANOPY" init >/dev/null 2>&1

# --- status: not installed yet ---
OUT="$(HOME="$H" "$CANOPY" watch status 2>&1)"
printf '%s' "$OUT" | grep -qi 'plist: NOT installed' && ok "status reports not-installed" || bad "status should say not installed: $OUT"

# --- ensure with no plist: safe, never touches launchd ---
HOME="$H" "$CANOPY" watch ensure >/dev/null 2>&1 && ok "ensure exits 0 with no plist" || bad "ensure should not fail"
ls "$H/Library/LaunchAgents/"*.plist >/dev/null 2>&1 && bad "ensure must not create a plist" || ok "ensure created no plist (no side effects)"

# --- install writes the plist (no --load, so no launchctl) ---
HOME="$H" "$CANOPY" watch install >/dev/null 2>&1
ls "$H/Library/LaunchAgents/"com.canopy.watch.*.plist >/dev/null 2>&1 && ok "install wrote the plist" || bad "install did not write a plist"
# plist carries the notify env + points at the stable snapshot path pattern
PL="$(ls "$H/Library/LaunchAgents/"com.canopy.watch.*.plist 2>/dev/null | head -1)"
grep -q 'CANOPY_NOTIFY' "$PL" && ok "plist sets CANOPY_NOTIFY (merges ping)" || bad "plist missing CANOPY_NOTIFY"

# --- status: now installed ---
OUT="$(HOME="$H" "$CANOPY" watch status 2>&1)"
printf '%s' "$OUT" | grep -qi 'plist: installed' && ok "status reports installed" || bad "status should say installed: $OUT"

# --- status detects a TCC block from the log ---
printf 'fatal: Unable to read current working directory: Operation not permitted\n' > "$R/.canopy/watch.log"
OUT="$(HOME="$H" "$CANOPY" watch status 2>&1)"
printf '%s' "$OUT" | grep -qi 'TCC' && ok "status flags the TCC/Full-Disk-Access block" || bad "status should flag TCC: $OUT"

# --- Layer 1: 'canopy recover' reconciles a merged PR in-session (stub gh-axi) ---
STUB="$WORK/bin"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\necho "state:  MERGED"\n' > "$STUB/gh-axi"; chmod +x "$STUB/gh-axi"
R2="$(new_repo)"; cd "$R2"; "$CANOPY" init >/dev/null 2>&1
ID="$("$CANOPY" task add "shipped thing" 2>/dev/null)"
"$CANOPY" task set "$ID" pr 1 >/dev/null
"$CANOPY" task set "$ID" worktree "$R2" >/dev/null
"$CANOPY" task status "$ID" pr-open >/dev/null
PATH="$STUB:$PATH" HOME="$H" "$CANOPY" recover >/dev/null 2>&1 || true
ST="$(jq -r '.tasks[0].status' "$R2/.canopy/state.json")"
[ "$ST" = "done" ] && ok "recover reconciled the merged PR -> done (Layer 1 redundancy)" || bad "task should be done after recover, got: $ST"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
