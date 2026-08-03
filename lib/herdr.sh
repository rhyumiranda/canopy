# herdr.sh - interactive Herdr worker tabs. Sourced, not executed.
# shellcheck shell=bash

_herdr_need() { need herdr; }
_herdr_state_file() { printf '%s/herdr.json\n' "$(canopy_dir)"; }

_herdr_json_value() {
  local value="${1:-}"
  printf '%s\n' "$value" | jq -r 'if type == "object" then (.id // .workspace_id // .tab_id // .pane_id // .agent_session_id // empty) else . end' 2>/dev/null || true
}

_herdr_workspace() {
  local sf ws
  sf="$(_herdr_state_file)"
  ws="$(jq -r '.workspace_id // empty' "$sf" 2>/dev/null || true)"
  if [ -n "$ws" ]; then
    printf '%s\n' "$ws"
    return 0
  fi
  ws="$(_herdr_json_value "$(herdr workspace create --cwd "$(repo_root)" --label "canopy: $(basename "$(repo_root)")" --no-focus)")"
  [ -n "$ws" ] || die "Herdr did not return a workspace id"
  mkdir -p "$(canopy_dir)"
  jq -n --arg id "$ws" --arg now "$(_c_ts)" '{workspace_id:$id,created:$now}' | write_atomic "$sf"
  printf '%s\n' "$ws"
}

_herdr_task_ids() {
  local id="$1"
  jq -r '[.herdr_tab_id,.herdr_pane_id,.herdr_agent_session_id] | map(select(. != null and . != "")) | @tsv' "$(task_file "$id")"
}

_herdr_report() {
  local id="$1" state="$2" message="${3:-}" pane
  pane="$(jq -r '.herdr_pane_id // empty' "$(task_file "$id")")"
  [ -n "$pane" ] || return 0
  herdr pane report-agent "$pane" --source "canopy:$id" --agent "canopy-$id" \
    --state "$state" ${message:+--message "$message"} >/dev/null 2>&1 || true
}

_herdr_start() {
  require_canopy; need jq; _herdr_need
  local id="${1:?task id}" agent="${2:-$(canopy_task_agent "$1")}" tf path title brief ws tab pane sid out
  _assert_task "$id"
  tf="$(task_file "$id")"
  path="$(jq -r '.worktree // empty' "$tf")"
  [ -d "$path" ] || die "task $id has no leased worktree"
  tab="$(jq -r '.herdr_tab_id // empty' "$tf")"
  pane="$(jq -r '.herdr_pane_id // empty' "$tf")"
  if [ -n "$tab" ] && [ -n "$pane" ]; then
    task_log "$id" "Herdr worker already exists (tab $tab, pane $pane)"
    _herdr_report "$id" working "reused existing Herdr worker"
    printf '%s\n' "$pane"
    return 0
  fi
  ws="$(_herdr_workspace)"
  title="$(jq -r '.title' "$tf")"; brief="$(jq -r '.brief // ""' "$tf")"
  tab="$(_herdr_json_value "$(herdr tab create --workspace "$ws" --cwd "$path" --label "canopy:$id $title" --no-focus)")"
  [ -n "$tab" ] || die "Herdr did not return a tab id"
  task_set "$id" herdr_workspace_id "$ws" >/dev/null
  task_set "$id" herdr_tab_id "$tab" >/dev/null
  out="$(herdr agent start "$agent" --cwd "$path" --tab "$tab" --no-focus -- "$agent" 2>&1)" || {
    herdr tab close "$tab" >/dev/null 2>&1 || true
    die "could not start $agent in Herdr"
  }
  pane="$(_herdr_json_value "$out")"
  [ -n "$pane" ] || pane="$(printf '%s\n' "$out" | sed -n 's/.*pane[^A-Za-z0-9_-]*\([A-Za-z0-9_-][A-Za-z0-9_-]*\).*/\1/p' | head -1)"
  [ -n "$pane" ] || die "Herdr did not return a pane id"
  sid="$(printf '%s\n' "$out" | jq -r '.agent_session_id // .session_id // empty' 2>/dev/null || true)"
  task_set "$id" herdr_pane_id "$pane" >/dev/null
  [ -n "$sid" ] && task_set "$id" herdr_agent_session_id "$sid" >/dev/null
  task_set "$id" agent "$agent" >/dev/null
  [ -n "$brief" ] && herdr agent send "$pane" "$brief" >/dev/null 2>&1 || true
  task_status "$id" implementing >/dev/null
  task_log "$id" "started interactive $agent worker in Herdr workspace $ws, tab $tab, pane $pane"
  _herdr_report "$id" working "interactive worker started"
  printf '%s\n' "$pane"
}

canopy_worker_start() {
  local agent="" id=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --agent) shift; agent="$(_worker_agent_flag "${1:-}")" ;;
      -h|--help) printf '%s\n' 'usage: canopy worker start [--agent claude|codex] <id>'; return 0 ;;
      *) id="$1"; break ;;
    esac
    shift
  done
  [ -n "$id" ] || die 'usage: canopy worker start [--agent claude|codex] <id>'
  _herdr_start "$id" "${agent:-$(canopy_task_agent "$id")}"
}

canopy_worker_attach() {
  require_canopy; need jq; _herdr_need
  local id="${1:?task id}" target; _assert_task "$id"
  target="$(jq -r '.herdr_pane_id // .herdr_tab_id // empty' "$(task_file "$id")")"
  [ -n "$target" ] || die "task $id has no Herdr worker"
  herdr agent attach "$target" --takeover
}

canopy_worker_send() {
  require_canopy; need jq; _herdr_need
  local id="${1:?task id}" text="${*:2}" pane; _assert_task "$id"
  [ -n "$text" ] || die 'usage: canopy worker send <id> <text>'
  pane="$(jq -r '.herdr_pane_id // empty' "$(task_file "$id")")"
  [ -n "$pane" ] || die "task $id has no Herdr worker"
  herdr agent send "$pane" "$text"
  task_log "$id" "sent message to Herdr pane $pane"
}

canopy_worker_status() {
  require_canopy; need jq; _herdr_need
  local id="${1:?task id}" pane; _assert_task "$id"
  pane="$(jq -r '.herdr_pane_id // empty' "$(task_file "$id")")"
  [ -n "$pane" ] || die "task $id has no Herdr worker"
  herdr agent explain "$pane" --json 2>/dev/null || herdr pane read "$pane" --lines 20
}

canopy_worker_stop() {
  local ref="${1:?worker id or session}"
  if [ -f "$(task_file "$ref" 2>/dev/null)" ] && jq -e '.herdr_pane_id' "$(task_file "$ref")" >/dev/null 2>&1; then
    local pane; pane="$(jq -r '.herdr_pane_id' "$(task_file "$ref")")"
    _herdr_need; herdr pane send-keys "$pane" CTRL-C >/dev/null 2>&1 || true
    _herdr_report "$ref" idle "interactive worker stopped"
    task_log "$ref" "stopped Herdr worker pane $pane"
    return 0
  fi
  _canopy_worker_stop_headless "$@"
}

canopy_worker_resume() {
  local id="${1:?task id}"; _assert_task "$id"
  _herdr_start "$id" "$(canopy_task_agent "$id")"
  _herdr_report "$id" working "interactive worker resumed"
}

canopy_worker_close() {
  require_canopy; need jq; _herdr_need
  local id="${1:?task id}" tf pane tab checkpoint path; _assert_task "$id"; tf="$(task_file "$id")"
  checkpoint="$(jq -r '.checkpoint.note // empty' "$tf")"
  case "$checkpoint" in ready_for_review|*ready_for_review*) ;; *) die "task $id is not ready_for_review" ;; esac
  path="$(jq -r '.worktree // empty' "$tf")"
  ( cd "$path" && canopy_checks_run ) || die "task $id checks failed"
  pane="$(jq -r '.herdr_pane_id // empty' "$tf")"; tab="$(jq -r '.herdr_tab_id // empty' "$tf")"
  [ -n "$pane" ] && herdr pane close "$pane" >/dev/null 2>&1 || true
  [ -n "$tab" ] && herdr tab close "$tab" >/dev/null 2>&1 || true
  task_status "$id" done >/dev/null
  task_log "$id" "closed Herdr worker after ready_for_review and passing checks"
}

_canopy_worker_stop_headless() {
  local ref="$1" sid id agent pid
  require_canopy; need jq
  sid="$ref"; id=""
  if [ -f "$(task_file "$ref" 2>/dev/null)" ]; then id="$ref"; else id="$(_find_task_by_worker_session "$ref" || true)"; fi
  [ -n "$id" ] && sid="$(jq -r '.worker_session // empty' "$(task_file "$id")")" && pid="$(jq -r '.worker_pid // empty' "$(task_file "$id")")" && agent="$(canopy_task_agent "$id")"
  [ -n "$sid" ] || return 0
  if [ "${agent:-claude}" = codex ]; then
    [ -n "${pid:-}" ] && kill "$pid" >/dev/null 2>&1 || true
  else
    need claude; claude stop "$sid" >/dev/null 2>&1 || true
  fi
}
