# checks.sh — deterministic quality checks (0 LLM tokens). Sourced, not executed.
# shellcheck shell=bash
#
# Config resolution (worktree-visible, so it works inside leased worktrees):
#   1. committed  canopy.json  -> .checks { test, lint, typecheck, build, ... }  (null/absent = skip)
#   2. else auto-detect from package.json scripts, tsconfig.json, Makefile
# Each check is "name<TAB>command"; commands run in the target dir.

_pkg_script() { jq -e --arg s "$1" '.scripts[$s] // empty' "$2" >/dev/null 2>&1; }

_checks_config() {
  local dir="${1:-.}"
  if [ -f "$dir/canopy.json" ] && jq -e '.checks' "$dir/canopy.json" >/dev/null 2>&1; then
    jq -r '.checks | to_entries[] | select(.value != null and .value != "") | "\(.key)\t\(.value)"' "$dir/canopy.json"
    return
  fi
  if [ -f "$dir/package.json" ]; then
    _pkg_script test "$dir/package.json"      && printf 'test\tnpm test --silent\n'
    _pkg_script lint "$dir/package.json"      && printf 'lint\tnpm run lint --silent\n'
    if _pkg_script typecheck "$dir/package.json"; then printf 'typecheck\tnpm run typecheck --silent\n'
    elif [ -f "$dir/tsconfig.json" ]; then printf 'typecheck\tnpx -y tsc --noEmit\n'; fi
    _pkg_script build "$dir/package.json"     && printf 'build\tnpm run build --silent\n'
  fi
  if [ -f "$dir/Makefile" ]; then
    grep -qE '^test:'  "$dir/Makefile" && printf 'test\tmake test\n'
    grep -qE '^lint:'  "$dir/Makefile" && printf 'lint\tmake lint\n'
    grep -qE '^build:' "$dir/Makefile" && printf 'build\tmake build\n'
  fi
}

# canopy checks show [dir]
canopy_checks_show() {
  need jq
  local dir="${1:-$(pwd)}" any=0 name cmd
  while IFS=$'\t' read -r name cmd; do
    [ -n "${name:-}" ] || continue; any=1
    printf '  %-10s %s\n' "$name" "$cmd" >&2
  done < <(_checks_config "$dir")
  [ "$any" = 1 ] || { warn "no checks detected in $dir"; return 0; }
}

# canopy checks run [dir]  -> non-zero if ANY check fails
canopy_checks_run() {
  need jq
  local dir="${1:-$(pwd)}" fail=0 ran=0 name cmd
  while IFS=$'\t' read -r name cmd; do
    [ -n "${name:-}" ] || continue; ran=1
    if ( cd "$dir" && eval "$cmd" ) >/dev/null 2>&1; then
      info "check ✓ $name"
    else
      warn "check ✗ $name  ($cmd)"; fail=1
    fi
  done < <(_checks_config "$dir")
  [ "$ran" = 1 ] || warn "no checks to run in $dir (nothing to verify)"
  return "$fail"
}
