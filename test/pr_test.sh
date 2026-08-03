#!/usr/bin/env bash
# PR body template + checks status (no gh-axi). Run: bash test/pr_test.sh
set -uo pipefail
export CANOPY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANOPY="$CANOPY_ROOT/bin/canopy"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
has() { printf '%s' "$1" | grep -qF -- "$2" && ok "body has: $2" || bad "body missing: $2"; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

. "$CANOPY_ROOT/lib/common.sh"; . "$CANOPY_ROOT/lib/state.sh"
. "$CANOPY_ROOT/lib/checks.sh"; . "$CANOPY_ROOT/lib/review.sh"; . "$CANOPY_ROOT/lib/pr.sh"

echo "== checks status =="
PDIR="$WORK/proj"; mkdir -p "$PDIR"
echo '{"checks":{"test":"true","lint":"false"}}' > "$PDIR/canopy.json"
LINE="$(canopy_checks_status "$PDIR")" && rc=0 || rc=$?
printf '%s' "$LINE" | grep -q '✅ test'  && ok "status shows passing check" || bad "no ✅ test"
printf '%s' "$LINE" | grep -q '❌ lint'  && ok "status shows failing check" || bad "no ❌ lint"
[ "$rc" -ne 0 ] && ok "status non-zero when a check fails" || bad "status should fail"

echo "== PR body template =="
R="$WORK/repo"; mkdir -p "$R"; ( cd "$R"; git init -q; git config user.email t@t; git config user.name t; echo a>f; git add -A; git commit -qm base )
cd "$R"; "$CANOPY" init >/dev/null 2>&1
ID="$("$CANOPY" task add "add /health endpoint" 2>/dev/null)"
"$CANOPY" task set "$ID" brief "adds GET /health returning 200 ok" >/dev/null
"$CANOPY" task set "$ID" why "the load balancer needs a liveness probe" >/dev/null
"$CANOPY" task set "$ID" issue 42 >/dev/null
"$CANOPY" task set "$ID" breaking "none, additive only" >/dev/null
"$CANOPY" task set "$ID" verify "curl localhost:3000/health" >/dev/null
"$CANOPY" task set "$ID" reviewed clean >/dev/null
"$CANOPY" task set "$ID" review_summary "small, well-tested, docs updated" >/dev/null
"$CANOPY" task set "$ID" checks_line "✅ test  ✅ lint" >/dev/null
# a worktree with a diff
WT="$WORK/wt"; cp -r "$R" "$WT"; ( cd "$WT"; printf 'health\n' >> f; echo new>g; git add -A; git commit -qm "feat: add /health" )
BASE="$(git -C "$WT" rev-parse HEAD~1)"

BODY="$(_pr_body "$ID" "$WT" "$BASE")"
has "$BODY" "**Summary** — add /health endpoint"   # falls back to title when no summary set
has "$BODY" "**Why** — the load balancer needs a liveness probe"
has "$BODY" "Closes #42"
has "$BODY" "## What changed"
has "$BODY" "adds GET /health returning 200 ok"
has "$BODY" "## Testing"
has "$BODY" "✅ test  ✅ lint"
has "$BODY" "🔍 Independent review: **clean** — small, well-tested, docs updated"
has "$BODY" "Verify: \`curl localhost:3000/health\`"
has "$BODY" "## Risk / breaking"
has "$BODY" "none, additive only"
printf '%s' "$BODY" | grep -qE '## Files \([0-9]+, \+[0-9]+/-[0-9]+\)' && ok "files line has scope (n, +x/-y)" || bad "no scope on files line"

# an explicit summary overrides the title fallback
"$CANOPY" task set "$ID" summary "one-line elevator pitch" >/dev/null
BODY2="$(_pr_body "$ID" "$WT" "$BASE")"
has "$BODY2" "**Summary** — one-line elevator pitch"

echo "== triage labels =="
TF="$(task_file "$ID")"
# conventional-commit type -> label
[ "$(_label_for_type 'fix: null check')"        = bug ]           && ok "fix -> bug"            || bad "fix should map to bug"
[ "$(_label_for_type 'feat(pr): add x')"        = enhancement ]   && ok "feat(scope) -> enhancement" || bad "feat should map to enhancement"
[ "$(_label_for_type 'perf: speed up')"         = enhancement ]   && ok "perf -> enhancement"   || bad "perf should map to enhancement"
[ "$(_label_for_type 'docs: readme')"           = documentation ] && ok "docs -> documentation" || bad "docs should map to documentation"
[ -z "$(_label_for_type 'chore: bump deps')" ]                    && ok "chore -> no label"     || bad "chore should map to nothing"
# derived label applied when none set
"$CANOPY" task set "$ID" labels "" >/dev/null 2>&1 || true
[ "$(_pr_labels "$TF" 'fix: x')" = bug ] && ok "unlabeled task gets derived 'bug' from a fix: title" || bad "no derived label"
# explicit labels union with derived, de-duplicated
"$CANOPY" task set "$ID" labels "urgent bug" >/dev/null
LBLS="$(_pr_labels "$TF" 'fix: x')"
case " $LBLS " in *" urgent "*) case " $LBLS " in *" bug "*) ok "explicit + derived union" ;; *) bad "missing bug: $LBLS" ;; esac ;; *) bad "missing urgent: $LBLS" ;; esac
[ "$(printf '%s' "$LBLS" | tr ' ' '\n' | grep -c '^bug$')" = 1 ] && ok "no duplicate 'bug'" || bad "duplicate label: $LBLS"

echo "== PR open after successful push =="
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
GH_LOG="$WORK/gh-axi.log"; export GH_LOG
REAL_TAIL="$(command -v tail)"; export REAL_TAIL
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "$*" >> "$GH_LOG"' \
  'case "$1 $2" in' \
  '  "label create") exit 0 ;;' \
  '  "pr create")' \
  '    [ "${GH_AXI_PR_CREATE_FAIL:-0}" = 1 ] && { printf "%s\n" "boom from gh-axi"; exit 42; }' \
  '    [ "${GH_AXI_PR_CREATE_UNPARSABLE:-0}" = 1 ] && { printf "%s\n" "created somewhere unexpected"; exit 0; }' \
  '    printf "%s\n" "https://github.com/org/repo/pull/777"; exit 0 ;;' \
  'esac' \
  'exit 0' > "$FAKEBIN/gh-axi"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [ "${1:-}" = "-1" ]; then exit 9; fi' \
  'exec "$REAL_TAIL" "$@"' > "$FAKEBIN/tail"
chmod +x "$FAKEBIN/gh-axi" "$FAKEBIN/tail"

ORIGIN="$WORK/origin.git"; git init --bare -q "$ORIGIN"
PRR="$WORK/pr-open-repo"; mkdir -p "$PRR"; (
  cd "$PRR"
  git init -q
  git config user.email t@t
  git config user.name t
  printf 'base\n' > f
  git add -A
  git commit -qm base
  git branch -M main
  git remote add origin "$ORIGIN"
  git push -q -u origin main
)
(
  cd "$PRR"
  "$CANOPY" init >/dev/null 2>&1
  PRID="$("$CANOPY" task add "open pr after push" 2>/dev/null)"
  git checkout -qb rhyu/tail-regression
  printf 'change\n' >> f
  git add -A
  git commit -qm "fix: open pr after push"
  "$CANOPY" task set "$PRID" worktree "$PRR" >/dev/null
  "$CANOPY" task set "$PRID" branch rhyu/tail-regression >/dev/null
  "$CANOPY" task set "$PRID" reviewed clean >/dev/null
  PATH="$FAKEBIN:$PATH" CANOPY_SKIP_CHECKS=1 "$CANOPY" pr open "$PRID" > "$WORK/pr-open.out" 2> "$WORK/pr-open.err"
)
PR_RC=$?
[ "$PR_RC" -eq 0 ] && ok "pr open succeeds after push when tail -1 is unavailable" || { bad "pr open failed after push"; sed 's/^/       /' "$WORK/pr-open.err"; }
grep -q '^pr create ' "$GH_LOG" && ok "gh-axi pr create runs after push" || bad "gh-axi pr create did not run"
[ "$(cat "$WORK/pr-open.out")" = 777 ] && ok "pr open prints PR number only" || bad "unexpected pr open stdout: $(cat "$WORK/pr-open.out")"

(
  cd "$PRR"
  PRID2="$("$CANOPY" task add "open pr create failure" 2>/dev/null)"
  git checkout -qb rhyu/pr-create-failure
  printf 'fail\n' >> f
  git add -A
  git commit -qm "fix: surface pr create failure"
  "$CANOPY" task set "$PRID2" worktree "$PRR" >/dev/null
  "$CANOPY" task set "$PRID2" branch rhyu/pr-create-failure >/dev/null
  "$CANOPY" task set "$PRID2" reviewed clean >/dev/null
  PATH="$FAKEBIN:$PATH" GH_AXI_PR_CREATE_FAIL=1 CANOPY_SKIP_CHECKS=1 "$CANOPY" pr open "$PRID2" > "$WORK/pr-fail.out" 2> "$WORK/pr-fail.err"
)
PR_FAIL_RC=$?
[ "$PR_FAIL_RC" -ne 0 ] && ok "pr open fails when gh-axi pr create fails" || bad "pr open should fail on pr create failure"
grep -q 'boom from gh-axi' "$WORK/pr-fail.err" && ok "pr create stderr includes captured gh-axi error" || bad "missing captured gh-axi error"
grep -q 'pr create failed' "$WORK/pr-fail.err" && ok "pr create failure message is clear" || bad "missing clear pr create failure"

(
  cd "$PRR"
  PRID3="$("$CANOPY" task add "open pr unparsable output" 2>/dev/null)"
  git checkout -qb rhyu/pr-unparsable-output
  printf 'unparsable\n' >> f
  git add -A
  git commit -qm "fix: surface unparsable pr output"
  "$CANOPY" task set "$PRID3" worktree "$PRR" >/dev/null
  "$CANOPY" task set "$PRID3" branch rhyu/pr-unparsable-output >/dev/null
  "$CANOPY" task set "$PRID3" reviewed clean >/dev/null
  PATH="$FAKEBIN:$PATH" GH_AXI_PR_CREATE_UNPARSABLE=1 CANOPY_SKIP_CHECKS=1 "$CANOPY" pr open "$PRID3" > "$WORK/pr-unparsable.out" 2> "$WORK/pr-unparsable.err"
)
PR_UNPARSABLE_RC=$?
[ "$PR_UNPARSABLE_RC" -ne 0 ] && ok "pr open fails on unparsable gh-axi output" || bad "pr open should fail on unparsable gh-axi output"
grep -q 'created somewhere unexpected' "$WORK/pr-unparsable.err" && ok "unparsable output is shown" || bad "missing unparsable gh-axi output"
grep -q 'could not parse PR number from gh-axi output' "$WORK/pr-unparsable.err" && ok "unparsable PR number message is clear" || bad "missing unparsable PR number message"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
