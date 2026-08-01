# worker.sh — spawn/observe claude --bg workers. Sourced, not executed.
# shellcheck shell=bash

# strip a Claude Code agent def's frontmatter -> system-prompt body
_agent_body() { awk 'p; /^---$/{n++; if(n==2) p=1}' "$CANOPY_ROOT/agents/$1.md"; }

# parse the session id out of `claude --bg` output (strip ANSI, anchor on "backgrounded")
_parse_bg_id() {
  sed $'s/\x1b\\[[0-9;]*m//g' \
    | awk '/backgrounded/{for(i=1;i<=NF;i++) if($i ~ /^[0-9a-f]{6,}$/){print $i; exit}}'
}

_worker_prompt() {
  local id="$1" title="$2" brief="$3"
  cat <<EOF
Task ${id}: ${title}

${brief:-（no extra brief; implement the title.）}

Follow your worker instructions: implement → document the change in the same diff → run the deterministic checks yourself → commit on the current feature branch. When done, report a tight summary + the branch name + check results. Do not create a new worktree.
EOF
}

# canopy worker spawn <id> -> prints the worker session id
canopy_worker_spawn() {
  require_canopy; need claude; need jq
  local id="${1:?task id}"; _assert_task "$id"
  local tf path title brief sid
  tf="$(task_file "$id")"
  path="$(jq -r '.worktree // empty' "$tf")"
  [ -n "$path" ] || die "task $id not leased — run 'canopy worktree lease $id' first"
  [ -d "$path" ] || die "leased worktree missing: $path"
  title="$(jq -r '.title' "$tf")"
  brief="$(jq -r '.brief // ""' "$tf")"

  # detached bg worker; cwd = leased worktree; NO -w (ground rule)
  sid="$( cd "$path" && claude --bg --dangerously-skip-permissions \
            --append-system-prompt "$(_agent_body worker)" \
            "$(_worker_prompt "$id" "$title" "$brief")" 2>&1 | _parse_bg_id )"
  [ -n "$sid" ] || die "could not read worker session id from claude --bg"

  task_set "$id" worker_session "$sid" >/dev/null
  task_status "$id" implementing >/dev/null
  task_log "$id" "spawned worker $sid in $path"
  info "worker $sid spawned for $id"
  printf '%s\n' "$sid"
}

# canopy worker fix <id> <issues-json-or-text>  -> spawns a fresh worker in the same
# worktree to address review issues, then prints its session id.
canopy_worker_fix() {
  require_canopy; need claude; need jq
  local id="${1:?task id}"; shift; local issues="${*:?issues}"
  _assert_task "$id"
  local path sid; path="$(jq -r '.worktree // empty' "$(task_file "$id")")"
  [ -d "$path" ] || die "task $id has no worktree"
  local prompt
  prompt="The independent review found issues with your change. Fix EXACTLY these, then re-run the deterministic checks and commit again on the current branch. Do not expand scope.

Issues:
${issues}"
  sid="$( cd "$path" && claude --bg --dangerously-skip-permissions \
            --append-system-prompt "$(_agent_body worker)" "$prompt" 2>&1 | _parse_bg_id )"
  [ -n "$sid" ] || die "could not read fix-worker session id"
  task_set "$id" worker_session "$sid" >/dev/null
  task_status "$id" implementing >/dev/null
  task_log "$id" "spawned fix worker $sid"
  info "fix worker $sid spawned for $id"
  printf '%s\n' "$sid"
}

# canopy worker logs <id|sid>  (best-effort tail)
canopy_worker_logs() {
  need claude
  local ref="${1:?worker id or session}"
  local sid="$ref"
  if [ -f "$(task_file "$ref" 2>/dev/null)" ]; then
    sid="$(jq -r '.worker_session // empty' "$(task_file "$ref")")"
  fi
  [ -n "$sid" ] || die "no worker session for $ref"
  claude logs "$sid" 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g' | tail -30
}

# canopy worker stop <id|sid>
canopy_worker_stop() {
  need claude
  local ref="${1:?worker id or session}" sid="$ref"
  if [ -f "$(task_file "$ref" 2>/dev/null)" ]; then
    sid="$(jq -r '.worker_session // empty' "$(task_file "$ref")")"
  fi
  [ -n "$sid" ] && claude stop "$sid" >/dev/null 2>&1 || true
}
