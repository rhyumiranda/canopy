#!/usr/bin/env bash
# aggregate enumeration across registered projects: status/recover/watch --all.
# Deterministic (no LLM, no treehouse). Run: bash test/aggregate_test.sh
#
# HOME is redirected to a throwaway dir so a per-repo watcher's launchd plist
# (written under $HOME/Library/LaunchAgents) can never touch the real one.
set -uo pipefail
CANOPY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANOPY="$CANOPY_ROOT/bin/canopy"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1"; printf '       missing [%s] in:\n%s\n' "$3" "$2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1"; printf '       unexpected [%s] in:\n%s\n' "$3" "$2" ;; *) ok "$1" ;; esac; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

mkproj() { # mkproj <parent> <name> — a throwaway git repo under <parent>/projects/
  local d="$1/projects/$2"; mkdir -p "$d"; ( cd "$d" && git init -q \
    && git config user.email t@t && git config user.name t \
    && echo hi > f && git add -A && git commit -qm init && git branch -M main ) ; }

echo "== aggregate --all across projects =="

# The canopy repo whose projects/ the --all commands scan is the MAIN worktree root.
R="$WORK/repo"; mkdir -p "$R"; cd "$R"
git init -q; git config user.email t@t; git config user.name t
echo hi > f; git add -A; git commit -qm init; git branch -M main

# Two throwaway projects, each with its own board.
#   alpha: one planning task (no PR)     beta: one pr-open task (PR #42)
mkproj "$R" alpha
mkproj "$R" beta
( cd "$R/projects/alpha" && "$CANOPY" init >/dev/null 2>&1 \
  && "$CANOPY" task add "do alpha thing" >/dev/null 2>&1 )
( cd "$R/projects/beta" && "$CANOPY" init >/dev/null 2>&1 \
  && bid="$("$CANOPY" task add "do beta thing" 2>/dev/null)" \
  && "$CANOPY" task set "$bid" pr 42 >/dev/null 2>&1 \
  && "$CANOPY" task status "$bid" pr-open >/dev/null 2>&1 )

# --- status --all: each project under its own header, ids shown <name>:tN ------
all="$( ( cd "$R" && "$CANOPY" status --all ) 2>&1 )"
has "status --all shows the alpha project header" "$all" "project: alpha"
has "status --all shows the beta project header"  "$all" "project: beta"
has "status --all namespaces alpha ids as alpha:t1" "$all" "alpha:t1"
has "status --all namespaces beta ids as beta:t1"   "$all" "beta:t1"
has "status --all keeps per-project status+PR"      "$all" "pr-open"

# --- bare status: current repo only, ids NOT namespaced ----------------------
bare="$( ( cd "$R/projects/alpha" && "$CANOPY" status ) 2>&1 )"
has   "bare status shows this repo's own task id (t1)" "$bare" "  t1	planning"
hasnt "bare status does NOT namespace ids"             "$bare" "alpha:t1"
hasnt "bare status does NOT leak the other project"    "$bare" "beta"

# --- recover --all: iterates every project without error ---------------------
if rec="$( ( cd "$R" && "$CANOPY" recover --all ) 2>&1 )"; then
  ok "recover --all exits 0 over multiple projects"
else
  bad "recover --all errored: $rec"
fi
has "recover --all visits the alpha project" "$rec" "project: alpha"
has "recover --all visits the beta project"  "$rec" "project: beta"

# --- watch ensure --all: only targets projects with pr-open tasks ------------
we="$( ( cd "$R" && "$CANOPY" watch ensure --all ) 2>&1 )"
has   "watch ensure --all arms the pr-open project (beta)" "$we" "project beta has 1 pr-open"
hasnt "watch ensure --all skips the project with no pr-open (alpha)" "$we" "project alpha has"

# --- regression: bare status byte-for-byte matches a hand-rolled render ------
# The single-repo board format must be untouched by the refactor.
exp="$(cd "$R/projects/alpha" && jq -r '.tasks[] | "  \(.id)\t\(.status)\t\(.title)"' .canopy/state.json)"
got="$( ( cd "$R/projects/alpha" && "$CANOPY" status ) 2>&1 | grep -E '^  t[0-9]' )"
[ "$got" = "$exp" ] && ok "bare status task line is byte-for-byte unchanged" \
  || { bad "bare status task line changed"; printf '       want=[%s] got=[%s]\n' "$exp" "$got"; }

echo
echo "== status renders ONE board per reader (no double-render) =="

# --- piped status (stdout NOT a tty): exactly one TOON board, no dup ----------
# Captured via $(...), so stdout is a pipe -> the agent/TOON path. It must emit a
# single machine-parseable board on stdout with NO colored `[canopy] mode:`
# duplicate leaking in (the old bug rendered the board on BOTH stdout and stderr).
pipeout="$( ( cd "$R/projects/alpha" && "$CANOPY" status ) 2>/dev/null )"
has   "piped status emits the TOON mode line"   "$pipeout" "mode: "
has   "piped status emits the TOON task row"    "$pipeout" "  t1	planning"
has   "piped status emits the TOON help hint"   "$pipeout" "help: "
hasnt "piped status has no colored [canopy] duplicate on stdout" "$pipeout" "[canopy]"
modecount="$(printf '%s\n' "$pipeout" | grep -c '^mode: ')"
[ "$modecount" -eq 1 ] \
  && ok "piped status renders exactly one board (one mode line)" \
  || { bad "piped status rendered $modecount boards (expected 1)"; printf '%s\n' "$pipeout"; }

# --- interactive status (TTY stdout via pty): one colored board, no TOON dup ---
# Best-effort — a pty read via `script` is finicky on macOS bash 3.2, so we assert
# only when `script` gives us usable output. At a real terminal stdout is a tty ->
# the colored human path: exactly one `[canopy] mode:` board, and NONE of the TOON
# extras (no `help:` line, no plain `tasks[...]{` header) that would signal a
# second board printed to the same screen.
if command -v script >/dev/null 2>&1; then
  esc="$(printf '\033')"
  tty_out="$(script -q /dev/null bash -c "cd '$R/projects/alpha' && '$CANOPY' status" 2>&1 \
             | tr -d '\r' | sed "s/${esc}\[[0-9;]*m//g")"
  if printf '%s' "$tty_out" | grep -q '\[canopy\] mode:'; then
    m="$(printf '%s\n' "$tty_out" | grep -c '\[canopy\] mode:')"
    [ "$m" -eq 1 ] && ok "interactive status prints the mode line exactly once" \
      || { bad "interactive status printed the mode line $m times (double-render)"; printf '%s\n' "$tty_out"; }
    hasnt "interactive status shows no TOON help line (no second board)"   "$tty_out" "help: "
    hasnt "interactive status shows no TOON tasks header (no second board)" "$tty_out" "tasks[1]{"
  else
    ok "interactive pty read unavailable — skipped (piped path already asserted)"
  fi
else
  ok "no 'script' pty helper — interactive check skipped (piped path asserted)"
fi

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
