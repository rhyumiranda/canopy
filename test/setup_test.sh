#!/usr/bin/env bash
# canopy setup: a real run installs + is labeled correctly; --dry-run only previews.
# Sandboxed via $HOME (setup.sh respects $HOME). Run: bash test/setup_test.sh
set -uo pipefail
CANOPY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANOPY="$CANOPY_ROOT/bin/canopy"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

echo "== canopy setup =="

# --- real run (sandboxed HOME) ---
H="$WORK/home"; mkdir -p "$H"
OUT="$(HOME="$H" "$CANOPY" setup 2>&1)"
case "$OUT" in
  *"(dry-run)"*) bad "real setup must NOT be labeled (dry-run)" ;;
  *"done"*)      ok "real setup labeled plainly (not dry-run)" ;;
  *)             bad "real setup produced no 'done' line" ;;
esac
[ -f "$H/.claude/agents/worker.md" ]   && ok "worker agent installed"   || bad "worker agent not installed"
[ -f "$H/.claude/commands/yolo.md" ]   && ok "yolo command installed"   || bad "yolo command not installed"
[ -L "$H/.local/bin/canopy" ]          && ok "canopy symlinked on PATH" || bad "canopy not symlinked"

# --- dry-run (fresh sandbox) previews without touching disk ---
H2="$WORK/home2"; mkdir -p "$H2"
OUT2="$(HOME="$H2" "$CANOPY" setup --dry-run 2>&1)"
case "$OUT2" in
  *"(dry-run)"*) ok "dry-run is labeled (dry-run)" ;;
  *)             bad "dry-run not labeled" ;;
esac
[ -e "$H2/.claude/agents/worker.md" ] && bad "dry-run must not copy files" || ok "dry-run copied nothing"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
