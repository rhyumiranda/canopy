#!/usr/bin/env bash
# Run all Canopy test suites. Run: bash test/all.sh
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for f in "$DIR"/run.sh "$DIR"/*_test.sh; do
  [ -f "$f" ] || continue
  printf '\n\033[1m### %s ###\033[0m\n' "$(basename "$f")"
  bash "$f" || rc=1
done
printf '\n\033[1m=== overall: %s ===\033[0m\n' "$([ $rc -eq 0 ] && echo PASS || echo FAIL)"
exit $rc
