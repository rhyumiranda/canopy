# herdr.sh - interactive Herdr worker tabs. Sourced, not executed.
# shellcheck shell=bash

_herdr_bin() { printf '%s\n' "${CANOPY_HERDR_BIN:-herdr}"; }
_herdr_need() { need "$(basename "$(_herdr_bin)")"; }
_herdr_state_file() { printf '%s/herdr.json\n' "$(canopy_dir)"; }
_herdr_agent_label() { printf 'canopy-%s-%s\n' "$1" "$2"; }
_herdr_tab_label() {
  local backend
  backend="$(_canopy_agent_validate "$2")"
  [ "$backend" = claude ] && backend=Claude || backend=Codex
  printf '%s · %s\n' "$1" "$backend"
}

_herdr_json_id() {
  jq -r 'if type == "object" then (.id // .workspace_id // .tab_id // .pane_id // .agent_session_id // .session_id // empty) else . end' 2>/dev/null || true
}

_herdr_context_workspace() {
  local out ws
  out="$($(_herdr_bin) pane current --current 2>/dev/null || true)"
  ws="$(printf '%s\n' "$out" | jq -r '.workspace_id // .workspace.id // .tab.workspace_id // .tab.workspace.id // empty' 2>/dev/null || true)"
  [ -n "$ws" ] && printf '%s\n' "$ws"
}

_herdr_workspace() {
  local explicit="${1:-}" sf ws
  sf="$(_herdr_state_file)"
  ws="$explicit"
  [ -n "$ws" ] || ws="${CANOPY_HERDR_WORKSPACE:-}"
  [ -n "$ws" ] || ws="$(jq -r '.workspace_id // empty' "$sf" 2>/dev/null || true)"
  if [ -n "$ws" ] && "$(_herdr_bin)" workspace get "$ws" >/dev/null 2>&1; then
    printf '%s\n' "$ws"; return 0
  fi
  [ -z "$explicit" ] || die "Herdr workspace not found: $explicit"
  ws="$(_herdr_context_workspace)"
  [ -n "$ws" ] || die "no existing Herdr workspace context; pass --workspace <workspace-id>"
  "$(_herdr_bin)" workspace get "$ws" >/dev/null 2>&1 || die "Herdr workspace not found: $ws"
  mkdir -p "$(canopy_dir)"
  jq -n --arg id "$ws" --arg now "$(_c_ts)" '{workspace_id:$id,created:$now}' | write_atomic "$sf"
  printf '%s\n' "$ws"
}

_herdr_id_alive() {
  local kind="$1" id="$2"
  [ -n "$id" ] && "$(_herdr_bin)" "$kind" get "$id" >/dev/null 2>&1
}

_herdr_find_tab() {
  local ws="$1" label="$2"
  "$(_herdr_bin)" tab list --workspace "$ws" 2>/dev/null \
    | jq -r --arg label "$label" '.. | objects | select((.label // .name // "") == $label) | (.id // .tab_id // empty)' 2>/dev/null \
    | head -1
}

_herdr_find_pane() {
  local ws="$1" label="$2"
  "$(_herdr_bin)" pane list --workspace "$ws" 2>/dev/null \
    | jq -r --arg label "$label" '.. | objects | select((.label // .name // .agent // "") == $label) | (.id // .pane_id // empty)' 2>/dev/null \
    | head -1
}

_herdr_report() {
  local id="$1" state="$2" message="${3:-}" tf pane agent sid label
  tf="$(task_file "$id")"
  pane="$(jq -r '.herdr_pane_id // empty' "$tf" 2>/dev/null || true)"
  [ -n "$pane" ] || return 0
  agent="$(canopy_task_agent "$id")"
  sid="$(jq -r '.herdr_agent_session_id // empty' "$tf" 2>/dev/null || true)"
  label="$(_herdr_agent_label "$id" "$agent")"
  # Older Herdr versions have no status hook; lifecycle must still work there.
  "$(_herdr_bin)" pane report-agent "$pane" --source "canopy:$id" --agent "$label" \
    --state "$state" ${message:+--message "$message"} ${sid:+--agent-session-id "$sid"} \
    >/dev/null 2>&1 || true
}

_herdr_launch_claude() {
  local id="$1" path="$2" tab="$3" prompt="$4"
  "$(_herdr_bin)" agent start claude --cwd "$path" --tab "$tab" --no-focus -- \
    claude --dangerously-skip-permissions --append-system-prompt "$(_agent_body worker)" "$prompt"
}

_herdr_launch_codex() {
  local id="$1" path="$2" tab="$3" prompt="$4"
  printf '%s' "$prompt" | "$(_herdr_bin)" agent start codex --cwd "$path" --tab "$tab" --no-focus -- \
    codex -s "${CANOPY_CODEX_SANDBOX:-workspace-write}" -a "${CANOPY_CODEX_APPROVAL:-never}" \
    -C "$path" exec --json -
}

_herdr_launch() {
  local agent="$1"; shift
  case "$agent" in
    claude) _herdr_launch_claude "$@" ;;
    codex)  _herdr_launch_codex "$@" ;;
    *) die "unknown agent runtime: $agent (use claude or codex)" ;;
  esac
}

_herdr_start() {
  require_canopy; need jq; _herdr_need
  local id="${1:?task id}" agent="${2:-$(canopy_task_agent "$1")}" explicit_ws="${3:-}" tf path title brief ws tab pane sid out label alabel stored_agent reuse_persisted
  _assert_task "$id"; agent="$(_canopy_agent_validate "$agent")"; tf="$(task_file "$id")"
  path="$(jq -r '.worktree // empty' "$tf")"
  [ -d "$path" ] || die "task $id has no leased worktree"
  title="$(jq -r '.title' "$tf")"; brief="$(jq -r '.brief // ""' "$tf")"
  label="$(_herdr_tab_label "$id" "$agent")"; alabel="$(_herdr_agent_label "$id" "$agent")"
  stored_agent="$(jq -r '.agent // empty' "$tf" 2>/dev/null || true)"
  reuse_persisted=1
  [ -z "$stored_agent" ] || [ "$stored_agent" = "$agent" ] || reuse_persisted=0
  ws="$(_herdr_workspace "$explicit_ws")"
  tab=""
  if [ "$reuse_persisted" = 1 ]; then
    tab="$(jq -r '.herdr_tab_id // empty' "$tf" 2>/dev/null || true)"
    _herdr_id_alive tab "$tab" || tab=""
  fi
  [ -n "$tab" ] || tab="$(_herdr_find_tab "$ws" "$label")"
  if [ -z "$tab" ]; then
    tab="$($(_herdr_bin) tab create --workspace "$ws" --cwd "$path" --label "$label" --no-focus 2>/dev/null | _herdr_json_id)"
    [ -n "$tab" ] || die "Herdr did not return a tab id"
  fi
  task_set "$id" herdr_workspace_id "$ws" >/dev/null
  task_set "$id" herdr_tab_id "$tab" >/dev/null
  pane=""
  if [ "$reuse_persisted" = 1 ]; then
    pane="$(jq -r '.herdr_pane_id // empty' "$tf" 2>/dev/null || true)"
    _herdr_id_alive pane "$pane" || pane=""
  fi
  [ -n "$pane" ] || pane="$(_herdr_find_pane "$ws" "$alabel")"
  if [ -n "$pane" ]; then
    task_set "$id" herdr_pane_id "$pane" >/dev/null
    task_status "$id" implementing >/dev/null
    _herdr_report "$id" working "reused existing Herdr worker"
    printf '%s\n' "$pane"; return 0
  fi
  prompt="$(_worker_prompt "$id" "$title" "$brief")"
  out="$(_herdr_launch "$agent" "$id" "$path" "$tab" "$prompt" 2>&1)" || {
    die "could not start $agent in Herdr"
  }
  pane="$(printf '%s\n' "$out" | _herdr_json_id | head -1)"
  [ -n "$pane" ] || die "Herdr did not return a pane id"
  sid="$(printf '%s\n' "$out" | jq -r '.agent_session_id // .session_id // .thread_id // empty' 2>/dev/null || true)"
  task_set "$id" agent "$agent" >/dev/null
  task_set "$id" herdr_workspace_id "$ws" >/dev/null
  task_set "$id" herdr_tab_id "$tab" >/dev/null
  task_set "$id" herdr_pane_id "$pane" >/dev/null
  [ -n "$sid" ] && task_set "$id" herdr_agent_session_id "$sid" >/dev/null
  task_status "$id" implementing >/dev/null
  task_log "$id" "started interactive $agent worker in Herdr workspace $ws, tab $tab, pane $pane"
  _herdr_report "$id" working "interactive worker started"
  printf '%s\n' "$pane"
}

canopy_worker_start() {
  local agent="" id="" workspace=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --agent) shift; agent="$(_worker_agent_flag "${1:-}")" ;;
      --workspace) shift; workspace="${1:-}"; [ -n "$workspace" ] || die '--workspace needs a workspace id' ;;
      -h|--help) printf '%s\n' 'usage: canopy worker start [--agent claude|codex] [--workspace <id>] <id>'; return 0 ;;
      -*) die "unknown worker start option: $1" ;;
      *) id="$1"; shift; [ "$#" -eq 0 ] || die 'usage: canopy worker start [--agent claude|codex] <id>'; break ;;
    esac
    shift
  done
  [ -n "$id" ] || die 'usage: canopy worker start [--agent claude|codex] [--workspace <id>] <id>'
  _herdr_start "$id" "${agent:-$(canopy_task_agent "$id")}" "$workspace"
}

canopy_worker_attach() {
  require_canopy; need jq; _herdr_need
  local id="${1:?task id}" target; _assert_task "$id"
  target="$(jq -r '.herdr_pane_id // .herdr_tab_id // empty' "$(task_file "$id")")"
  [ -n "$target" ] || die "task $id has no Herdr worker"
  "$(_herdr_bin)" agent attach "$target" --takeover
}

canopy_worker_send() {
  require_canopy; need jq; _herdr_need
  local id="${1:?task id}" text="${*:2}" pane; _assert_task "$id"
  [ -n "$text" ] || die 'usage: canopy worker send <id> <text>'
  pane="$(jq -r '.herdr_pane_id // empty' "$(task_file "$id")")"
  [ -n "$pane" ] || die "task $id has no Herdr worker"
  "$(_herdr_bin)" agent send "$pane" "$text"
  task_log "$id" "sent message to Herdr pane $pane"
}

canopy_worker_status() {
  require_canopy; need jq; _herdr_need
  local id="${1:?task id}" pane; _assert_task "$id"
  pane="$(jq -r '.herdr_pane_id // empty' "$(task_file "$id")")"
  [ -n "$pane" ] || die "task $id has no Herdr worker"
  "$(_herdr_bin)" agent explain "$pane" --json 2>/dev/null || "$(_herdr_bin)" agent read "$pane" --lines 20
}

canopy_worker_stop() {
  local ref="${1:?worker id or session}" tf pane
  tf="$(task_file "$ref" 2>/dev/null || true)"
  if [ -f "$tf" ] && pane="$(jq -r '.herdr_pane_id // empty' "$tf" 2>/dev/null || true)" && [ -n "$pane" ]; then
    _herdr_need
    "$(_herdr_bin)" pane send-keys "$pane" CTRL-C >/dev/null 2>&1 || true
    _herdr_report "$ref" idle "interactive worker stopped"
    task_log "$ref" "stopped Herdr worker pane $pane"
    return 0
  fi
  _canopy_worker_stop_headless "$@"
}

_canopy_worker_stop_headless() {
  local ref="$1" sid="$ref" id="" agent="" pid=""
  require_canopy; need jq
  if [ -f "$(task_file "$ref" 2>/dev/null)" ]; then id="$ref"; else id="$(_find_task_by_worker_session "$ref" || true)"; fi
  if [ -n "$id" ]; then
    sid="$(jq -r '.worker_session // empty' "$(task_file "$id")")"
    pid="$(jq -r '.worker_pid // empty' "$(task_file "$id")")"
    agent="$(canopy_task_agent "$id")"
  fi
  [ -n "$sid" ] || return 0
  if [ "$agent" = codex ]; then
    [ -n "$pid" ] && kill "$pid" >/dev/null 2>&1 || true
  else
    need claude; claude stop "$sid" >/dev/null 2>&1 || true
  fi
}

canopy_worker_resume() {
  local id="" workspace=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --workspace) shift; workspace="${1:-}"; [ -n "$workspace" ] || die '--workspace needs a workspace id' ;;
      -h|--help) printf '%s\n' 'usage: canopy worker resume [--workspace <id>] <id>'; return 0 ;;
      -*) die "unknown worker resume option: $1" ;;
      *) id="$1"; shift; [ "$#" -eq 0 ] || die 'usage: canopy worker resume [--workspace <id>] <id>'; break ;;
    esac
    shift
  done
  [ -n "$id" ] || die 'usage: canopy worker resume [--workspace <id>] <id>'
  _assert_task "$id"
  _herdr_start "$id" "$(canopy_task_agent "$id")" "$workspace"
  _herdr_report "$id" working "interactive worker resumed"
}

canopy_worker_close() {
  require_canopy; need jq; _herdr_need
  local id="${1:?task id}" tf checkpoint path pane tab; _assert_task "$id"; tf="$(task_file "$id")"
  checkpoint="$(jq -r '.checkpoint.note // empty' "$tf")"
  [ "$checkpoint" = ready_for_review ] || die "task $id is not ready_for_review"
  path="$(jq -r '.worktree // empty' "$tf")"
  [ -d "$path" ] || die "task $id has no leased worktree"
  ( cd "$path" && canopy_checks_run ) || die "task $id checks failed"
  pane="$(jq -r '.herdr_pane_id // empty' "$tf")"; tab="$(jq -r '.herdr_tab_id // empty' "$tf")"
  [ -n "$pane" ] && "$(_herdr_bin)" pane close "$pane" >/dev/null 2>&1 || true
  [ -n "$tab" ] && "$(_herdr_bin)" tab close "$tab" >/dev/null 2>&1 || true
  task_status "$id" done >/dev/null
  task_log "$id" "closed Herdr worker after ready_for_review and passing checks"
}
