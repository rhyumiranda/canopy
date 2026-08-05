# common.sh — shared helpers (logging, paths, guards). Sourced, not executed.
# shellcheck shell=bash

CANOPY_VERSION="0.7.1" # x-release-please-version
export CANOPY_VERSION

# --- logging (all to stderr so stdout stays machine-parseable) ---
_c_ts() { date -u +%FT%TZ; }
log()  { printf '%s\n' "$*" >&2; }
info() { printf '\033[36m[canopy]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m[canopy] warn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[canopy] error:\033[0m %s\n' "$*" >&2; exit 1; }

# --- dependency guard ---
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

# --- AXI-style structured output (experimental worker CLI) -------------------
# The Herdr-facing worker commands follow AXI ergonomics (kunchenguid/axi):
# compact TOON on stdout, explicit empty states, and fail-loud usage errors.
#
# TOON flat object: emit `key: value` lines to stdout (machine-parseable).
toon_obj() { while [ "$#" -ge 2 ]; do printf '%s: %s\n' "$1" "$2"; shift 2; done; }

# Contextual next-step hints (AXI §9). Single line -> `help: x`; many -> array.
toon_help() {
  [ "$#" -gt 0 ] || return 0
  if [ "$#" -eq 1 ]; then printf 'help: %s\n' "$1"; return 0; fi
  printf 'help[%s]:\n' "$#"
  local h; for h in "$@"; do printf '  %s\n' "$h"; done
}

# Usage error (AXI §6 "fail loud on unrecognized input"): the structured error
# and its valid-flags hint go to STDOUT so the calling agent can read them and
# self-correct in one turn; exit code 2 marks a usage error (distinct from the
# runtime error `die`, which stays on stderr with exit 1).
usage_error() {
  printf 'error: %s\n' "$1"
  [ -n "${2:-}" ] && printf 'help: %s\n' "$2"
  exit 2
}

# --- repo / .canopy paths ---
# The repo root is the MAIN worktree's toplevel — resolved even when cwd is a
# linked worktree, so `.canopy/` (which lives in the main tree) is found when a
# worker runs `canopy` inside its leased worktree. `git-common-dir` points at
# <main-root>/.git in both the main tree and any linked worktree.
repo_root() {
  local common
  common="$(git rev-parse --git-common-dir 2>/dev/null)" || die "not inside a git repository"
  common="$(cd "$common" 2>/dev/null && pwd)" || die "not inside a git repository"
  if [ "$(basename "$common")" = ".git" ]; then
    dirname "$common"
  else
    # exotic git dir (submodule, custom GIT_DIR) — fall back to the cwd's toplevel
    git rev-parse --show-toplevel 2>/dev/null || die "not inside a git repository"
  fi
}
canopy_dir()   { echo "$(repo_root)/.canopy"; }
state_file()   { echo "$(canopy_dir)/state.json"; }
brief_file()   { echo "$(canopy_dir)/brief.md"; }
tasks_dir()    { echo "$(canopy_dir)/tasks"; }
task_file()    { echo "$(tasks_dir)/$1.json"; }
events_dir()   { echo "$(canopy_dir)/events"; }
lifecycle_file() { echo "$(events_dir)/lifecycle.json"; }
herdr_watchers_dir() { echo "$(canopy_dir)/herdr-watchers"; }

require_canopy() {
  [ -f "$(state_file)" ] || die "no .canopy/ here — run 'canopy init' first"
}

# --- atomic write: write_atomic <path> < content-on-stdin ---
write_atomic() {
  local dest="$1" tmp
  tmp="$(mktemp "${dest}.XXXXXX")"
  cat > "$tmp"
  mv -f "$tmp" "$dest"
}

# --- json guard: jq_ok <file> -> non-zero if not valid json ---
jq_ok() { jq -e . "$1" >/dev/null 2>&1; }

# --- base branch: the branch worktrees are cut from, and PRs/reviews target ---
# A repo whose integration branch is NOT the default (e.g. `develop`, while
# `main` is stale) sets it once with `canopy base develop`. The configured
# `.base` in state.json wins; otherwise fall back to auto-detection
# (`_default_branch`, defined in review.sh — resolved at call time).
base_branch() {
  local wt="${1:-.}" b
  b="$(jq -r '.base // empty' "$(state_file)" 2>/dev/null)" || b=""
  [ -n "$b" ] && { printf '%s\n' "$b"; return 0; }
  _default_branch "$wt"
}
