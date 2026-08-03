# agent.sh — shared agent-runtime helpers. Sourced, not executed.
# shellcheck shell=bash

# strip an agent def's frontmatter -> system-prompt body
_agent_body() { awk 'p; /^---$/{n++; if(n==2) p=1}' "$CANOPY_ROOT/agents/$1.md"; }

_canopy_agent_validate() {
  case "${1:-}" in
    claude|codex) printf '%s\n' "$1" ;;
    *) die "unknown agent runtime: ${1:-<none>} (use claude or codex)" ;;
  esac
}

canopy_agent_default() {
  _canopy_agent_validate "${CANOPY_AGENT:-claude}"
}

canopy_task_agent() {
  local id="${1:?task id}" tf v
  tf="$(task_file "$id")"
  [ -f "$tf" ] || die "no such task: $id"
  v="$(jq -r '.agent // empty' "$tf" 2>/dev/null || true)"
  if [ -n "$v" ] && [ "$v" != "null" ]; then
    _canopy_agent_validate "$v"
  else
    canopy_agent_default
  fi
}

canopy_logs_dir() { echo "$(canopy_dir)/logs"; }

_codex_bypass_flag() {
  printf '%s\n' "${CANOPY_CODEX_BYPASS_FLAG:---dangerously-bypass-approvals-and-sandbox}"
}

_codex_has_bypass_arg() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --dangerously-bypass-approvals-and-sandbox|--yolo) return 0 ;;
    esac
  done
  return 1
}

_find_task_by_worker_session() {
  local sid="${1:?session id}"
  [ -f "$(state_file)" ] || return 1
  jq -r --arg sid "$sid" '.tasks[]? | select(.worker_session == $sid) | .id' "$(state_file)" 2>/dev/null | head -1
}

_codex_thread_id_from_log() {
  local logf="${1:?log file}"
  [ -f "$logf" ] || return 0
  grep '"type":"thread.started"' "$logf" 2>/dev/null \
    | sed -n '1p' \
    | jq -r '.thread_id // empty' 2>/dev/null
}

_codex_wait_for_thread_id() {
  local logf="${1:?log file}" pid="${2:?pid}" sid="" i
  for i in $(seq 1 120); do
    sid="$(_codex_thread_id_from_log "$logf")"
    [ -n "$sid" ] && { printf '%s\n' "$sid"; return 0; }
    kill -0 "$pid" >/dev/null 2>&1 || break
    sleep 0.25
  done
  sid="$(_codex_thread_id_from_log "$logf")"
  [ -n "$sid" ] && { printf '%s\n' "$sid"; return 0; }
  kill "$pid" >/dev/null 2>&1 || true
  warn "could not read Codex session id from $logf"
  tail -30 "$logf" >&2 2>/dev/null || true
  return 1
}

_task_set_worker_runtime() {
  local id="${1:?task id}" agent="${2:?agent}" sid="${3:-}" pid="${4:-}" logf="${5:-}"
  task_set "$id" agent "$agent" >/dev/null
  task_set "$id" worker_session "$sid" >/dev/null
  task_set "$id" worker_pid "$pid" >/dev/null
  task_set "$id" worker_log "$logf" >/dev/null
}
