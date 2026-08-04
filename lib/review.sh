# review.sh — the lean gate: ONE independent review pass. Sourced, not executed.
# shellcheck shell=bash
#
# `canopy review <id>` runs a single review pass and prints the verdict JSON.
# The bounded (<=2 round) fix->re-review loop lives in the ORCHESTRATOR prompt,
# which calls `canopy review` and `canopy worker fix` — canopy provides primitives.

REVIEWER_MODEL="${CANOPY_REVIEWER_MODEL:-claude-haiku-4-5-20251001}"

_default_branch() {
  local wt="$1" d
  # `|| d=""` keeps this set -e safe: with no origin/HEAD the pipe fails, and an
  # unguarded `d=$(...)` under `set -euo pipefail` would abort the caller.
  d="$(git -C "$wt" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@.*/@@')" || d=""
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

# _review_intent_section <brief> <why>  -> intent block for the prompt (empty if none)
# Feeds the task's stated goal so the reviewer can tell a deliberate choice from a
# bug (a change that contradicts an explicit intent is an ask-user finding).
_review_intent_section() {
  local brief="$1" why="$2"
  [ -n "$brief" ] || [ -n "$why" ] || { printf ''; return; }
  printf '\nIntent (authoritative — what this change is meant to do):\n'
  [ -n "$brief" ] && printf -- '- Goal: %s\n' "$brief"
  [ -n "$why" ]   && printf -- '- Why: %s\n' "$why"
}

# _review_provenance <worktree> <prev_reviewed_head>  -> fix-round provenance block
# Empty on the first review (no prior reviewed head, or head unchanged). On a
# re-review after the worker fixed findings, it lists the commits authored SINCE
# the last review so the reviewer treats them as fresh, unreviewed code.
_review_provenance() {
  local wt="$1" prev="$2" head commits
  [ -n "$prev" ] || { printf ''; return; }
  git -C "$wt" cat-file -e "${prev}^{commit}" 2>/dev/null || { printf ''; return; }
  head="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"
  [ -n "$head" ] && [ "$head" != "$prev" ] || { printf ''; return; }
  commits="$(git -C "$wt" log --oneline "${prev}..${head}" 2>/dev/null)"
  [ -n "$commits" ] || { printf ''; return; }
  printf '\nFix-round provenance — THIS IS A RE-REVIEW:\n'
  printf 'The commits below were authored AFTER the previous review (%s), to address its findings. Treat them as fresh, unreviewed code — prior findings/fix-summaries are claims, not evidence, and a test added alongside its code is part of that claim, not proof:\n' "$prev"
  printf '%s\n' "$commits" | sed 's/^/  - /'
}

# _review_prompt <base> <head> <intent_section> <prov_section> <diff> -> user prompt
_review_prompt() {
  local base="$1" head="$2" intent="$3" prov="$4" diff="$5"
  printf 'Review this change (base=%s head=%s). Return ONLY the JSON verdict, nothing else.\n' "$base" "$head"
  [ -n "$intent" ] && printf '%s' "$intent"
  [ -n "$prov" ]   && printf '%s' "$prov"
  printf '\n```diff\n%s\n```\n' "$diff"
}

# _review_once <worktree> [intent_section] [prov_section] -> verdict JSON on stdout
# Runs the reviewer with cwd = the branch worktree and only read-only tools, so it
# can follow changed symbols to their call sites without stalling on a permission
# prompt (headless) and without any ability to edit or run the suite.
_reviewer_model_for() {
  case "${1:-claude}" in
    codex) printf '%s\n' "${CANOPY_CODEX_REVIEWER_MODEL:-gpt-5.4}" ;;
    *)     printf '%s\n' "$REVIEWER_MODEL" ;;
  esac
}

_reviewer_agent_default() {
  if [ -n "${CANOPY_ORCHESTRATOR_AGENT:-}" ]; then
    _canopy_agent_validate "$CANOPY_ORCHESTRATOR_AGENT"
  else
    printf '%s\n' claude
  fi
}

_review_schema() {
  cat <<'EOF'
{
  "type": "object",
  "additionalProperties": false,
  "required": ["verdict", "risk_level", "risk_rationale", "issues", "docs_in_sync", "summary"],
  "properties": {
    "verdict": { "type": "string", "enum": ["clean", "issues"] },
    "risk_level": { "type": "string", "enum": ["low", "med", "high"] },
    "risk_rationale": { "type": "string" },
    "issues": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["severity", "action", "where", "problem", "fix"],
        "properties": {
          "severity": { "type": "string", "enum": ["high", "med", "low"] },
          "action": { "type": "string", "enum": ["worker-fix", "ask-user", "no-op"] },
          "where": { "type": "string" },
          "problem": { "type": "string" },
          "fix": { "type": "string" }
        }
      }
    },
    "docs_in_sync": { "type": "boolean" },
    "summary": { "type": "string" }
  }
}
EOF
}

_review_once_claude() {
  local wt="$1" intent="${2:-}" prov="${3:-}" base head diff out
  base="$(git -C "$wt" merge-base HEAD "$(base_branch "$wt")" 2>/dev/null || git -C "$wt" rev-parse HEAD~1 2>/dev/null || echo '')"
  head="$(git -C "$wt" rev-parse HEAD)"
  if [ -z "$base" ] || [ "$base" = "$head" ]; then
    echo '{"verdict":"clean","risk_level":"low","issues":[],"docs_in_sync":true,"summary":"no diff to review"}'; return
  fi
  diff="$(git -C "$wt" diff "$base..$head")"
  [ -n "$diff" ] || { echo '{"verdict":"clean","risk_level":"low","issues":[],"docs_in_sync":true,"summary":"empty diff"}'; return; }

  out="$( cd "$wt" && claude -p --model "$REVIEWER_MODEL" \
            --allowedTools Read Grep Glob \
            --append-system-prompt "$(_agent_body reviewer)" \
            "$(_review_prompt "$base" "$head" "$intent" "$prov" "$diff")" 2>/dev/null )"
  printf '%s' "$out" | _extract_json
}

_review_once_codex() {
  local wt="$1" intent="${2:-}" prov="${3:-}" base head diff out schema msgf prompt model
  local -a codex_args
  base="$(git -C "$wt" merge-base HEAD "$(_default_branch "$wt")" 2>/dev/null || git -C "$wt" rev-parse HEAD~1 2>/dev/null || echo '')"
  head="$(git -C "$wt" rev-parse HEAD)"
  if [ -z "$base" ] || [ "$base" = "$head" ]; then
    echo '{"verdict":"clean","risk_level":"low","risk_rationale":"no diff to review","issues":[],"docs_in_sync":true,"summary":"no diff to review"}'; return
  fi
  diff="$(git -C "$wt" diff "$base..$head")"
  [ -n "$diff" ] || { echo '{"verdict":"clean","risk_level":"low","risk_rationale":"empty diff","issues":[],"docs_in_sync":true,"summary":"empty diff"}'; return; }
  schema="$(mktemp "${TMPDIR:-/tmp}/canopy-review-schema.XXXXXX.json")"
  msgf="$(mktemp "${TMPDIR:-/tmp}/canopy-review-msg.XXXXXX.json")"
  _review_schema > "$schema"
  prompt="$(_review_prompt "$base" "$head" "$intent" "$prov" "$diff")"
  model="$(_reviewer_model_for codex)"
  codex_args=(-s read-only -C "$wt" -m "$model")
  _codex_has_bypass_arg "${codex_args[@]+"${codex_args[@]}"}" || codex_args+=("$(_codex_bypass_flag)")
  if ! out="$( cd "$wt" && printf '%s' "$prompt" | codex "${codex_args[@]}" \
      exec --output-schema "$schema" -o "$msgf" - 2>&1 )"; then
    rm -f "$schema" "$msgf"
    die "codex reviewer failed: ${out:-unknown error}"
  fi
  [ -s "$msgf" ] || { rm -f "$schema" "$msgf"; die "codex reviewer returned no verdict"; }
  cat "$msgf"
  rm -f "$schema" "$msgf"
}

# canopy review <id>  -> prints verdict JSON; exit 0 if clean, 1 if issues
canopy_review() {
  require_canopy; need jq
  local agent="" id tf wt v verdict risk intent prov brief why prev head
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --agent) shift; agent="$(_canopy_agent_validate "${1:-}")" ;;
      -h|--help)
        cat <<'EOF'
usage: canopy review [--agent claude|codex] <id>
EOF
        return 0 ;;
      *) id="${1}"; break ;;
    esac
    shift
  done
  id="${id:-${1:-}}"
  [ -n "$id" ] || die "usage: canopy review [--agent claude|codex] <id>"
  _assert_task "$id"
  tf="$(task_file "$id")"
  wt="$(jq -r '.worktree // empty' "$tf")"
  [ -n "$wt" ] || die "task $id not leased"
  # Follow the orchestrator harness by default; explicit --agent still wins.
  agent="${agent:-$(_reviewer_agent_default)}"
  task_status "$id" reviewing >/dev/null

  # Intent (goal + why) sharpens deliberate-choice-vs-bug judgement.
  brief="$(jq -r '.what // .brief // ""' "$tf")"
  why="$(jq -r '.why // ""' "$tf")"
  intent="$(_review_intent_section "$brief" "$why")"
  # Fix-round provenance: if we reviewed this task before, tell the reviewer which
  # commits are the (unreviewed) fixes made since — so it re-reviews them fresh.
  prev="$(jq -r '.review_head // ""' "$tf")"
  prov="$(_review_provenance "$wt" "$prev")"

  case "$agent" in
    claude) need claude; v="$(_review_once_claude "$wt" "$intent" "$prov")" ;;
    codex)  need codex;  v="$(_review_once_codex "$wt" "$intent" "$prov")" ;;
  esac
  [ -n "$v" ] || die "reviewer returned nothing parseable"
  printf '%s' "$v" | jq -e '.verdict' >/dev/null 2>&1 || die "reviewer verdict not valid JSON: $v"

  task_log "$id" "review($agent): $(printf '%s' "$v" | jq -rc '{verdict,risk_level,docs_in_sync,summary}')"
  verdict="$(printf '%s' "$v" | jq -r '.verdict')"
  risk="$(printf '%s' "$v" | jq -r '.risk_level // "unknown"')"
  head="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"
  task_set "$id" reviewed "$verdict" >/dev/null   # gate signal for 'canopy pr open'
  task_set "$id" review_risk "$risk" >/dev/null
  task_set "$id" review_head "$head" >/dev/null    # marks this SHA as reviewed (fix-round detection)
  task_set "$id" review_summary "$(printf '%s' "$v" | jq -r '.summary // ""')" >/dev/null
  printf '%s\n' "$v"
  if [ "$verdict" = "clean" ]; then info "review clean ✓ (risk: $risk)"; return 0
  else info "review found issues (risk: $risk)"; return 1; fi
}
