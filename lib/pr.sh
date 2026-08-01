# pr.sh — open PRs via gh-axi + gate on CI. Sourced, not executed.
# shellcheck shell=bash

_pr_body() {
  local id="$1" wt="$2" base="$3" tf title brief stat
  tf="$(task_file "$id")"
  title="$(jq -r '.title' "$tf")"
  brief="$(jq -r '.brief // ""' "$tf")"
  stat="$(git -C "$wt" diff --stat "$base"..HEAD | sed 's/^/    /')"
  cat <<EOF
## Summary
$title

## What & why
${brief:-_(no extra brief)_}

## Files changed
$stat

## Testing
Deterministic checks (test / lint / typecheck / build) were run by the worker; one independent diff-only review passed. CI must be green to merge.

---
🌳 Opened by Canopy · task \`$id\`
EOF
}

# canopy pr open <id>  -> prints the PR number
canopy_pr_open() {
  require_canopy; need gh-axi; need git; need jq
  local id="${1:?task id}"; _assert_task "$id"
  local tf wt branch base title body out prnum
  tf="$(task_file "$id")"
  wt="$(jq -r '.worktree // empty' "$tf")"; [ -d "$wt" ] || die "task $id has no worktree"
  branch="$(jq -r '.branch // empty' "$tf")"; [ -n "$branch" ] || die "task $id has no branch"
  base="$(_default_branch "$wt")"
  title="$(git -C "$wt" log -1 --pretty=%s)"   # conventional subject from the worker

  info "pushing $branch"
  git -C "$wt" push -q -u origin "$branch" 2>&1 | tail -1 || die "push failed for $branch"

  body="$(_pr_body "$id" "$wt" "$base")"
  out="$( cd "$wt" && gh-axi pr create --title "$title" --body "$body" --base "$base" --head "$branch" 2>&1 )"
  prnum="$(printf '%s' "$out" | grep -oE '/pull/[0-9]+|#[0-9]+' | grep -oE '[0-9]+' | head -1)"
  if [ -z "$prnum" ]; then warn "could not parse PR number from gh-axi output:"; printf '%s\n' "$out" >&2; die "pr create may have failed"; fi

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
