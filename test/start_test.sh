#!/usr/bin/env bash
# canopy start (dry-run). Run: bash test/start_test.sh
set -uo pipefail
CANOPY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANOPY="$CANOPY_ROOT/bin/canopy"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

echo "== canopy start =="
R="$WORK/repo"; mkdir -p "$R"; ( cd "$R"; git init -q; git config user.email t@t; git config user.name t; echo x>f; git add -A; git commit -qm i )
( cd "$R" && "$CANOPY" init >/dev/null 2>&1 )

OUT="$(cd "$R" && "$CANOPY" start --dry-run 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "start --dry-run succeeds in a canopy repo" || bad "start dry-run failed"
echo "$OUT" | grep -qi 'orchestrator playbook' && ok "start loads the orchestrator playbook" || bad "no playbook in dry-run"
echo "$OUT" | grep -q 'CANOPY_ROLE=orchestrator' && ok "start sets CANOPY_ROLE=orchestrator" || bad "no role env"

OUT2="$(cd "$R" && "$CANOPY" start --codex --dry-run 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "start --codex --dry-run succeeds" || bad "start codex dry-run failed"
echo "$OUT2" | grep -q 'codex' && ok "start --codex targets codex" || bad "codex dry-run missing codex"
echo "$OUT2" | grep -q -- '--dangerously-bypass-approvals-and-sandbox' && ok "start --codex includes Codex bypass flag" || bad "codex dry-run missing bypass flag"
echo "$OUT2" | grep -q -- '-a never' && bad "start --codex should not combine -a never with bypass" || ok "start --codex omits conflicting approval flag"

# real launch keeps the same default (with a fake Codex binary)
FAKE_BIN="$WORK/fake-bin"; mkdir -p "$FAKE_BIN"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\\n" "$@" > "$CANOPY_CAPTURE"' > "$FAKE_BIN/codex"
chmod +x "$FAKE_BIN/codex"
CAPTURE="$WORK/codex-args"
( cd "$R" && PATH="$FAKE_BIN:$PATH" CANOPY_CAPTURE="$CAPTURE" "$CANOPY" start --codex >/dev/null 2>&1 )
[ "$(grep -cx -- '--dangerously-bypass-approvals-and-sandbox' "$CAPTURE")" = 1 ] \
  && ok "real codex launch has one bypass flag" \
  || bad "real codex launch bypass flag count wrong"
grep -qx -- '-a' "$CAPTURE" \
  && bad "real codex launch should not pass approval flag" \
  || ok "real codex launch omits conflicting approval flag"

# refuses outside a canopy repo
D="$WORK/plain"; mkdir -p "$D"; ( cd "$D"; git init -q )
if ( cd "$D" && "$CANOPY" start --dry-run >/dev/null 2>&1 ); then bad "start should refuse outside canopy"; else ok "start refuses outside a canopy repo"; fi

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
