# worktree.sh — treehouse lease/return + feature branch. Sourced, not executed.
# shellcheck shell=bash

_slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-' | cut -c1-40; }

# canopy worktree lease <id> -> prints leased worktree path
canopy_worktree_lease() {
  require_canopy; need treehouse; need git
  local id="${1:?task id}"; _assert_task "$id"
  local tf title branch path
  tf="$(task_file "$id")"
  title="$(jq -r '.title' "$tf")"
  branch="rhyu/${id}-$(_slug "$title")"

  path="$(treehouse get --lease --lease-holder "canopy-$id" 2>/dev/null)" \
    || die "treehouse lease failed"
  [ -d "$path" ] || die "treehouse returned a bad path: $path"

  # leased worktree starts at detached HEAD; put it on a feature branch
  git -C "$path" checkout -q -B "$branch" || die "could not create branch $branch in $path"

  task_set "$id" worktree "$path" >/dev/null
  task_set "$id" branch "$branch" >/dev/null
  task_log "$id" "leased $path on $branch"
  info "leased $path ($branch)"
  printf '%s\n' "$path"
}

# canopy worktree return <id>
canopy_worktree_return() {
  require_canopy; need treehouse
  local id="${1:?task id}"; _assert_task "$id"
  local path; path="$(jq -r '.worktree // empty' "$(task_file "$id")")"
  [ -n "$path" ] || die "task $id has no leased worktree"
  if treehouse return "$path" >/dev/null 2>&1; then
    task_log "$id" "returned $path"
    info "returned $path"
  else
    warn "treehouse return had an issue (uncommitted changes?) — leaving lease in place"
    return 1
  fi
}

# canopy worktree path <id>  -> prints the leased path (for scripts)
canopy_worktree_path() {
  require_canopy
  local id="${1:?task id}"; _assert_task "$id"
  jq -r '.worktree // empty' "$(task_file "$id")"
}
