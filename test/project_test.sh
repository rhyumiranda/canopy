#!/usr/bin/env bash
# project registry (read layer): ls + name->path resolution over projects/.
# Deterministic (no LLM, no treehouse). Run: bash test/project_test.sh
set -uo pipefail
CANOPY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANOPY="$CANOPY_ROOT/bin/canopy"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=[%s] got=[%s]\n' "$3" "$2"; }; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

mkproj() { # mkproj <parent> <name> — a throwaway git repo under <parent>/projects/
  local d="$1/projects/$2"; mkdir -p "$d"; ( cd "$d" && git init -q \
    && git config user.email t@t && git config user.name t \
    && echo hi > f && git add -A && git commit -qm init ) ; }

echo "== project registry =="

# The canopy repo whose projects/ the commands scan is the MAIN worktree root.
R="$WORK/repo"; mkdir -p "$R"; cd "$R"
git init -q; git config user.email t@t; git config user.name t
echo hi > f; git add -A; git commit -qm init; git branch -M main

# --- empty case: no projects/ dir -> friendly message, not an error ----------
"$CANOPY" project ls >/dev/null 2>&1 && ok "ls with no projects/ exits 0" || bad "ls errored on missing projects/"

# --- ls lists a registered repo with abs path, no board -> no count ----------
mkproj "$R" demo
out="$("$CANOPY" project ls 2>/dev/null)"
eq "ls shows the demo project name+path" "$out" "$(printf 'demo\t%s/projects/demo' "$R")"

# --- a non-repo subdir is NOT a project (must have its own .git) --------------
mkdir -p "$R/projects/notrepo"
out="$("$CANOPY" project ls 2>/dev/null)"
eq "ls ignores a non-git subdir" "$out" "$(printf 'demo\t%s/projects/demo' "$R")"

# --- a project WITH its own .canopy board reports an in-flight count ----------
mkproj "$R" boarded
( cd "$R/projects/boarded" && "$CANOPY" init >/dev/null 2>&1 \
  && "$CANOPY" task add "do a thing" >/dev/null 2>&1 )
out="$("$CANOPY" project ls 2>/dev/null | grep '^boarded')"
eq "ls reports in-flight count from a project's board" "$out" "$(printf 'boarded\t%s/projects/boarded\t1 in-flight' "$R")"

# --- path: exact basename match wins -----------------------------------------
eq "path resolves exact name" "$("$CANOPY" project path demo 2>/dev/null)" "$R/projects/demo"

# --- path: unique case-insensitive substring match ---------------------------
eq "path resolves by substring (case-insensitive)" "$("$CANOPY" project path DEM 2>/dev/null)" "$R/projects/demo"

# --- path: zero matches fails loudly, listing candidates ---------------------
if err="$("$CANOPY" project path nope 2>&1 >/dev/null)"; then
  bad "path should fail on no match"
else
  case "$err" in *demo*) ok "no-match error lists candidates" ;; *) bad "no-match error missing candidates: $err" ;; esac
fi

# --- path: ambiguous substring fails loudly, listing the matches -------------
mkproj "$R" demo2
if err="$("$CANOPY" project path dem 2>&1 >/dev/null)"; then
  bad "path should fail on ambiguity"
else
  case "$err" in *demo*demo2*|*demo2*demo*) ok "ambiguous error lists both matches" ;; *) bad "ambiguous error missing matches: $err" ;; esac
fi

# --- exact still wins even when it is also a substring of another -------------
eq "exact match wins over ambiguous substring" "$("$CANOPY" project path demo 2>/dev/null)" "$R/projects/demo"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
