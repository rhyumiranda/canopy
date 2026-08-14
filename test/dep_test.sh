#!/usr/bin/env bash
# Task dependencies / contract-first gate: a task can declare depends_on other
# tasks, and its worktree refuses to lease until every dependency has merged.
# Deterministic (no LLM, no treehouse — the gate runs before treehouse is touched,
# so we exercise the gate function directly). Run: bash test/dep_test.sh
set -uo pipefail
CANOPY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANOPY="$CANOPY_ROOT/bin/canopy"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=[%s] got=[%s]\n' "$3" "$2"; }; }
command -v jq  >/dev/null || { echo "jq required";  exit 1; }
command -v git >/dev/null || { echo "git required"; exit 1; }

echo "== task dependencies / contract-first gate =="

R="$WORK/repo"; mkdir -p "$R"; cd "$R"
git init -q; git config user.email t@t; git config user.name t
echo hi > f; git add -A; git commit -qm init; git branch -M main
"$CANOPY" init >/dev/null 2>&1

# ids are monotonic t1,t2,t3 in a fresh sandbox
C="$("$CANOPY" task add "define notifications contract" 2>/dev/null)"   # t1 (the contract)
A="$("$CANOPY" task add "notifications client" 2>/dev/null)"            # t2 (a side)
B="$("$CANOPY" task add "notifications server" 2>/dev/null)"            # t3 (a side)
eq "task ids assigned in order" "$C $A $B" "t1 t2 t3"

# fresh task carries an empty depends_on (both board and detail)
eq "new task detail has depends_on []" "$(jq -c '.depends_on' "$R/.canopy/tasks/$A.json")" "[]"
eq "new task board has depends_on []"  "$(jq -c --arg id "$A" '.tasks[]|select(.id==$id)|.depends_on' "$R/.canopy/state.json")" "[]"

# --- set a dependency ---
"$CANOPY" task set "$A" depends_on "$C" >/dev/null 2>&1
eq "depends_on stored as array in detail" "$(jq -c '.depends_on' "$R/.canopy/tasks/$A.json")" '["t1"]'
eq "depends_on mirrored to board"         "$(jq -c --arg id "$A" '.tasks[]|select(.id==$id)|.depends_on' "$R/.canopy/state.json")" '["t1"]'

# multiple deps, space- and comma-separated, de-duplicated
"$CANOPY" task set "$B" depends_on "$C, $C $A" >/dev/null 2>&1
eq "multi/dup deps normalized + de-duped" "$(jq -c '.depends_on' "$R/.canopy/tasks/$B.json")" '["t1","t2"]'

# clearing
"$CANOPY" task set "$B" depends_on "" >/dev/null 2>&1
eq "empty value clears deps" "$(jq -c '.depends_on' "$R/.canopy/tasks/$B.json")" "[]"
"$CANOPY" task set "$B" depends_on "$C" >/dev/null 2>&1  # restore for later

# --- validation ---
if "$CANOPY" task set "$A" depends_on "$A" >/dev/null 2>&1; then bad "self-dependency should be rejected"; else ok "self-dependency rejected"; fi
if "$CANOPY" task set "$A" depends_on "t99" >/dev/null 2>&1; then bad "missing dep id should be rejected"; else ok "missing dep id rejected"; fi
# cycle: t1 -> t2 while t2 -> t1 already
if "$CANOPY" task set "$C" depends_on "$A" >/dev/null 2>&1; then bad "cycle should be rejected"; else ok "cycle rejected (t1->t2->t1)"; fi
eq "rejected set left t1 deps untouched" "$(jq -c '.depends_on' "$R/.canopy/tasks/$C.json")" "[]"

# --- board display surfaces the dependency ---
"$CANOPY" status >/dev/null 2>&1
BOARD="$("$CANOPY" status 2>&1)"
printf '%s' "$BOARD" | grep -q "after t1" && ok "status shows '⟂ after t1'" || { bad "status should show the dependency"; printf '       board=[%s]\n' "$BOARD"; }

# --- the gate itself (_assert_deps_merged) ---
export CANOPY_ROOT
. "$CANOPY_ROOT/lib/common.sh"
. "$CANOPY_ROOT/lib/state.sh"
. "$CANOPY_ROOT/lib/watch.sh"     # _pr_is_merged
. "$CANOPY_ROOT/lib/worktree.sh"  # _assert_deps_merged

# t3 has no deps set? it depends_on t1 (restored above). t1 is unmerged (planning) -> blocked.
( cd "$R" && _assert_deps_merged "$B" >/dev/null 2>&1 ) && bad "gate must block while dep unmerged" || ok "gate blocks lease while dep unmerged"

# a task with NO deps is never blocked
( cd "$R" && _assert_deps_merged "$C" >/dev/null 2>&1 ) && ok "gate passes a task with no deps" || bad "no-dep task must not be blocked"

# dep satisfied via local status (watcher flips a merged PR's task to done/merged)
"$CANOPY" task status "$C" done >/dev/null 2>&1
( cd "$R" && _assert_deps_merged "$B" >/dev/null 2>&1 ) && ok "gate passes once dep status is done" || bad "gate should pass when dep is done"

# dep satisfied via live PR check (status not done/merged, but its PR reads merged)
"$CANOPY" task add "second contract" >/dev/null 2>&1            # t4
"$CANOPY" task add "consumer of t4" >/dev/null 2>&1             # t5
"$CANOPY" task set t5 depends_on t4 >/dev/null 2>&1
"$CANOPY" task set t4 pr 42 >/dev/null 2>&1                     # t4 still 'planning', but has a PR
STUB="$WORK/bin"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\necho "state: MERGED"\n' > "$STUB/gh-axi"; chmod +x "$STUB/gh-axi"
( cd "$R" && PATH="$STUB:$PATH" _assert_deps_merged t5 >/dev/null 2>&1 ) && ok "gate passes via live merged-PR check" || bad "gate should pass when dep PR is merged live"
# and blocks when the live PR is still open
printf '#!/usr/bin/env bash\necho "state: OPEN"\n' > "$STUB/gh-axi"; chmod +x "$STUB/gh-axi"
( cd "$R" && PATH="$STUB:$PATH" _assert_deps_merged t5 >/dev/null 2>&1 ) && bad "gate must block while dep PR open" || ok "gate blocks while dep PR still open"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
