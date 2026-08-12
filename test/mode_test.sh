#!/usr/bin/env bash
# global mode resolution: `canopy mode --global` reads the orchestrator HOME
# repo's mode regardless of cwd, and per-project .mode is superseded (not read,
# not mutated). Bare `canopy mode` is unchanged. Deterministic (no LLM/treehouse).
# Run: bash test/mode_test.sh
set -uo pipefail
CANOPY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANOPY="$CANOPY_ROOT/bin/canopy"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=[%s] got=[%s]\n' "$3" "$2"; }; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

mkproj() { # mkproj <parent> <name> — a throwaway git repo under <parent>/projects/
  local d="$1/projects/$2"; mkdir -p "$d"; ( cd "$d" && git init -q \
    && git config user.email t@t && git config user.name t \
    && echo hi > f && git add -A && git commit -qm init && git branch -M main ) ; }

echo "== global mode =="

# HOME repo (the orchestrator home): its projects/ holds routed projects.
R="$WORK/repo"; mkdir -p "$R"; cd "$R"
git init -q; git config user.email t@t; git config user.name t
echo hi > f; git add -A; git commit -qm init; git branch -M main
( cd "$R" && "$CANOPY" init >/dev/null 2>&1 )

# A routed project WITH its own board, deliberately set to a DIFFERENT mode.
mkproj "$R" alpha
( cd "$R/projects/alpha" && "$CANOPY" init >/dev/null 2>&1 \
  && "$CANOPY" mode yolo >/dev/null 2>&1 )

# --- bare mode: single-repo behavior unchanged (reads THIS repo's .mode) ------
eq "bare mode in home defaults to guided" "$( ( cd "$R" && "$CANOPY" mode ) 2>/dev/null)" "guided"
eq "bare mode in project reads its own .mode (yolo)" "$( ( cd "$R/projects/alpha" && "$CANOPY" mode ) 2>/dev/null)" "yolo"

# --- --global from HOME reads the home mode -----------------------------------
eq "global from home = home mode (guided)" "$( ( cd "$R" && "$CANOPY" mode --global ) 2>/dev/null)" "guided"

# --- --global from a routed project STILL reads the home mode -----------------
# The project's own .mode is yolo, but --global must resolve the home (guided).
eq "global from project supersedes project .mode" "$( ( cd "$R/projects/alpha" && "$CANOPY" mode --global ) 2>/dev/null)" "guided"

# --- flipping the HOME mode changes --global everywhere -----------------------
( cd "$R" && "$CANOPY" mode yolo >/dev/null 2>&1 )
eq "global follows a home flip, from home"    "$( ( cd "$R" && "$CANOPY" mode --global ) 2>/dev/null)" "yolo"
eq "global follows a home flip, from project" "$( ( cd "$R/projects/alpha" && "$CANOPY" mode --global ) 2>/dev/null)" "yolo"

# --- --global did NOT mutate the project's own stored .mode -------------------
eq "project .mode is left untouched by --global reads" \
  "$(jq -r '.mode' "$R/projects/alpha/.canopy/state.json")" "yolo"

# --- --global is read-only: passing a mode value fails loudly -----------------
if err="$( ( cd "$R" && "$CANOPY" mode --global yolo ) 2>&1 >/dev/null)"; then
  bad "mode --global with a value should fail"
else
  case "$err" in *read-only*) ok "mode --global rejects a set value" ;; *) bad "wrong error: $err" ;; esac
fi

# --- single-repo (no projects/ parent): global falls back to own mode ---------
S="$WORK/solo"; mkdir -p "$S"; ( cd "$S" && git init -q \
  && git config user.email t@t && git config user.name t \
  && echo hi > f && git add -A && git commit -qm init && git branch -M main \
  && "$CANOPY" init >/dev/null 2>&1 )
eq "solo repo: global == its own mode" "$( ( cd "$S" && "$CANOPY" mode --global ) 2>/dev/null)" "guided"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
