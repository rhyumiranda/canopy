# worker.sh — spawn/observe detached workers. Sourced, not executed.
# shellcheck shell=bash

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

_worker_agent_flag() {
  local agent="${1:-}"
  [ -n "$agent" ] && { _canopy_agent_validate "$agent"; return; }
  canopy_agent_default
}

_worker_spawn_claude() {
  local id="${1:?task id}" path="${2:?worktree}" title="${3:?title}" brief="${4:-}" sid
  sid="$( cd "$path" && claude --bg --dangerously-skip-permissions \
            --append-system-prompt "$(_agent_body worker)" \
            "$(_worker_prompt "$id" "$title" "$brief")" 2>&1 | _parse_bg_id )"
  [ -n "$sid" ] || die "could not read worker session id from claude --bg"
  _task_set_worker_runtime "$id" claude "$sid" "" ""
  printf '%s\n' "$sid"
}

_worker_spawn_codex() {
  local id="${1:?task id}" path="${2:?worktree}" title="${3:?title}" brief="${4:-}" mode="${5:-spawn}" resume_sid="${6:-}"
  local prompt pid sid logdir logf lastf
  local -a codex_args
  logdir="$(canopy_logs_dir)"
  mkdir -p "$logdir"
  logf="$logdir/${id}.${mode}.$(date +%s).codex.jsonl"
  lastf="$logdir/${id}.${mode}.last.txt"
  prompt="$(_worker_prompt "$id" "$title" "$brief")"
  if [ "$mode" = fix ]; then
    prompt="$brief"
  fi
  codex_args=(-s "${CANOPY_CODEX_SANDBOX:-workspace-write}" -C "$path")
  _codex_has_bypass_arg "${codex_args[@]+"${codex_args[@]}"}" || codex_args+=("$(_codex_bypass_flag)")

  if [ -n "$resume_sid" ]; then
    (
      set +e
      cd "$path" || exit 1
      child=""
      trap '[ -n "$child" ] && kill "$child" >/dev/null 2>&1 || true; wait "$child" >/dev/null 2>&1 || true; exit 0' TERM INT
      (
        printf '%s' "$prompt" | codex "${codex_args[@]}" \
          exec resume --json -o "$lastf" "$resume_sid" -
      ) &
      child="$!"
      wait "$child"
    ) >"$logf" 2>&1 &
  else
    (
      set +e
      cd "$path" || exit 1
      child=""
      trap '[ -n "$child" ] && kill "$child" >/dev/null 2>&1 || true; wait "$child" >/dev/null 2>&1 || true; exit 0' TERM INT
      (
        printf '%s' "$prompt" | codex "${codex_args[@]}" \
          exec --json -o "$lastf" -
      ) &
      child="$!"
      wait "$child"
    ) >"$logf" 2>&1 &
  fi
  pid="$!"
  sid="$(_codex_wait_for_thread_id "$logf" "$pid")" || die "could not read worker session id from Codex"
  _task_set_worker_runtime "$id" codex "$sid" "$pid" "$logf"
  printf '%s\n' "$sid"
}

# canopy worker spawn <id> -> prints the worker session id
canopy_worker_spawn() {
  require_canopy; need jq
  local agent="" id tf path title brief sid
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --agent) shift; agent="$(_worker_agent_flag "${1:-}")" ;;
      -h|--help)
        cat <<'EOF'
usage: canopy worker spawn [--agent claude|codex] <id>
EOF
        return 0 ;;
      *) id="${1}"; break ;;
    esac
    shift
  done
  id="${id:-${1:-}}"
  [ -n "$id" ] || die "usage: canopy worker spawn [--agent claude|codex] <id>"
  agent="$(_worker_agent_flag "$agent")"
  _assert_task "$id"
  tf="$(task_file "$id")"
  path="$(jq -r '.worktree // empty' "$tf")"
  [ -n "$path" ] || die "task $id not leased — run 'canopy worktree lease $id' first"
  [ -d "$path" ] || die "leased worktree missing: $path"
  title="$(jq -r '.title' "$tf")"
  brief="$(jq -r '.brief // ""' "$tf")"

  case "$agent" in
    claude) need claude; sid="$(_worker_spawn_claude "$id" "$path" "$title" "$brief")" ;;
    codex)  need codex;  sid="$(_worker_spawn_codex "$id" "$path" "$title" "$brief" spawn "")" ;;
  esac
  task_status "$id" implementing >/dev/null
  task_log "$id" "spawned $agent worker $sid in $path"
  info "$agent worker $sid spawned for $id"
  printf '%s\n' "$sid"
}

# canopy worker fix <id> <issues-json-or-text>  -> spawns a fresh worker in the same
# worktree to address review issues, then prints its session id.
canopy_worker_fix() {
  require_canopy; need jq
  local agent="" id issues
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --agent) shift; agent="$(_worker_agent_flag "${1:-}")" ;;
      -h|--help)
        cat <<'EOF'
usage: canopy worker fix [--agent claude|codex] <id> <issues>
EOF
        return 0 ;;
      *) id="${1}"; shift; issues="${*:-}"; break ;;
    esac
    shift
  done
  [ -n "${id:-}" ] || die "usage: canopy worker fix [--agent claude|codex] <id> <issues>"
  [ -n "${issues:-}" ] || die "usage: canopy worker fix [--agent claude|codex] <id> <issues>"
  _assert_task "$id"
  local path sid title resume_sid prompt
  agent="$(_worker_agent_flag "${agent:-$(canopy_task_agent "$id")}")"
  path="$(jq -r '.worktree // empty' "$(task_file "$id")")"
  [ -d "$path" ] || die "task $id has no worktree"
  prompt="The independent review found issues with your change. Fix EXACTLY these, then re-run the deterministic checks and commit again on the current branch. Do not expand scope.

Issues:
${issues}"
  title="$(jq -r '.title' "$(task_file "$id")")"
  case "$agent" in
    claude)
      need claude
      sid="$( cd "$path" && claude --bg --dangerously-skip-permissions \
                --append-system-prompt "$(_agent_body worker)" "$prompt" 2>&1 | _parse_bg_id )"
      [ -n "$sid" ] || die "could not read fix-worker session id"
      _task_set_worker_runtime "$id" claude "$sid" "" ""
      ;;
    codex)
      need codex
      resume_sid="$(jq -r '.worker_session // empty' "$(task_file "$id")")"
      sid="$(_worker_spawn_codex "$id" "$path" "$title" "$prompt" fix "$resume_sid")"
      ;;
  esac
  task_status "$id" implementing >/dev/null
  task_log "$id" "spawned $agent fix worker $sid"
  info "$agent fix worker $sid spawned for $id"
  printf '%s\n' "$sid"
}

# canopy worker logs <id|sid>  (best-effort tail)
canopy_worker_logs() {
  require_canopy; need jq
  local ref="${1:?worker id or session}" sid="$ref" id="" agent="" logf=""
  if [ -f "$(task_file "$ref" 2>/dev/null)" ]; then
    id="$ref"
  else
    id="$(_find_task_by_worker_session "$ref" || true)"
  fi
  if [ -n "$id" ]; then
    sid="$(jq -r '.worker_session // empty' "$(task_file "$id")")"
    agent="$(canopy_task_agent "$id")"
    logf="$(jq -r '.worker_log // empty' "$(task_file "$id")")"
  fi
  [ -n "$sid" ] || die "no worker session for $ref"
  case "${agent:-claude}" in
    claude)
      need claude
      claude logs "$sid" 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g' | tail -30
      ;;
    codex)
      [ -n "$logf" ] && [ -f "$logf" ] || die "no codex log captured for $ref"
      tail -30 "$logf"
      ;;
  esac
}

# canopy worker stop <id|sid>
canopy_worker_stop() {
  require_canopy; need jq
  local ref="${1:?worker id or session}" sid="$ref" id="" agent="" pid=""
  if [ -f "$(task_file "$ref" 2>/dev/null)" ]; then
    id="$ref"
  else
    id="$(_find_task_by_worker_session "$ref" || true)"
  fi
  if [ -n "$id" ]; then
    sid="$(jq -r '.worker_session // empty' "$(task_file "$id")")"
    pid="$(jq -r '.worker_pid // empty' "$(task_file "$id")")"
    agent="$(canopy_task_agent "$id")"
  fi
  [ -n "$sid" ] || return 0
  case "${agent:-claude}" in
    claude)
      need claude
      claude stop "$sid" >/dev/null 2>&1 || true
      ;;
    codex)
      if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
        kill "$pid" >/dev/null 2>&1 || true
        sleep 1
        kill -0 "$pid" >/dev/null 2>&1 && kill -9 "$pid" >/dev/null 2>&1 || true
      fi
      ;;
  esac
}
