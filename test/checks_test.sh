#!/usr/bin/env bash
# Deterministic checks runner. Run: bash test/checks_test.sh
set -uo pipefail
CANOPY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANOPY="$CANOPY_ROOT/bin/canopy"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

echo "== checks tests =="

# --- committed canopy.json override: one passing, one failing ---
D="$WORK/cfg"; mkdir -p "$D"
cat > "$D/canopy.json" <<'JSON'
{ "checks": { "test": "true", "lint": "false", "build": null } }
JSON
# show lists exactly the two non-null checks
SHOW="$("$CANOPY" checks show "$D" 2>&1)"
echo "$SHOW" | grep -q 'test' && ok "show lists test" || bad "show missing test"
echo "$SHOW" | grep -q 'lint' && ok "show lists lint" || bad "show missing lint"
echo "$SHOW" | grep -q 'build' && bad "null check should be skipped" || ok "null check skipped"
# run: lint (false) fails -> non-zero
if "$CANOPY" checks run "$D" >/dev/null 2>&1; then bad "run should fail when a check fails"; else ok "run fails when a check fails"; fi

# --- all-passing config -> zero ---
D2="$WORK/pass"; mkdir -p "$D2"
echo '{ "checks": { "test": "true", "lint": "true" } }' > "$D2/canopy.json"
if "$CANOPY" checks run "$D2" >/dev/null 2>&1; then ok "run passes when all green"; else bad "run should pass when all green"; fi

# --- auto-detect from package.json scripts ---
D3="$WORK/pkg"; mkdir -p "$D3"
cat > "$D3/package.json" <<'JSON'
{ "name":"x","scripts":{ "test":"exit 0", "lint":"exit 1" } }
JSON
SHOW3="$("$CANOPY" checks show "$D3" 2>&1)"
echo "$SHOW3" | grep -q 'test' && ok "auto-detect test from package.json" || bad "missed package.json test"
echo "$SHOW3" | grep -q 'lint' && ok "auto-detect lint from package.json" || bad "missed package.json lint"

# --- no config, nothing detected -> run is a no-op success ---
D4="$WORK/empty"; mkdir -p "$D4"
if "$CANOPY" checks run "$D4" >/dev/null 2>&1; then ok "empty repo: run is a no-op success"; else bad "empty repo should not fail"; fi

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
