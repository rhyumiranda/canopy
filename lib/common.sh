# common.sh — shared helpers (logging, paths, guards). Sourced, not executed.
# shellcheck shell=bash

CANOPY_VERSION="0.16.0" # x-release-please-version
export CANOPY_VERSION

# --- logging (all to stderr so stdout stays machine-parseable) ---
_c_ts() { date -u +%FT%TZ; }
log()  { printf '%s\n' "$*" >&2; }
info() { printf '\033[36m[canopy]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m[canopy] warn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[canopy] error:\033[0m %s\n' "$*" >&2; exit 1; }

# --- dependency guard ---
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

# --- install-method detection (path-based, no marker file) ------------------
# is_brew_install — true (0) if the running canopy lives under Homebrew's Cellar.
# Consumed by `canopy upgrade` (brew-managed → instruct `brew upgrade`, don't die on
# the missing .source checkout), `canopy setup --unlink`, and `canopy doctor`.
# Path-based on purpose (survives brew relocations / Intel vs Apple-Silicon prefix
# differences): compare the resolved install root (CANOPY_ROOT, exported by
# bin/canopy after following its symlink chain) against `$(brew --prefix)/Cellar`.
# Offline/brew-absent safe — no `brew` on PATH → not a brew install.
is_brew_install() {
  command -v brew >/dev/null 2>&1 || return 1
  local prefix root
  prefix="$(brew --prefix 2>/dev/null)" || prefix=""
  [ -n "$prefix" ] || return 1
  root="${CANOPY_ROOT:-}"
  [ -n "$root" ] || return 1
  case "$root" in
    "$prefix"/Cellar/*|"$prefix"/Cellar) return 0 ;;
    *) return 1 ;;
  esac
}

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

require_canopy() {
  [ -f "$(state_file)" ] || die "no .canopy/ here — run 'canopy init' first"
}

# --- worker role guard ------------------------------------------------------
# A leased worker worktree shares the MAIN repo's git-common-dir, so repo_root()
# (hence canopy_dir/state_file/task_file) resolves to the LIVE orchestrator
# .canopy tree even when the worker runs `canopy` from inside its own worktree.
# If a worker runs a state-mutating orchestrator command — because its task is
# ABOUT canopy, or a stray verify/test step shells out to `canopy` — it clobbers
# the orchestrator's own board and Herdr identity. Observed: a worker nulled its
# task's herdr_pane_id/herdr_tab_id/worker_session, so the orchestrator lost the
# worker, got no terminal event, and silently stalled. Workers are launched with
# CANOPY_ROLE=worker (see lib/worker.sh); under that role this refuses the
# orchestrator-owned commands while still allowing a worker's own
# read/verify/checkpoint commands.
#
# _worker_cmd_allowed <cmd> <sub>  -> 0 if a worker may run it, 1 otherwise.
# Worker-safe = reads + verify + its own progress notes. `task checkpoint`/`show`
# touch only the worker's own detail file (checkpoint note + log), never the
# board or Herdr identity, so the orchestrator's tracking stays intact and
# checkpoint-based resume keeps working.
_worker_cmd_allowed() {
  case "$1" in
    checks|status|events|scribe|version|-v|--version|help|-h|--help|"") return 0 ;;
    # oracle/plan-gate are read-only advisory consults (they launch a read-only
    # claude and mutate no .canopy state) — a detached worker must be able to
    # reach a consultant mid-task, so allow them under CANOPY_ROLE=worker.
    oracle|plan-gate) return 0 ;;
    task) case "$2" in checkpoint|show) return 0 ;; *) return 1 ;; esac ;;
    *) return 1 ;;
  esac
}

# canopy_role_guard <cmd> <sub> — die on an orchestrator-only command under a
# worker role. No-op for the orchestrator (or a plain shell) so existing use is
# unaffected. Called once from bin/canopy before dispatch.
canopy_role_guard() {
  [ "${CANOPY_ROLE:-}" = worker ] || return 0
  local cmd="${1:-}" sub="${2:-}"
  _worker_cmd_allowed "$cmd" "$sub" && return 0
  die "canopy '${cmd}${sub:+ $sub}' is orchestrator-only and refused under CANOPY_ROLE=worker: a worker shares the orchestrator's .canopy state via git-common-dir and must not mutate its board or tasks. A worker may run: checks, task checkpoint, task show, status, events, scribe, version, oracle, plan-gate."
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

# --- Claude Code folder trust -------------------------------------------------
# Claude persists per-folder trust in ~/.claude.json under
# .projects["<abs path>"].hasTrustDialogAccepted (true = trusted). A leased
# worktree lives outside the usual trusted pool (e.g. ~/.treehouse/...), so it
# has no entry — and `claude` stalls on the interactive "Do you trust this
# folder?" dialog at launch. --dangerously-skip-permissions only bypasses *tool*
# permission prompts, NOT the trust gate, so an untrusted worktree silently
# wedges a headless/detached worker until it times out. Pre-marking the path we
# created ourselves as trusted removes that stall. Idempotent; preserves the
# rest of the (large) config exactly via a jq rewrite + atomic replace.
_claude_config_file() { printf '%s\n' "${CANOPY_CLAUDE_CONFIG:-$HOME/.claude.json}"; }

# _claude_trust_path <abs-worktree-path> -> best-effort; never fails a launch.
_claude_trust_path() {
  local path="${1:?path}" cfg tmp
  command -v jq >/dev/null 2>&1 || return 0
  cfg="$(_claude_config_file)"
  # No config yet: Claude creates it on first run and treats a fresh install as
  # trusted, so there is nothing to pre-mark.
  [ -f "$cfg" ] || return 0
  # Corrupt/empty config: never risk clobbering a file we cannot parse.
  jq -e . "$cfg" >/dev/null 2>&1 || { warn "trust pre-mark skipped: $cfg is not valid JSON"; return 0; }
  # Already trusted -> leave the file untouched (idempotent, zero churn).
  [ "$(jq -r --arg p "$path" '.projects[$p].hasTrustDialogAccepted // false' "$cfg" 2>/dev/null)" = true ] && return 0
  tmp="$(mktemp "${cfg}.XXXXXX")" || return 0
  if jq --arg p "$path" '
        .projects //= {} |
        .projects[$p] = ((.projects[$p] // {}) + {hasTrustDialogAccepted: true})
      ' "$cfg" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv -f "$tmp" "$cfg"
  else
    rm -f "$tmp"
    warn "could not pre-mark $path as trusted in $cfg"
  fi
}

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
