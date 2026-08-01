# pr.sh — open PRs via gh-axi + gate on review/checks/CI. Sourced, not executed.
# shellcheck shell=bash

# " 3 files changed, 42 insertions(+), 7 deletions(-)" -> "<n> <ins> <del>"
_diff_scope() {
  local wt="$1" base="$2" line n i d
  line="$(git -C "$wt" diff --shortstat "$base"..HEAD 2>/dev/null)"
  n="$(printf '%s' "$line" | grep -oE '[0-9]+ files? changed' | grep -oE '[0-9]+' | head -1)"
  i="$(printf '%s' "$line" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' | head -1)"
  d="$(printf '%s' "$line" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' | head -1)"
  printf '%s %s %s\n' "${n:-0}" "${i:-0}" "${d:-0}"
}

_review_line() {
  local tf="$1" v s
  v="$(jq -r '.reviewed // "none"' "$tf")"
  s="$(jq -r '.review_summary // ""' "$tf")"
  case "$v" in
    clean)  printf '🔍 Independent review: **clean**%s' "$([ -n "$s" ] && printf ' — %s' "$s")" ;;
    issues) printf '🔍 Independent review: had issues, resolved before this PR' ;;
    *)      printf '🔍 Independent review: (not recorded)' ;;
  esac
}

_verify_cmd() {
  local tf="$1" wt="$2" v t
  v="$(jq -r '.verify // empty' "$tf")"
  [ -n "$v" ] && { printf '%s\n' "$v"; return; }
  t="$(_checks_config "$wt" | awk -F'\t' '$1=="test"{print $2; exit}')"
  printf '%s\n' "${t:-canopy checks run}"
}

_pr_body() {
  local id="$1" wt="$2" base="$3" tf title what why issue breaking stat verify
  tf="$(task_file "$id")"
  title="$(jq -r '.title' "$tf")"
  what="$(jq -r '.what // .brief // ""' "$tf")"
  why="$(jq -r '.why // ""' "$tf")"
  issue="$(jq -r '.issue // empty' "$tf")"
  breaking="$(jq -r '.breaking // ""' "$tf")"
  stat="$(git -C "$wt" diff --stat "$base"..HEAD | sed 's/^/    /')"
  verify="$(_verify_cmd "$tf" "$wt")"
  # shellcheck disable=SC2046
  set -- $(_diff_scope "$wt" "$base"); local nf="$1" ins="$2" del="$3"

  cat <<EOF
${title}

**What** — ${what:-_(not specified)_}
**Why** — ${why:-_(not specified)_}$([ -n "$issue" ] && printf '   ·   Closes #%s' "$issue")

## How to verify
\`\`\`bash
${verify}
\`\`\`

## Checks
$(jq -r '.checks_line // "(not recorded)"' "$tf")
$(_review_line "$tf")

## Breaking changes
${breaking:-None.}

## Files (${nf}, +${ins}/-${del})
$stat

---
🌳 Opened by Canopy · task \`$id\`
EOF
}

# canopy pr open <id>  -> prints the PR number
canopy_pr_open() {
  require_canopy; need gh-axi; need git; need jq
  local id="${1:?task id}"; _assert_task "$id"
  local tf wt branch base title body out prnum checks_line labels
  tf="$(task_file "$id")"
  wt="$(jq -r '.worktree // empty' "$tf")"; [ -d "$wt" ] || die "task $id has no worktree"
  branch="$(jq -r '.branch // empty' "$tf")"; [ -n "$branch" ] || die "task $id has no branch"

  # HARD GATE 1: no PR without a clean independent review (override for hotfix/budget-0).
  local reviewed; reviewed="$(jq -r '.reviewed // "none"' "$tf")"
  if [ "$reviewed" != "clean" ] && [ "${CANOPY_SKIP_REVIEW:-0}" != "1" ]; then
    die "task $id not reviewed clean (reviewed=$reviewed) — run 'canopy review $id' first (or CANOPY_SKIP_REVIEW=1)"
  fi

  # HARD GATE 2: deterministic checks must pass locally; capture the rendered line for the body.
  if checks_line="$(canopy_checks_status "$wt")"; then :; else
    [ "${CANOPY_SKIP_CHECKS:-0}" = "1" ] || die "task $id has failing checks: $checks_line (fix them, or CANOPY_SKIP_CHECKS=1)"
  fi
  task_set "$id" checks_line "$checks_line" >/dev/null

  base="$(_default_branch "$wt")"
  title="$(git -C "$wt" log -1 --pretty=%s)"

  info "pushing $branch"
  git -C "$wt" push -q -u origin "$branch" 2>&1 | tail -1 || die "push failed for $branch"

  body="$(_pr_body "$id" "$wt" "$base")"

  # optional labels: .labels may be a JSON array or a space-separated string
  local -a label_args=(); labels="$(jq -r '.labels // empty | if type=="array" then join(" ") else . end' "$tf")"
  local l; for l in $labels; do label_args+=(--label "$l"); done

  out="$( cd "$wt" && gh-axi pr create --title "$title" --body "$body" --base "$base" --head "$branch" "${label_args[@]}" 2>&1 )"
  prnum="$(printf '%s' "$out" | grep -oE '/pull/[0-9]+|#[0-9]+' | grep -oE '[0-9]+' | head -1)"
  if [ -z "$prnum" ]; then warn "could not parse PR number:"; printf '%s\n' "$out" >&2; die "pr create may have failed"; fi

  task_set "$id" pr "$prnum" >/dev/null
  task_status "$id" pr-open >/dev/null
  task_log "$id" "opened PR #$prnum ($branch)"
  info "opened PR #$prnum"
  printf '%s\n' "$prnum"
}

# canopy pr checks <id>  -> 0 green/none, 1 failing, 2 pending
canopy_pr_checks() {
  require_canopy; need gh-axi
  local id="${1:?task id}"; _assert_task "$id"
  local pr out; pr="$(jq -r '.pr // empty' "$(task_file "$id")")"
  [ -n "$pr" ] || die "task $id has no PR"
  out="$(gh-axi pr checks "$pr" 2>&1)"
  if printf '%s' "$out" | grep -qiE 'no checks|no ci|not configured|no required'; then
    warn "no CI checks on PR #$pr — nothing to gate on"; return 0
  fi
  if printf '%s' "$out" | grep -qiE '\bfail|\berror|✗|✘'; then warn "PR #$pr: failing checks"; return 1; fi
  if printf '%s' "$out" | grep -qiE 'pending|in.progress|queued|running|●'; then info "PR #$pr: checks pending"; return 2; fi
  info "PR #$pr: checks green"; return 0
}
