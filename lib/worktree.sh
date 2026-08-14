# worktree.sh — treehouse lease/return + feature branch. Sourced, not executed.
# shellcheck shell=bash

_slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-' | cut -c1-40; }

# _nested_repos <root> -> prints immediate subdirs that are their OWN git repo
# (have a .git and aren't a registered submodule), one per line. These signal a
# "thin container": an outer repo (usually just AGENTS.md/CLAUDE.md) wrapping the
# real project in a subdirectory with its own remote.
_nested_repos() {
  local root="$1" subs="" sub name p is_sub
  if [ -f "$root/.gitmodules" ]; then
    # submodule paths are legitimate nested .git — exclude them. sed (not awk) per
    # AGENTS.md so it parses the same on CI's mawk.
    subs="$(git -C "$root" config --file "$root/.gitmodules" --get-regexp 'submodule\..*\.path$' 2>/dev/null | sed 's/^[^ ]* //')" || subs=""
  fi
  for sub in "$root"/*/; do
    [ -d "$sub" ] || continue          # no non-hidden subdirs -> glob stays literal
    sub="${sub%/}"
    [ -e "$sub/.git" ] || continue     # .git dir (normal repo) or file (gitlink)
    name="$(basename "$sub")"
    is_sub=0
    if [ -n "$subs" ]; then
      while IFS= read -r p; do [ "$name" = "$p" ] && { is_sub=1; break; }; done <<EOF
$subs
EOF
    fi
    [ "$is_sub" = 1 ] && continue
    printf '%s\n' "$sub"
  done
}

# _assert_not_container <root> -> die (exit 1) if <root> looks like a thin
# container repo. Leasing a container yields a worktree with no source and no
# remote, so the worker can't build or push — fail fast with an actionable fix
# instead of silently leasing the wrong repo. Bypass with CANOPY_ALLOW_CONTAINER=1
# for the rare case where leasing the outer repo is genuinely intended.
_assert_not_container() {
  [ "${CANOPY_ALLOW_CONTAINER:-0}" = 1 ] && return 0
  local root="$1" nested first
  nested="$(_nested_repos "$root")" || nested=""
  [ -n "$nested" ] || return 0
  first="$(printf '%s\n' "$nested" | head -1)"
  die "$(printf '%s\n' \
    "this looks like a container repo — the real project lives in a nested git repo: $first" \
    "treehouse would lease the empty outer repo, giving a worktree with no source or remote." \
    "Fix: run canopy from the real sub-repo instead, e.g." \
    "  cd \"$first\" && canopy init && canopy ..." \
    "or set CANOPY_ALLOW_CONTAINER=1 to lease this outer repo anyway.")"
}

# _assert_deps_merged <id> — the contract-first gate. Refuse to lease a worktree for
# a task whose depends_on targets haven't landed on the base branch yet, so the two
# sides of a shared boundary can't be built against a contract that isn't there. The
# authoritative enforcement (the orchestrator LLM is told to skip such tasks, but a
# bash gate is what actually guarantees it). No deps → no-op.
_assert_deps_merged() {
  local id="$1" tf dep deps unmet=""
  tf="$(task_file "$id")"
  deps="$(jq -r '(.depends_on // [])[]' "$tf" 2>/dev/null)" || deps=""
  [ -n "$deps" ] || return 0
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    _dep_satisfied "$dep" || unmet="$unmet $dep"
  done <<< "$deps"
  [ -n "$unmet" ] && die "task $id is blocked: dependency not merged yet —${unmet}. Wait for those PRs to merge (see 'canopy status'), then lease again. (Contract-first: the dependency defines the shared API this task builds against.)"
  return 0
}

# canopy worktree lease <id> -> prints leased worktree path
canopy_worktree_lease() {
  require_canopy; need treehouse; need git
  local id="${1:?task id}"; _assert_task "$id"; _assert_deps_merged "$id"
  local tf title branch path
  tf="$(task_file "$id")"
  title="$(jq -r '.title' "$tf")"
  branch="rhyu/${id}-$(_slug "$title")"

  # Refuse to lease a thin container repo (real project nested in a subdir) —
  # treehouse would hand back a worktree with no source or remote (see t17).
  _assert_not_container "$(repo_root)"

  path="$(treehouse get --lease --lease-holder "canopy-$id" 2>/dev/null)" \
    || die "treehouse lease failed"
  [ -d "$path" ] || die "treehouse returned a bad path: $path"

  # Cut the feature branch from a FRESH copy of the base branch (configured via
  # `canopy base`, else the detected default). The leased worktree starts at the
  # pool's HEAD, which can be stale — anchoring to origin/<base> is what fixes
  # "cut from an outdated main / wrong branch". Fall back to the local base, then
  # to the pool HEAD (offline / no remote), so it always produces a branch.
  local base; base="$(base_branch "$path")"
  if git -C "$path" fetch -q origin "$base" 2>/dev/null; then
    git -C "$path" checkout -q -B "$branch" FETCH_HEAD || die "could not create branch $branch from origin/$base"
    task_log "$id" "branch $branch cut from fresh origin/$base"
  elif git -C "$path" show-ref --verify --quiet "refs/heads/$base"; then
    git -C "$path" checkout -q -B "$branch" "$base" || die "could not create branch $branch from $base"
    task_log "$id" "branch $branch cut from local $base (origin fetch unavailable)"
  else
    git -C "$path" checkout -q -B "$branch" || die "could not create branch $branch in $path"
    task_log "$id" "branch $branch cut from pool HEAD (base '$base' not found)"
  fi

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
