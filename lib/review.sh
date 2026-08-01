# review.sh — the lean gate: ONE independent review pass. Sourced, not executed.
# shellcheck shell=bash
#
# `canopy review <id>` runs a single review pass and prints the verdict JSON.
# The bounded (<=2 round) fix->re-review loop lives in the ORCHESTRATOR prompt,
# which calls `canopy review` and `canopy worker fix` — canopy provides primitives.

REVIEWER_MODEL="${CANOPY_REVIEWER_MODEL:-claude-haiku-4-5-20251001}"

_default_branch() {
  local wt="$1" d
  d="$(git -C "$wt" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@.*/@@')"
  [ -n "$d" ] && { echo "$d"; return; }
  for b in main master; do
    git -C "$wt" show-ref --verify --quiet "refs/heads/$b" && { echo "$b"; return; }
  done
  echo main
}

# pull the first JSON object out of (possibly fenced / chatty) model output
_extract_json() {
  local raw; raw="$(cat)"
  raw="$(printf '%s' "$raw" | sed 's/```json//g; s/```//g')"
  if printf '%s' "$raw" | jq -ce '.' >/dev/null 2>&1; then
    printf '%s' "$raw" | jq -c '.'
  else
    printf '%s' "$raw" | tr '\n' ' ' | grep -oE '\{.*\}' | head -1
  fi
}

# _review_once <worktree> -> verdict JSON on stdout
_review_once() {
  local wt="$1" base head diff out
  base="$(git -C "$wt" merge-base HEAD "$(_default_branch "$wt")" 2>/dev/null || git -C "$wt" rev-parse HEAD~1 2>/dev/null || echo '')"
  head="$(git -C "$wt" rev-parse HEAD)"
  if [ -z "$base" ] || [ "$base" = "$head" ]; then
    echo '{"verdict":"clean","issues":[],"docs_in_sync":true,"summary":"no diff to review"}'; return
  fi
  diff="$(git -C "$wt" diff "$base..$head")"
  [ -n "$diff" ] || { echo '{"verdict":"clean","issues":[],"docs_in_sync":true,"summary":"empty diff"}'; return; }

  out="$( claude -p --model "$REVIEWER_MODEL" \
            --append-system-prompt "$(_agent_body reviewer)" \
            "Review this diff (base=$base head=$head). Return ONLY the JSON verdict, nothing else.

\`\`\`diff
$diff
\`\`\`" 2>/dev/null )"
  printf '%s' "$out" | _extract_json
}

# canopy review <id>  -> prints verdict JSON; exit 0 if clean, 1 if issues
canopy_review() {
  require_canopy; need claude; need jq
  local id="${1:?task id}"; _assert_task "$id"
  local wt v verdict
  wt="$(jq -r '.worktree // empty' "$(task_file "$id")")"
  [ -n "$wt" ] || die "task $id not leased"
  task_status "$id" reviewing >/dev/null

  v="$(_review_once "$wt")"
  [ -n "$v" ] || die "reviewer returned nothing parseable"
  printf '%s' "$v" | jq -e '.verdict' >/dev/null 2>&1 || die "reviewer verdict not valid JSON: $v"

  task_log "$id" "review: $(printf '%s' "$v" | jq -rc '{verdict,docs_in_sync,summary}')"
  verdict="$(printf '%s' "$v" | jq -r '.verdict')"
  printf '%s\n' "$v"
  if [ "$verdict" = "clean" ]; then info "review clean ✓"; return 0
  else info "review found issues"; return 1; fi
}
