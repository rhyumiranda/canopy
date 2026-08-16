# doctor.sh — `canopy doctor`: a read-only install/prereq health check. Sourced.
# shellcheck shell=bash
#
# Prints a status table and the exact fix command for every red line, then exits
# non-zero if any HARD prerequisite (git / jq / claude>=2.1) is missing or too old.
# Soft items (treehouse, gh-axi, PATH, wiring freshness, macOS watch) WARN but never
# fail the exit code — they don't block core orchestration, only convenience paths.
#
# Pure read-only: doctor MUST NOT write ~/.claude, ~/.local, or any .canopy state — it
# only inspects. It reuses is_brew_install (lib/common.sh) for the install method and
# _watch_tcc_risk (lib/watch.sh) for the macOS privacy hint — never duplicating that
# detection.

_DOCTOR_MIN_CLAUDE="2.1"

# --- report rows (human report -> stdout; exit code is the machine signal) ---
_doc_ok()   { printf '  \033[32mok\033[0m    %-10s %s\n' "$1" "$2"; }
_doc_warn() { printf '  \033[33mwarn\033[0m  %-10s %s\n' "$1" "$2"; }
_doc_bad()  { printf '  \033[31mFAIL\033[0m  %-10s %s\n' "$1" "$2"; }
_doc_info() { printf '  \033[36m--\033[0m    %-10s %s\n' "$1" "$2"; }
_doc_fix()  { printf '        fix: %s\n' "$1"; }

# _claude_ge_min <version> — true if major.minor >= _DOCTOR_MIN_CLAUDE (2.1).
_claude_ge_min() {
  local v="$1" major minor
  major="${v%%.*}"
  minor="${v#*.}"; minor="${minor%%.*}"
  case "$major" in ''|*[!0-9]*) return 1 ;; esac
  case "$minor" in ''|*[!0-9]*) minor=0 ;; esac
  [ "$major" -gt 2 ] && return 0
  [ "$major" -eq 2 ] && [ "$minor" -ge 1 ] && return 0
  return 1
}

# _doc_prereq <name> <hard:0|1> <fix-msg> — present? report; set hard_fail on a
# missing HARD prereq (hard_fail is canopy_doctor's local, seen via dynamic scope).
_doc_prereq() {
  local name="$1" hard="$2" fix="$3" path
  if command -v "$name" >/dev/null 2>&1; then
    path="$(command -v "$name")" || path=""
    _doc_ok "$name" "$path"
    return 0
  fi
  if [ "$hard" = 1 ]; then
    _doc_bad "$name" "missing (required)"; hard_fail=1
  else
    _doc_warn "$name" "missing (optional)"
  fi
  _doc_fix "$fix"
}

# canopy_doctor — inspect prereqs, PATH, wiring, install method, and the macOS watch
# hint; print fixes; exit non-zero iff a hard prereq is missing/too old.
canopy_doctor() {
  local hard_fail=0

  printf 'canopy doctor — v%s\n\n' "$CANOPY_VERSION"

  printf 'prerequisites\n'
  _doc_prereq git 1 "install git (e.g. brew install git)"
  _doc_prereq jq  1 "install jq (e.g. brew install jq)"

  # claude is a HARD prereq AND must be >= 2.1 — probe the version.
  if command -v claude >/dev/null 2>&1; then
    local cvraw cvnum
    cvraw="$(claude --version 2>/dev/null)" || cvraw=""
    cvnum="$(printf '%s' "$cvraw" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)" || cvnum=""
    if [ -z "$cvnum" ]; then
      _doc_warn claude "present, version unknown ($(command -v claude))"
    elif _claude_ge_min "$cvnum"; then
      _doc_ok claude "v$cvnum (>= $_DOCTOR_MIN_CLAUDE)"
    else
      _doc_bad claude "v$cvnum too old (need >= $_DOCTOR_MIN_CLAUDE)"; hard_fail=1
      _doc_fix "upgrade Claude Code to >= $_DOCTOR_MIN_CLAUDE — https://claude.com/claude-code"
    fi
  else
    _doc_bad claude "missing (required)"; hard_fail=1
    _doc_fix "install Claude Code >= $_DOCTOR_MIN_CLAUDE — https://claude.com/claude-code"
  fi

  _doc_prereq treehouse 0 "install treehouse (git worktree pool manager)"
  _doc_prereq gh-axi    0 "install gh-axi (GitHub CLI wrapper)"

  # --- install method + PATH + update path ---
  printf '\ninstall\n'
  local method updatecmd bindir prefix
  if is_brew_install; then
    method="Homebrew"
    updatecmd="brew upgrade canopy"
    prefix="$(brew --prefix 2>/dev/null)" || prefix=""
    bindir="$prefix/bin"
  else
    method="source clone"
    updatecmd="canopy upgrade"
    bindir="$HOME/.local/bin"
  fi
  _doc_info method "$method (root: ${CANOPY_ROOT:-unknown})"
  _doc_info update "$updatecmd"

  case ":$PATH:" in
    *":$bindir:"*) _doc_ok PATH "$bindir on PATH" ;;
    *) _doc_warn PATH "$bindir NOT on PATH"
       _doc_fix "export PATH=\"$bindir:\$PATH\"" ;;
  esac

  # --- Claude/Codex wiring freshness (marker vs CANOPY_VERSION) ---
  printf '\nwiring\n'
  local marker lv
  marker="$HOME/.claude/canopy/.linked-version"
  if [ -f "$marker" ]; then
    lv="$(cat "$marker" 2>/dev/null)" || lv=""
    if [ "$lv" = "$CANOPY_VERSION" ]; then
      _doc_ok defs "wired, current (v$lv)"
    else
      _doc_warn defs "stale (marker v${lv:-?} != v$CANOPY_VERSION)"
      _doc_fix "canopy setup --link"
    fi
  else
    _doc_warn defs "not wired"
    _doc_fix "canopy setup --link"
  fi

  # --- macOS watch hint: reuse _watch_tcc_risk (lib/watch.sh), don't duplicate ---
  if [ "$(uname -s)" = Darwin ] && command -v launchctl >/dev/null 2>&1 \
     && git rev-parse --git-dir >/dev/null 2>&1; then
    if ( _watch_tcc_risk ) 2>/dev/null; then
      _doc_warn watch "repo under a macOS privacy folder (~/Documents|Desktop|Downloads)"
      _doc_fix "grant Full Disk Access to /bin/bash, or move the repo — see 'canopy watch status'"
    else
      _doc_ok watch "no macOS privacy (TCC) risk for this location"
    fi
  fi

  printf '\n'
  if [ "$hard_fail" = 1 ]; then
    printf '\033[31mcanopy doctor: hard prerequisite(s) missing — fix the FAIL lines above.\033[0m\n'
    return 1
  fi
  printf '\033[32mcanopy doctor: all hard prerequisites present.\033[0m\n'
  return 0
}
