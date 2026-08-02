# common.sh — shared helpers (logging, paths, guards). Sourced, not executed.
# shellcheck shell=bash

CANOPY_VERSION="0.1.0-dev"
export CANOPY_VERSION

# --- logging (all to stderr so stdout stays machine-parseable) ---
_c_ts() { date -u +%FT%TZ; }
log()  { printf '%s\n' "$*" >&2; }
info() { printf '\033[36m[canopy]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m[canopy] warn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[canopy] error:\033[0m %s\n' "$*" >&2; exit 1; }

# --- dependency guard ---
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

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
