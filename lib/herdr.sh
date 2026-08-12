# herdr.sh - interactive Herdr worker tabs. Sourced, not executed.
# shellcheck shell=bash

_herdr_bin() { printf '%s\n' "${CANOPY_HERDR_BIN:-herdr}"; }
_herdr_need() { need "$(basename "$(_herdr_bin)")"; }

# _herdr_agent_submit <pane> <text> — deliver text to a live agent pane AND submit it.
# `herdr agent send` only WRITES the text into the agent's input box (a paste); with
# no following Enter the message sits unsent, silently no-op'ing orchestrator steering
# and causing phantom stalls (multi-line text especially lands as one unsent block).
# The submit is an explicit Enter keystroke: the pty delivers it strictly after the
# paste bytes, so a single Enter submits the whole message. herdr stdout (RPC JSON) is
# routed to stderr so callers' machine-readable stdout stays clean. Verified against a
# live Claude TUI with multi-line text (test/herdr_test.sh: "send submits the message").
_herdr_agent_submit() {
  local pane="$1" text="$2"
  "$(_herdr_bin)" agent send "$pane" "$text" >&2 || return 1
  "$(_herdr_bin)" pane send-keys "$pane" Enter >&2
}
_herdr_state_file() { printf '%s/herdr.json\n' "$(canopy_dir)"; }
_herdr_agent_label() { printf 'canopy-%s-%s\n' "$1" "$2"; }

# _herdr_slug_word <text> — lowercase and strip to [a-z0-9] (drops spaces/punct).
# Kept deliberately tiny and awk-free so it parses identically on macOS bash 3.2
# and CI's mawk-less environment.
_herdr_slug_word() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'; }

# _herdr_agent_name <id> — the unique NAME positional for `herdr agent start`.
# Herdr enforces GLOBAL uniqueness on that positional, so if every worker started
# under the literal backend name ("claude"/"codex") only one claude (and one codex)
# worker could run at a time across ALL workspaces — a second start failed with
# agent_name_taken. Derive a human-readable slug from the task's conventional-commit
# title (type = verb, scope word = noun; e.g. 'fix(herdr): ...' -> cp-fix-herdr) and
# suffix the task id, which is itself unique, so the name is both collision-proof and
# stable across restarts. This is the uniqueness key; _herdr_agent_label stays the
# id+backend display/matching identity (pane relabel + ownership checks).
_herdr_agent_name() {
  local id="$1" title head subject verb noun slug
  title="$(jq -r '.title // empty' "$(task_file "$id")" 2>/dev/null || true)"
  head="${title%%:*}"            # "fix(herdr)"  — the part before the first colon
  subject=""
  [ "$head" = "$title" ] || subject="${title#*: }"   # subject present only when a colon split
  verb="${head%%(*}"; verb="${verb%% *}"             # leading word: the commit type
  if [ "$head" != "${head#*(}" ]; then
    noun="${head#*(}"; noun="${noun%%)*}"            # scope inside the parens
  else
    noun="${subject%% *}"                            # else the first word of the subject
  fi
  verb="$(_herdr_slug_word "$verb")"; noun="$(_herdr_slug_word "$noun")"
  slug="cp"
  [ -z "$verb" ] || slug="$slug-$verb"
  [ -z "$noun" ] || slug="$slug-$noun"
  [ "$slug" = cp ] && slug="cp-worker"
  printf '%s-%s\n' "$slug" "$id"
}
_herdr_tab_label() {
  local backend
  backend="$(_canopy_agent_validate "$2")"
  [ "$backend" = claude ] && backend=Claude || backend=Codex
  printf '%s · %s\n' "$1" "$backend"
}

_herdr_tab_id() {
  # `agent start` (herdr 0.7.3) returns the tab id under .result.agent.tab_id;
  # `tab create` returns it under .result.tab.*. Try both so every response parses.
  jq -r 'if type == "object" then (.result.tab.tab_id // .result.tab.id // .result.tab_id // .result.agent.tab_id // .tab_id // empty) else . end' 2>/dev/null || true
}

_herdr_pane_id() {
  # `agent start` (herdr 0.7.3) returns the pane id under .result.agent.pane_id;
  # `pane split`/other shapes use .result.pane.*. Try both so every response parses.
  jq -r 'if type == "object" then (.result.pane.pane_id // .result.pane.id // .result.pane_id // .result.agent.pane_id // .result.agent.id // .pane_id // empty) else . end' 2>/dev/null || true
}

_herdr_agent_session_id() {
  # `agent start` (herdr 0.7.3) returns the session id under .result.agent.*.
  jq -r 'if type == "object" then (.result.agent_session_id // .result.session_id // .result.thread_id // .result.agent.agent_session_id // .result.agent.session_id // .result.agent.thread_id // .agent_session_id // .session_id // .thread_id // empty) else empty end' 2>/dev/null || true
}

_herdr_context_workspace() {
  local out ws
  out="$($(_herdr_bin) pane current --current 2>/dev/null || true)"
  ws="$(printf '%s\n' "$out" | jq -r '.result.pane.workspace_id // .result.pane.workspace.id // .result.pane.tab.workspace_id // .result.pane.tab.workspace.id // .result.workspace_id // .workspace_id // .workspace.id // .tab.workspace_id // .tab.workspace.id // empty' 2>/dev/null || true)"
  [ -n "$ws" ] && printf '%s\n' "$ws"
}

_herdr_workspace() {
  local explicit="${1:-}" task_ws="${2:-}" sf ws
  sf="$(_herdr_state_file)"
  ws="$explicit"
  if [ -n "$ws" ] && "$(_herdr_bin)" workspace get "$ws" >/dev/null 2>&1; then
    printf '%s\n' "$ws"; return 0
  fi
  [ -z "$explicit" ] || die "Herdr workspace not found: $explicit"
  ws="$task_ws"
  if [ -n "$ws" ] && "$(_herdr_bin)" workspace get "$ws" >/dev/null 2>&1; then
    printf '%s\n' "$ws"; return 0
  fi
  ws="${CANOPY_HERDR_WORKSPACE:-}"
  [ -n "$ws" ] || ws="$(jq -r '.workspace_id // empty' "$sf" 2>/dev/null || true)"
  if [ -n "$ws" ] && "$(_herdr_bin)" workspace get "$ws" >/dev/null 2>&1; then
    printf '%s\n' "$ws"; return 0
  fi
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

_herdr_id_matches() {
  local kind="$1" id="$2" expected="$3" out labels
  [ -n "$id" ] || return 1
  out="$($(_herdr_bin) "$kind" get "$id" 2>/dev/null || true)"
  [ -n "$out" ] || return 1
  labels="$(printf '%s\n' "$out" | jq -er --arg kind "$kind" '
    [.. | objects |
      (if $kind == "tab" then (.label? // .name? // empty)
       else (.agent? // .label? // .name? // empty) end)
      | select(type == "string" and length > 0)]
    | if length == 1 then .[0] else empty end
  ' 2>/dev/null || true)"
  [ -n "$labels" ] && [ "$labels" = "$expected" ]
}

_herdr_stop_owned() {
  local id="$1" agent="$2" tab="$3" pane="$4" label alabel sid pane_owned=0 tab_owned=0 pane_rc=0 tab_rc=0
  label="$(_herdr_tab_label "$id" "$agent")"
  alabel="$(_herdr_agent_label "$id" "$agent")"
  sid="$(jq -r '.herdr_agent_session_id // empty' "$(task_file "$id")" 2>/dev/null || true)"
  if [ -n "$pane" ]; then
    _herdr_id_matches pane "$pane" "$alabel" || return 1
    pane_owned=1
  fi
  if [ -n "$tab" ]; then
    _herdr_id_matches tab "$tab" "$label" || return 1
    tab_owned=1
  fi
  _herdr_supervisor_stop "$id" "$pane" "$sid"
  if [ "$pane_owned" = 1 ]; then
    "$(_herdr_bin)" pane send-keys "$pane" CTRL-C >/dev/null 2>&1 || true
    if "$(_herdr_bin)" pane close "$pane" >/dev/null 2>&1; then
      task_set "$id" herdr_pane_id "" >/dev/null
    else
      pane_rc=$?
    fi
  fi
  if [ "$tab_owned" = 1 ]; then
    if "$(_herdr_bin)" tab close "$tab" >/dev/null 2>&1; then
      task_set "$id" herdr_tab_id "" >/dev/null
    else
      tab_rc=$?
    fi
  fi
  if [ "$pane_rc" -ne 0 ] || [ "$tab_rc" -ne 0 ]; then
    warn "task $id Herdr cleanup incomplete: pane close rc=$pane_rc, tab close rc=$tab_rc; failed IDs preserved; retry"
    return 1
  fi
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

_herdr_probe_state() {
  local pane="$1" out state
  [ -n "$pane" ] || return 1
  if ! "$(_herdr_bin)" pane get "$pane" >/dev/null 2>&1; then
    printf '%s\n' interrupted
    return 0
  fi
  out="$($(_herdr_bin) agent explain "$pane" --json 2>/dev/null || true)"
  state="$(printf '%s\n' "$out" | jq -r '
    .result.agent.status // .result.agent.state //
    .result.status // .result.state //
    .status // .state // .agent.status // .agent.state // empty
  ' 2>/dev/null | head -1)"
  case "$state" in
    done|failed|blocked|interrupted) printf '%s\n' "$state"; return 0 ;;
    error) printf '%s\n' failed; return 0 ;;
  esac
  if "$(_herdr_bin)" wait agent-status "$pane" --status done --timeout 1 >/dev/null 2>&1; then
    printf '%s\n' done; return 0
  fi
  if "$(_herdr_bin)" wait agent-status "$pane" --status blocked --timeout 1 >/dev/null 2>&1; then
    printf '%s\n' blocked; return 0
  fi
  return 1
}

# _herdr_live_state <pane> — the pane's REAL live worker state, read straight from
# `agent explain` (never the pinnable `report-agent` status, which can stale at
# `working` after a worker idles). Prints one of: working|idle|done|blocked|
# failed|interrupted|gone|none|unknown. `gone` = the pane no longer exists (already
# torn down); `none` = no pane id. This is the single source of truth for the
# "is it still working?" half of the close decision.
_herdr_live_state() {
  local pane="$1" out state
  [ -n "$pane" ] || { printf '%s\n' none; return 0; }
  if ! "$(_herdr_bin)" pane get "$pane" >/dev/null 2>&1; then
    printf '%s\n' gone; return 0
  fi
  out="$($(_herdr_bin) agent explain "$pane" --json 2>/dev/null || true)"
  state="$(printf '%s\n' "$out" | jq -r '
    .result.agent.status // .result.agent.state //
    .result.status // .result.state //
    .status // .state // .agent.status // .agent.state // empty
  ' 2>/dev/null | head -1)"
  case "$state" in error) state=failed ;; esac
  printf '%s\n' "${state:-unknown}"
}

# _herdr_safe_to_close <id> — the single chokepoint that decides whether a worker's
# Herdr pane/tab may be torn down. Returns 0 (safe) ONLY when the task is truly
# shipped (status done AND its PR merged) AND its pane's LIVE state is not working.
# Deliberately NEVER trusts the pinnable canopy/Herdr report status for the
# working check: a finished worker often stales at `working` there, which would
# leave it unclosable; live `agent explain` reads the real terminal and reports
# idle. Every refusal is logged (task log + info) so a skipped close is never
# silent. Fails safe: unknown/unreadable live state refuses the close.
_herdr_safe_to_close() {
  local id="$1" tf status pr pane state
  tf="$(task_file "$id" 2>/dev/null || true)"
  [ -n "$tf" ] && [ -f "$tf" ] || return 1
  status="$(jq -r '.status // empty' "$tf" 2>/dev/null || true)"
  pr="$(jq -r '.pr // empty' "$tf" 2>/dev/null || true)"
  if [ "$status" != done ]; then
    _herdr_refuse_close "$id" "status=${status:-none} (not done)"; return 1
  fi
  if [ -z "$pr" ]; then
    _herdr_refuse_close "$id" "no PR recorded"; return 1
  fi
  if declare -F _pr_is_merged >/dev/null 2>&1 && ! _pr_is_merged "$pr"; then
    _herdr_refuse_close "$id" "PR #$pr not merged"; return 1
  fi
  pane="$(jq -r '.herdr_pane_id // empty' "$tf" 2>/dev/null || true)"
  state="$(_herdr_live_state "$pane")"
  case "$state" in
    working|unknown) _herdr_refuse_close "$id" "live pane state=$state"; return 1 ;;
  esac
  return 0
}

_herdr_refuse_close() {
  local id="$1" why="$2"
  info "task $id not safe to close: $why"
  task_log "$id" "safe-to-close refused: $why" >/dev/null 2>&1 || true
}

# _herdr_clean_one <id> — close a worker's Herdr pane/tab, but ONLY if
# _herdr_safe_to_close approves. Returns 0 when it actually closed something, 1
# otherwise (nothing to close, unsafe, or an incomplete Herdr teardown). Never
# errors the caller — the merge-watcher and cleanup command must keep going.
_herdr_clean_one() {
  local id="$1" tf agent tab pane
  tf="$(task_file "$id" 2>/dev/null || true)"
  [ -n "$tf" ] && [ -f "$tf" ] || return 1
  pane="$(jq -r '.herdr_pane_id // empty' "$tf" 2>/dev/null || true)"
  tab="$(jq -r '.herdr_tab_id // empty' "$tf" 2>/dev/null || true)"
  [ -n "$pane" ] || [ -n "$tab" ] || return 1   # nothing to close
  _herdr_safe_to_close "$id" || return 1
  agent="$(jq -r '.agent // empty' "$tf" 2>/dev/null || true)"
  if [ -z "$agent" ]; then
    _herdr_refuse_close "$id" "no backend identity"; return 1
  fi
  # _herdr_stop_owned re-checks pane/tab ownership before closing, so a mismatched
  # or reassigned Herdr object is never clobbered.
  if _herdr_stop_owned "$id" "$agent" "$tab" "$pane"; then
    task_log "$id" "cleaned Herdr worker (done+merged, live pane not working)"
    return 0
  fi
  return 1
}

# _herdr_new_phase <id> — mark a fresh active worker phase: bump the lifecycle
# generation and forget the last observed terminal state, so the next terminal
# outcome is treated as a new, wakeable transition even if it repeats an earlier
# one on the same pane/session. Called on every real (re)start/resume.
_herdr_new_phase() {
  local id="$1" tf gen
  tf="$(task_file "$id")"
  gen="$(jq -r '.herdr_lifecycle_gen // 0' "$tf" 2>/dev/null || echo 0)"
  task_set "$id" herdr_lifecycle_gen "$((gen + 1))" >/dev/null
  task_set "$id" herdr_probe_status "" >/dev/null
}

# _herdr_probe_gate <id> <probed-status>
# Transition detector guarding lifecycle emission. Returns 0 (emit) ONLY when the
# worker has just ENTERED a terminal state it was not already in. When the worker
# is seen to LEAVE a terminal state (a healthy/non-terminal probe after a terminal
# one), it bumps the generation so a later re-entry counts as a fresh transition.
# This is what stops an over-aggressive dedupe from swallowing legitimate later
# wakes on the same pane/session while still suppressing true duplicate probes.
_herdr_probe_gate() {
  local id="$1" status="$2" tf last gen
  tf="$(task_file "$id")"
  last="$(jq -r '.herdr_probe_status // empty' "$tf" 2>/dev/null || true)"
  if _status_terminal "$status"; then
    [ "$last" = "$status" ] && return 1
    task_set "$id" herdr_probe_status "$status" >/dev/null
    return 0
  fi
  if _status_terminal "$last"; then
    gen="$(jq -r '.herdr_lifecycle_gen // 0' "$tf" 2>/dev/null || echo 0)"
    task_set "$id" herdr_lifecycle_gen "$((gen + 1))" >/dev/null
    task_set "$id" herdr_probe_status "" >/dev/null
  fi
  return 1
}

_herdr_supervisor_label() {
  local id="$1" pane="$2" sid="$3" root_hash ident_hash
  root_hash="$(printf '%s' "$(repo_root)" | shasum | cut -c1-8)"
  ident_hash="$(printf '%s' "${id}|${pane}|${sid}" | shasum | cut -c1-8)"
  printf 'com.canopy.herdr.%s.%s.%s\n' "$root_hash" "$id" "$ident_hash"
}

_herdr_supervisor_plist() {
  local id="$1" pane="$2" sid="$3"
  printf '%s/%s.plist\n' "$(herdr_watchers_dir)" "$(_herdr_supervisor_label "$id" "$pane" "$sid")"
}

_herdr_supervisor_loaded() {
  command -v launchctl >/dev/null 2>&1 && launchctl list "$1" >/dev/null 2>&1
}

_herdr_supervisor_stop() {
  local id="$1" pane="$2" sid="$3" label plist
  [ -n "$pane" ] || return 0
  label="$(_herdr_supervisor_label "$id" "$pane" "$sid")"
  plist="$(_herdr_supervisor_plist "$id" "$pane" "$sid")"
  if command -v launchctl >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || launchctl remove "$label" >/dev/null 2>&1 || true
  fi
}

_herdr_supervisor_start() {
  require_canopy; need jq
  local id="$1" tf pane tab sid agent ws root canopy_bin herdr_bin label plist supervisor env_supervisor=""
  command -v launchctl >/dev/null 2>&1 || { warn "Herdr terminal watcher not armed: launchctl unavailable"; return 0; }
  tf="$(task_file "$id")"
  pane="$(jq -r '.herdr_pane_id // empty' "$tf")"
  tab="$(jq -r '.herdr_tab_id // empty' "$tf")"
  sid="$(jq -r '.herdr_agent_session_id // empty' "$tf")"
  agent="$(jq -r '.agent // empty' "$tf")"
  ws="$(jq -r '.herdr_workspace_id // empty' "$tf")"
  [ -n "$pane" ] && [ -n "$agent" ] || return 0
  root="$(repo_root)"
  canopy_bin="$CANOPY_ROOT/bin/canopy"
  herdr_bin="$(_herdr_bin)"
  label="$(_herdr_supervisor_label "$id" "$pane" "$sid")"
  plist="$(_herdr_supervisor_plist "$id" "$pane" "$sid")"
  mkdir -p "$(herdr_watchers_dir)"
  supervisor="$(_watch_supervisor_pane || true)"
  if [ -n "$supervisor" ]; then
    env_supervisor="<key>CANOPY_SUPERVISOR_PANE</key><string>$(printf '%s' "$supervisor" | _xml_escape)</string>"
  fi
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string><string>-lc</string>
    <string>cd "${root}" &amp;&amp; CANOPY_HERDR_BIN="${herdr_bin}" "${canopy_bin}" herdr supervise "${id}" "${pane}" "${tab}" "${sid}" "${agent}"</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict><key>CANOPY_NOTIFY</key><string>1</string>${env_supervisor}</dict>
  <key>RunAtLoad</key><true/>
  <key>StandardErrorPath</key><string>${root}/.canopy/watch.log</string>
  <key>StandardOutPath</key><string>${root}/.canopy/watch.log</string>
</dict>
</plist>
EOF
  if ! _herdr_supervisor_loaded "$label"; then
    launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1 || launchctl load "$plist" >/dev/null 2>&1 || warn "could not arm Herdr terminal watcher for $id"
  fi
  task_set "$id" herdr_supervisor_label "$label" >/dev/null
  task_log "$id" "armed Herdr terminal watcher for pane $pane"
}

_herdr_supervisor_identity_matches() {
  local id="$1" pane="$2" tab="$3" sid="$4" agent="$5" tf saved_pane saved_tab saved_sid saved_agent
  tf="$(task_file "$id")"
  saved_pane="$(jq -r '.herdr_pane_id // empty' "$tf")"
  saved_tab="$(jq -r '.herdr_tab_id // empty' "$tf")"
  saved_sid="$(jq -r '.herdr_agent_session_id // empty' "$tf")"
  saved_agent="$(jq -r '.agent // empty' "$tf")"
  [ "$saved_pane" = "$pane" ] || return 1
  [ -z "$tab" ] || [ "$saved_tab" = "$tab" ] || return 1
  [ -z "$sid" ] || [ "$saved_sid" = "$sid" ] || return 1
  [ -z "$agent" ] || [ "$saved_agent" = "$agent" ] || return 1
}

canopy_herdr_supervise() {
  require_canopy; need jq; _herdr_need
  local id="${1:?task id}" pane="${2:?pane id}" tab="${3:-}" sid="${4:-}" agent="${5:-}" tf status current
  _assert_task "$id"; tf="$(task_file "$id")"
  _herdr_supervisor_identity_matches "$id" "$pane" "$tab" "$sid" "$agent" || return 0
  while :; do
    _herdr_supervisor_identity_matches "$id" "$pane" "$tab" "$sid" "$agent" || return 0
    status="$(_herdr_probe_state "$pane" || true)"
    if _status_terminal "$status"; then
      if _herdr_probe_gate "$id" "$status"; then
        current="$(jq -r '.status' "$tf")"
        [ "$current" = "$status" ] || task_set "$id" status "$status" >/dev/null
        if task_lifecycle_event "$id" "$status" "Herdr worker reported $status" >/dev/null; then
          _notify "task $id $status"
          task_log "$id" "Herdr lifecycle event queued: $status"
        fi
      fi
      _herdr_supervisor_stop "$id" "$pane" "$sid"
      return 0
    fi
    sleep "${CANOPY_HERDR_WATCH_INTERVAL:-5}"
  done
}

canopy_herdr_watch_once() {
  require_canopy; need jq; _herdr_need
  local ids id tf pane status current
  ids="$(jq -r --arg re "$CANOPY_ACTIVE_RE" '.tasks[] | select(.status|test($re)) | .id' "$(state_file)")"
  [ -n "$ids" ] || return 0
  while read -r id; do
    [ -n "$id" ] || continue
    tf="$(task_file "$id")"; [ -f "$tf" ] || continue
    pane="$(jq -r '.herdr_pane_id // empty' "$tf")"
    [ -n "$pane" ] || continue
    status="$(_herdr_probe_state "$pane" || true)"
    # Route every probe through the gate: it records healthy/non-terminal states so
    # a later terminal transition on the same pane is not wrongly deduplicated, and
    # only returns 0 for a genuine fresh terminal transition worth waking on.
    _herdr_probe_gate "$id" "$status" || continue
    current="$(jq -r '.status' "$tf")"
    [ "$current" = "$status" ] || task_set "$id" status "$status" >/dev/null
    if task_lifecycle_event "$id" "$status" "Herdr worker reported $status" >/dev/null; then
      _notify "task $id $status"
      task_log "$id" "Herdr lifecycle event queued: $status"
    fi
  done <<< "$ids"
}

_herdr_report() {
  local id="$1" state="$2" message="${3:-}" tf pane agent sid label
  local -a report_args
  tf="$(task_file "$id")"
  pane="$(jq -r '.herdr_pane_id // empty' "$tf" 2>/dev/null || true)"
  [ -n "$pane" ] || return 0
  agent="$(canopy_task_agent "$id")"
  sid="$(jq -r '.herdr_agent_session_id // empty' "$tf" 2>/dev/null || true)"
  label="$(_herdr_agent_label "$id" "$agent")"
  # Older Herdr versions have no status hook; lifecycle must still work there.
  report_args=("$(_herdr_bin)" pane report-agent "$pane" --source "canopy:$id" --agent "$label" --state "$state")
  [ -z "$message" ] || report_args+=(--message "$message")
  [ -z "$sid" ] || report_args+=(--agent-session-id "$sid")
  "${report_args[@]}" >/dev/null 2>&1 || {
    warn "task $id Herdr status report failed; worker state changed to $state but Herdr was not updated"
    return 1
  }
}

# _worker_claude_settings <id> — write a per-worker Claude settings file whose Stop
# hook fires on every end-of-turn and runs `canopy worker idle <id>`; echo its
# absolute path. That is the missing completion signal: Herdr's agent status is
# source-pinned to the last state canopy PUSHES, so a worker that finishes its turn
# and idles at the prompt (emitting nothing) leaves Herdr showing a stale 'working'
# forever and the orchestrator blind to the stall. The hook re-pins the status to
# idle and enqueues a lifecycle event so the orchestrator wakes. Claude MERGES this
# via --settings on top of the user's global settings, so the guard/session hooks are
# untouched; the task id, canopy binary and Herdr binary are baked into the command
# because a Stop hook has no way to learn them at runtime. Best-effort: on any failure
# it echoes nothing and the launch proceeds without the hook (older behavior).
_worker_claude_settings() {
  local id="$1" dir file cmd canopy_bin herdr_bin
  command -v jq >/dev/null 2>&1 || return 0
  dir="$(canopy_dir)/worker-settings"
  mkdir -p "$dir" 2>/dev/null || return 0
  file="$dir/$id.json"
  canopy_bin="$CANOPY_ROOT/bin/canopy"
  herdr_bin="$(_herdr_bin)"
  cmd="CANOPY_HERDR_BIN='$herdr_bin' '$canopy_bin' worker idle '$id' >/dev/null 2>&1 || true"
  jq -n --arg cmd "$cmd" '{hooks:{Stop:[{hooks:[{type:"command",command:$cmd}]}]}}' \
    > "$file" 2>/dev/null || return 0
  printf '%s\n' "$file"
}

# canopy worker idle <id> — invoked by the worker's Claude Stop hook on every
# end-of-turn. Two jobs, so the worker's status is never stale and the orchestrator
# always wakes on completion:
#   1. Re-pin Herdr's source-pinned status to 'idle' (the fix for the stale 'working').
#   2. Reconcile against Herdr's LIVE detection (`agent explain`): if the worker has
#      actually entered a terminal state, emit that terminal lifecycle event (exactly
#      as the supervisor does); otherwise emit a non-terminal 'idle' wake so the
#      orchestrator still learns the turn finished. Either way, one wake per phase.
# Never fails the caller (a Stop hook must not block the worker): every step is
# guarded, and a missing pane / older Herdr just degrades to the lifecycle event.
canopy_worker_idle() {
  local id=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) printf '%s\n' "usage: canopy worker idle <task-id>"; return 0 ;;
      --) shift; break ;;
      -*) usage_error "unknown flag $1 for 'worker idle'" "usage: canopy worker idle <task-id>" ;;
      *) id="$1"; shift; break ;;
    esac
  done
  if [ -z "$id" ] && [ "$#" -gt 0 ]; then id="$1"; fi
  [ -n "$id" ] || usage_error "missing task-id" "usage: canopy worker idle <task-id>"
  require_canopy; need jq
  local tf pane status current; _assert_task "$id"; tf="$(task_file "$id")"
  pane="$(jq -r '.herdr_pane_id // empty' "$tf" 2>/dev/null || true)"
  # 1. Freshen Herdr's source-pinned status: the worker is idle at the prompt.
  if [ -n "$pane" ] && command -v "$(basename "$(_herdr_bin)")" >/dev/null 2>&1; then
    _herdr_report "$id" idle "worker idle at end of turn" || true
  fi
  # 2. Reconcile against live detection, then emit exactly one wake.
  status=""
  [ -z "$pane" ] || status="$(_herdr_probe_state "$pane" 2>/dev/null || true)"
  if _status_terminal "$status" && _herdr_probe_gate "$id" "$status"; then
    current="$(jq -r '.status' "$tf")"
    [ "$current" = "$status" ] || task_set "$id" status "$status" >/dev/null
    if task_lifecycle_event "$id" "$status" "worker reported $status on idle" >/dev/null; then
      _notify "task $id $status"
      task_log "$id" "idle hook queued lifecycle event: $status"
    fi
  elif task_lifecycle_event "$id" idle "worker idle at end of turn" >/dev/null; then
    _notify "task $id idle"
    task_log "$id" "idle hook queued lifecycle event: idle"
  fi
}

_herdr_launch_claude() {
  local id="$1" path="$2" tab="$3" prompt="$4" name="$5" settings
  local -a settings_arg=()
  # Pre-trust the leased worktree so claude never stalls on the trust dialog.
  _claude_trust_path "$path"
  settings="$(_worker_claude_settings "$id" || true)"
  [ -z "$settings" ] || settings_arg=(--settings "$settings")
  # CANOPY_ROLE=worker: the worker shares the orchestrator's .canopy via
  # git-common-dir, so canopy_role_guard must refuse orchestrator-only commands
  # it might run. Without this it would inherit CANOPY_ROLE=orchestrator.
  "$(_herdr_bin)" agent start "$name" --cwd "$path" --tab "$tab" --no-focus -- \
    env CANOPY_ROLE=worker claude --dangerously-skip-permissions ${settings_arg[@]+"${settings_arg[@]}"} \
    --append-system-prompt "$(_agent_body worker)" "$prompt"
}

_herdr_launch_codex() {
  local id="$1" path="$2" tab="$3" prompt="$4" name="$5"
  local -a codex_args
  codex_args=(-s "${CANOPY_CODEX_SANDBOX:-workspace-write}" -C "$path")
  _codex_has_bypass_arg "${codex_args[@]+"${codex_args[@]}"}" || codex_args+=("$(_codex_bypass_flag)")
  # Launch the interactive Codex TUI seeded with the prompt as its positional arg
  # (mirrors the Claude adapter). The old `bash -c '… | codex … exec --json -'`
  # wrapper ran Codex headless: it printed a one-shot JSON stream, then exited, so
  # the tab was never a steerable interactive worker — and on any early exit the
  # seeded prompt died with it. Passing the prompt as codex's argument delivers it
  # to a durable interactive session instead.
  # CANOPY_ROLE=worker: the worker shares the orchestrator's .canopy via
  # git-common-dir, so canopy_role_guard must refuse orchestrator-only commands
  # it might run. Without this it would inherit CANOPY_ROLE=orchestrator.
  "$(_herdr_bin)" agent start "$name" --cwd "$path" --tab "$tab" --no-focus -- \
    env CANOPY_ROLE=worker codex "${codex_args[@]}" "$prompt"
}

_herdr_launch() {
  local agent="$1"; shift
  # $1 is the task id; derive the unique agent-start name once and hand it to the
  # backend adapter as its trailing arg. The launched binary after `--` is untouched.
  local name; name="$(_herdr_agent_name "$1")"
  case "$agent" in
    claude) _herdr_launch_claude "$@" "$name" ;;
    codex)  _herdr_launch_codex "$@" "$name" ;;
    *) die "unknown agent runtime: $agent (use claude or codex)" ;;
  esac
}

_herdr_start() {
  require_canopy; need jq; _herdr_need
  local id="${1:?task id}" agent="${2:-$(canopy_task_agent "$1")}" explicit_ws="${3:-}" resuming="${4:-0}" tf path title brief checkpoint task_ws ws tab pane sid out label alabel stored_agent reuse_persisted legacy_tab legacy_pane
  _assert_task "$id"; agent="$(_canopy_agent_validate "$agent")"; tf="$(task_file "$id")"
  path="$(jq -r '.worktree // empty' "$tf")"
  [ -d "$path" ] || die "task $id has no leased worktree"
  title="$(jq -r '.title' "$tf")"; brief="$(jq -r '.brief // ""' "$tf")"
  task_ws="$(jq -r '.herdr_workspace_id // empty' "$tf" 2>/dev/null || true)"
  label="$(_herdr_tab_label "$id" "$agent")"; alabel="$(_herdr_agent_label "$id" "$agent")"
  stored_agent="$(jq -r '.agent // empty' "$tf" 2>/dev/null || true)"
  legacy_tab="$(jq -r '.herdr_tab_id // empty' "$tf" 2>/dev/null || true)"
  legacy_pane="$(jq -r '.herdr_pane_id // empty' "$tf" 2>/dev/null || true)"
  if [ -z "$stored_agent" ] && { [ -n "$legacy_tab" ] || [ -n "$legacy_pane" ]; }; then
    die "task $id has legacy Herdr state without backend identity; run 'canopy worker reconcile --agent <old-backend> $id' first"
  fi
  reuse_persisted=1
  [ -z "$stored_agent" ] || [ "$stored_agent" = "$agent" ] || reuse_persisted=0
  if [ "$reuse_persisted" = 0 ]; then
    _herdr_stop_owned "$id" "$stored_agent" \
      "$legacy_tab" "$legacy_pane" \
      || die "task $id Herdr state could not be reconciled safely; verify the old pane/tab before switching backends"
    for key in herdr_tab_id herdr_pane_id herdr_agent_session_id worker_session worker_pid worker_log; do
      task_set "$id" "$key" "" >/dev/null
    done
  fi
  ws="$(_herdr_workspace "$explicit_ws" "$task_ws")"
  tab=""
  if [ "$reuse_persisted" = 1 ]; then
    tab="$(jq -r '.herdr_tab_id // empty' "$tf" 2>/dev/null || true)"
    _herdr_id_matches tab "$tab" "$label" || tab=""
  fi
  [ -n "$tab" ] || tab="$(_herdr_find_tab "$ws" "$label")"
  if [ -z "$tab" ]; then
    tab="$($(_herdr_bin) tab create --workspace "$ws" --cwd "$path" --label "$label" --no-focus 2>/dev/null | _herdr_tab_id)"
    [ -n "$tab" ] || die "Herdr did not return a tab id"
  fi
  task_set "$id" herdr_workspace_id "$ws" >/dev/null
  task_set "$id" herdr_tab_id "$tab" >/dev/null
  pane=""
  if [ "$reuse_persisted" = 1 ]; then
    pane="$(jq -r '.herdr_pane_id // empty' "$tf" 2>/dev/null || true)"
    _herdr_id_matches pane "$pane" "$alabel" || pane=""
  fi
  [ -n "$pane" ] || pane="$(_herdr_find_pane "$ws" "$alabel")"
  if [ -n "$pane" ]; then
    task_set "$id" agent "$agent" >/dev/null
    task_set "$id" herdr_pane_id "$pane" >/dev/null
    if [ "$resuming" = 1 ]; then
      checkpoint="$(jq -r '.checkpoint.note // empty' "$tf" 2>/dev/null || true)"
      if [ -n "$checkpoint" ]; then
        _herdr_agent_submit "$pane" "Continue from checkpoint: $checkpoint" \
          || die "task $id could not deliver its checkpoint to the live Herdr pane"
        task_log "$id" "delivered checkpoint to reused Herdr pane $pane"
      fi
      # Resuming a live pane hands it new work — start a fresh lifecycle phase so a
      # repeat of an earlier terminal outcome still wakes the orchestrator.
      _herdr_new_phase "$id"
    fi
    task_status "$id" implementing >/dev/null
    _herdr_report "$id" working "reused existing Herdr worker"
    _herdr_supervisor_start "$id"
    printf '%s\n' "$pane"; return 0
  fi
  prompt="$(_worker_prompt "$id" "$title" "$brief")"
  checkpoint="$(jq -r '.checkpoint.note // empty' "$tf" 2>/dev/null || true)"
  if [ -n "$checkpoint" ]; then
    prompt="$prompt

Last checkpoint:
${checkpoint}

Continue from the checkpoint; do not restart."
  fi
  out="$(_herdr_launch "$agent" "$id" "$path" "$tab" "$prompt" 2>&1)" || {
    die "could not start $agent in Herdr"
  }
  pane="$(printf '%s\n' "$out" | _herdr_pane_id | head -1)"
  [ -n "$pane" ] || die "Herdr did not return a pane id"
  sid="$(printf '%s\n' "$out" | _herdr_agent_session_id | head -1)"
  task_set "$id" agent "$agent" >/dev/null
  task_set "$id" herdr_workspace_id "$ws" >/dev/null
  task_set "$id" herdr_tab_id "$tab" >/dev/null
  task_set "$id" herdr_pane_id "$pane" >/dev/null
  [ -n "$sid" ] && task_set "$id" herdr_agent_session_id "$sid" >/dev/null
  # A freshly launched worker is a new lifecycle phase; reset transition tracking so
  # its terminal outcome emits even if the task previously ended in the same state.
  _herdr_new_phase "$id"
  task_status "$id" implementing >/dev/null
  task_log "$id" "started interactive $agent worker in Herdr workspace $ws, tab $tab, pane $pane"
  _herdr_report "$id" working "interactive worker started"
  _herdr_supervisor_start "$id"
  printf '%s\n' "$pane"
}

# _worker_help <cmd> — concise per-subcommand reference on stdout (AXI §10).
# The ergonomics layer over the base Herdr worker commands: strict flags, help,
# and TOON confirmations. Diagnostics/JSON status behavior is unchanged.
_worker_help() {
  case "$1" in
    start) cat <<'EOF'
usage: canopy worker start [--agent claude|codex] [--workspace <id>] [--headless] <task-id>
  Launch (or reuse) an interactive Herdr worker for a leased task.
  --agent claude|codex   worker backend (default: task's agent, else claude)
  --workspace <id>       Herdr workspace id (default: persisted, else current pane)
  --headless             run a detached (non-Herdr) worker instead
  -h, --help             show this help
EOF
      ;;
    resume) cat <<'EOF'
usage: canopy worker resume [--agent claude|codex] [--workspace <id>] <task-id>
  Relaunch an interactive Herdr worker from its checkpoint.
  --agent claude|codex   backend to resume through (default: task's agent)
  --workspace <id>       Herdr workspace id (default: persisted, else current pane)
  -h, --help             show this help
EOF
      ;;
    attach) cat <<'EOF'
usage: canopy worker attach <task-id>
  Take over the task's Herdr pane (hands off to the interactive TUI).
  -h, --help   show this help
EOF
      ;;
    send) cat <<'EOF'
usage: canopy worker send [--] <task-id> <text...>
  Send a line of text to the task's Herdr pane.
  -h, --help   show this help  (use -- so text starting with - is not a flag)
EOF
      ;;
    status) cat <<'EOF'
usage: canopy worker status <task-id>
  Print bounded, structured (JSON) status for the task's Herdr worker.
  -h, --help   show this help
EOF
      ;;
    read) cat <<'EOF'
usage: canopy worker read <task-id> [--lines <1..120>]
  Print fuller recent worker context (raw).
  --lines <n>   number of lines (default 80, max 120)
  -h, --help    show this help
EOF
      ;;
    reconcile) cat <<'EOF'
usage: canopy worker reconcile --agent claude|codex <task-id>
  Verify and clear legacy Herdr state so the task can resume with an explicit backend.
  --agent claude|codex   backend that previously owned the pane/tab (required)
  -h, --help             show this help
EOF
      ;;
    close) cat <<'EOF'
usage: canopy worker close <task-id>
  Close the task's Herdr tab (requires ready_for_review + passing checks).
  -h, --help   show this help
EOF
      ;;
    stop) cat <<'EOF'
usage: canopy worker stop <task-id|session-id>
  Stop a worker (interactive Herdr pane or headless process).
  -h, --help   show this help
EOF
      ;;
    clean) cat <<'EOF'
usage: canopy worker clean [--all] [<task-id>]
  Close every safe-to-close worker's Herdr tab/pane (or one named task).
  Safe = task done AND its PR merged AND its live pane is not working.
  A working or unshipped worker is always refused (never closed).
  --all        sweep all workers with Herdr state
  -h, --help   show this help
EOF
      ;;
  esac
}

canopy_worker_start() {
  local agent="" id="" workspace="" headless=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) _worker_help start; return 0 ;;
      --agent) shift; agent="$(_worker_agent_flag "${1:-}")" ;;
      --workspace) shift; workspace="${1:-}"; [ -n "$workspace" ] || usage_error "--workspace needs a workspace id" "usage: canopy worker start [--agent claude|codex] [--workspace <id>] [--headless] <task-id>" ;;
      --headless) headless=1 ;;
      -*) usage_error "unknown flag $1 for 'worker start'" "valid flags: --agent, --workspace, --headless (--help always allowed)" ;;
      *) id="$1"; shift; [ "$#" -eq 0 ] || usage_error "unexpected argument: $1" "usage: canopy worker start [--agent claude|codex] [--workspace <id>] [--headless] <task-id>"; break ;;
    esac
    shift
  done
  [ -n "$id" ] || usage_error "missing task-id" "usage: canopy worker start [--agent claude|codex] [--workspace <id>] [--headless] <task-id>"
  if [ "$headless" = 1 ]; then
    [ -z "$workspace" ] || die '--workspace is only valid for interactive Herdr workers'
    agent="${agent:-$(canopy_task_agent "$id")}"
    canopy_worker_spawn --agent "$agent" "$id"
    return
  fi
  agent="${agent:-$(canopy_task_agent "$id")}"
  _herdr_start "$id" "$agent" "$workspace" >/dev/null
  local pane
  pane="$(jq -r '.herdr_pane_id // empty' "$(task_file "$id")")" || pane=""
  toon_obj task "$id" agent "$agent" pane "${pane:--}" state working
  toon_help "Run \`canopy worker status $id\` to check progress" "Run \`canopy worker send $id \"<text>\"\` to steer it"
}

canopy_worker_attach() {
  local id=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) _worker_help attach; return 0 ;;
      --) shift; break ;;
      -*) usage_error "unknown flag $1 for 'worker attach'" "valid flags: --help. usage: canopy worker attach <task-id>" ;;
      *) id="$1"; shift; [ "$#" -eq 0 ] || usage_error "unexpected argument: $1" "usage: canopy worker attach <task-id>"; break ;;
    esac
    shift
  done
  if [ -z "$id" ] && [ "$#" -gt 0 ]; then id="$1"; fi
  [ -n "$id" ] || usage_error "missing task-id" "usage: canopy worker attach <task-id>"
  require_canopy; need jq
  local tf pane tab agent target; _assert_task "$id"; tf="$(task_file "$id")"
  agent="$(jq -r '.agent // empty' "$tf")"
  [ -n "$agent" ] || die "task $id has no Herdr backend identity; reconcile legacy state first"
  pane="$(jq -r '.herdr_pane_id // empty' "$tf")"; tab="$(jq -r '.herdr_tab_id // empty' "$tf")"
  [ -n "$pane" ] || [ -n "$tab" ] || die "task $id has no Herdr worker"
  _herdr_need
  [ -z "$pane" ] || _herdr_id_matches pane "$pane" "$(_herdr_agent_label "$id" "$agent")" \
    || die "task $id Herdr pane identity does not match; refusing to attach"
  [ -z "$tab" ] || _herdr_id_matches tab "$tab" "$(_herdr_tab_label "$id" "$agent")" \
    || die "task $id Herdr tab identity does not match; refusing to attach"
  target="${pane:-$tab}"
  "$(_herdr_bin)" agent attach "$target" --takeover
}

canopy_worker_send() {
  local id=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) _worker_help send; return 0 ;;
      --) shift; break ;;
      -*) usage_error "unknown flag $1 for 'worker send'" "valid flags: --help. usage: canopy worker send [--] <task-id> <text...>" ;;
      *) id="$1"; shift; break ;;
    esac
    shift
  done
  if [ -z "$id" ] && [ "$#" -gt 0 ]; then id="$1"; shift; fi
  [ -n "$id" ] || usage_error "missing task-id" "usage: canopy worker send [--] <task-id> <text...>"
  local text="$*"
  [ -n "$text" ] || usage_error "missing text to send" "usage: canopy worker send [--] <task-id> <text...>"
  require_canopy; need jq
  local tf pane tab agent; _assert_task "$id"; tf="$(task_file "$id")"
  agent="$(jq -r '.agent // empty' "$tf")"
  [ -n "$agent" ] || die "task $id has no Herdr backend identity; reconcile legacy state first"
  pane="$(jq -r '.herdr_pane_id // empty' "$tf")"; tab="$(jq -r '.herdr_tab_id // empty' "$tf")"
  [ -n "$pane" ] || die "task $id has no Herdr worker"
  _herdr_need
  _herdr_id_matches pane "$pane" "$(_herdr_agent_label "$id" "$agent")" \
    || die "task $id Herdr pane identity does not match; refusing to send"
  [ -z "$tab" ] || _herdr_id_matches tab "$tab" "$(_herdr_tab_label "$id" "$agent")" \
    || die "task $id Herdr tab identity does not match; refusing to send"
  _herdr_agent_submit "$pane" "$text"
  task_log "$id" "sent message to Herdr pane $pane"
  toon_obj task "$id" pane "$pane" sent ok
  toon_help "Run \`canopy worker status $id\` to see the worker's response"
}

canopy_worker_status() {
  local id=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) _worker_help status; return 0 ;;
      --) shift; break ;;
      -*) usage_error "unknown flag $1 for 'worker status'" "valid flags: --help. usage: canopy worker status <task-id>" ;;
      *) id="$1"; shift; [ "$#" -eq 0 ] || usage_error "unexpected argument: $1" "usage: canopy worker status <task-id>"; break ;;
    esac
    shift
  done
  if [ -z "$id" ] && [ "$#" -gt 0 ]; then id="$1"; fi
  [ -n "$id" ] || usage_error "missing task-id" "usage: canopy worker status <task-id>"
  require_canopy; need jq
  local tf pane tab explain state summary agent context; _assert_task "$id"
  tf="$(task_file "$id")"
  pane="$(jq -r '.herdr_pane_id // empty' "$tf")"; tab="$(jq -r '.herdr_tab_id // empty' "$tf")"
  if [ -z "$(jq -r '.agent // empty' "$tf")" ] && { [ -n "$pane" ] || [ -n "$tab" ]; }; then
    die "task $id has legacy Herdr state without backend identity; run 'canopy worker reconcile --agent <old-backend> $id' first"
  fi
  agent="$(canopy_task_agent "$id")"
  explain=""
  if [ -n "$pane" ]; then
    _herdr_need
    _herdr_id_matches pane "$pane" "$(_herdr_agent_label "$id" "$agent")" || pane=""
  fi
  if [ -n "$pane" ]; then
    explain="$($(_herdr_bin) agent explain "$pane" --json 2>/dev/null || true)"
  fi
  state="$(printf '%s\n' "$explain" | jq -r '.. | objects | (.state // .status // empty)' 2>/dev/null | head -1)"
  summary="$(printf '%s\n' "$explain" | jq -r '.. | objects | (.summary // .message // empty)' 2>/dev/null | head -1)"
  [ -n "$state" ] || state="unknown"
  [ -n "$summary" ] || summary="no summary available"
  context="canopy worker read $id"
  jq -cn --arg task "$id" --arg backend "$agent" --arg state "$state" \
    --arg summary "$summary" --arg workspace "$(jq -r '.herdr_workspace_id // empty' "$tf")" \
    --arg tab "$(jq -r '.herdr_tab_id // empty' "$tf")" --arg pane "$pane" \
    --arg checkpoint "$(jq -r '.checkpoint.note // empty' "$tf")" --arg context "$context" \
    '{task:$task,backend:$backend,state:$state,summary:$summary,workspace:$workspace,tab:$tab,pane:$pane,checkpoint:$checkpoint,full_context:$context}'
}

canopy_worker_read() {
  local id="" lines=80
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) _worker_help read; return 0 ;;
      --lines) shift; lines="${1:-}"; { [ "$lines" -ge 1 ] 2>/dev/null && [ "$lines" -le 120 ] 2>/dev/null; } || usage_error "--lines must be 1..120" "usage: canopy worker read <task-id> [--lines <1..120>]" ;;
      -*) usage_error "unknown flag $1 for 'worker read'" "valid flags: --lines (--help always allowed)" ;;
      *) [ -z "$id" ] || usage_error "unexpected argument: $1" "usage: canopy worker read <task-id> [--lines <1..120>]"; id="$1" ;;
    esac
    shift
  done
  [ -n "$id" ] || usage_error "missing task-id" "usage: canopy worker read <task-id> [--lines <1..120>]"
  require_canopy; need jq
  local pane tab agent logf; _assert_task "$id"
  pane="$(jq -r '.herdr_pane_id // empty' "$(task_file "$id")")"
  tab="$(jq -r '.herdr_tab_id // empty' "$(task_file "$id")")"
  if [ -z "$(jq -r '.agent // empty' "$(task_file "$id")")" ] && { [ -n "$pane" ] || [ -n "$tab" ]; }; then
    die "task $id has legacy Herdr state without backend identity; run 'canopy worker reconcile --agent <old-backend> $id' first"
  fi
  if [ -n "$pane" ]; then
    _herdr_need
    agent="$(canopy_task_agent "$id")"
    _herdr_id_matches pane "$pane" "$(_herdr_agent_label "$id" "$agent")" \
      || die "task $id Herdr pane identity does not match"
    "$(_herdr_bin)" agent read "$pane" --lines "$lines"
    return
  fi
  logf="$(jq -r '.worker_log // empty' "$(task_file "$id")")"
  [ -n "$logf" ] && [ -f "$logf" ] || die "task $id has no readable worker context"
  tail -n "$lines" "$logf"
}

_herdr_worker_stop() {
  local ref="${1:?task id}" tf pane tab agent sid cur
  tf="$(task_file "$ref")"
  pane="$(jq -r '.herdr_pane_id // empty' "$tf")"
  tab="$(jq -r '.herdr_tab_id // empty' "$tf")"
  agent="$(jq -r '.agent // empty' "$tf")"
  [ -n "$agent" ] || die "task $ref has legacy Herdr state without backend identity; reconcile before stopping"
  _herdr_need
  [ -z "$pane" ] || _herdr_id_matches pane "$pane" "$(_herdr_agent_label "$ref" "$agent")" \
    || die "task $ref Herdr pane identity does not match; refusing to stop it"
  [ -z "$tab" ] || _herdr_id_matches tab "$tab" "$(_herdr_tab_label "$ref" "$agent")" \
    || die "task $ref Herdr tab identity does not match; refusing to stop it"
  if [ -n "$pane" ]; then
    sid="$(jq -r '.herdr_agent_session_id // empty' "$tf")"
    _herdr_supervisor_stop "$ref" "$pane" "$sid"
    "$(_herdr_bin)" pane send-keys "$pane" CTRL-C >/dev/null 2>&1 || true
    _herdr_report "$ref" idle "interactive worker stopped"
  fi
  # A manual stop is a terminal outcome: record a durable 'interrupted' event (once,
  # and only if the worker was still active) so the next Canopy turn learns it was
  # halted instead of silently losing the transition. The supervisor is already
  # booted out above, so it will not also emit.
  cur="$(jq -r '.status' "$tf")"
  if ! _status_terminal "$cur"; then
    task_set "$ref" status interrupted >/dev/null
    if task_lifecycle_event "$ref" interrupted "worker manually stopped" >/dev/null; then
      _notify "task $ref interrupted"
    fi
  fi
  task_log "$ref" "stopped Herdr worker${pane:+ pane $pane}${tab:+ in tab $tab}"
}

canopy_worker_resume() {
  local id="" workspace="" agent=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) _worker_help resume; return 0 ;;
      --workspace) shift; workspace="${1:-}"; [ -n "$workspace" ] || usage_error "--workspace needs a workspace id" "usage: canopy worker resume [--agent claude|codex] [--workspace <id>] <task-id>" ;;
      --agent) shift; agent="$(_worker_agent_flag "${1:-}")" ;;
      -*) usage_error "unknown flag $1 for 'worker resume'" "valid flags: --agent, --workspace (--help always allowed)" ;;
      *) id="$1"; shift; [ "$#" -eq 0 ] || usage_error "unexpected argument: $1" "usage: canopy worker resume [--agent claude|codex] [--workspace <id>] <task-id>"; break ;;
    esac
    shift
  done
  [ -n "$id" ] || usage_error "missing task-id" "usage: canopy worker resume [--agent claude|codex] [--workspace <id>] <task-id>"
  _assert_task "$id"
  _herdr_start "$id" "${agent:-$(canopy_task_agent "$id")}" "$workspace" 1
  _herdr_report "$id" working "interactive worker resumed"
}

canopy_worker_reconcile() {
  require_canopy; need jq; _herdr_need
  local id="" agent="" tf tab pane
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) _worker_help reconcile; return 0 ;;
      --agent) shift; agent="$(_worker_agent_flag "${1:-}")" ;;
      -*) usage_error "unknown flag $1 for 'worker reconcile'" "valid flags: --agent (--help always allowed)" ;;
      *) id="$1"; shift; [ "$#" -eq 0 ] || usage_error "unexpected argument: $1" "usage: canopy worker reconcile --agent claude|codex <task-id>"; break ;;
    esac
    shift
  done
  [ -n "$id" ] || usage_error "missing task-id" "usage: canopy worker reconcile --agent claude|codex <task-id>"
  [ -n "$agent" ] || usage_error "missing --agent" "usage: canopy worker reconcile --agent claude|codex <task-id>"
  _assert_task "$id"; tf="$(task_file "$id")"
  tab="$(jq -r '.herdr_tab_id // empty' "$tf")"; pane="$(jq -r '.herdr_pane_id // empty' "$tf")"
  [ -n "$tab" ] || [ -n "$pane" ] || die "task $id has no legacy Herdr IDs to reconcile"
  _herdr_stop_owned "$id" "$agent" "$tab" "$pane" \
    || die "task $id legacy Herdr IDs could not be verified; inspect Herdr and retry"
  for key in herdr_tab_id herdr_pane_id herdr_agent_session_id worker_session worker_pid worker_log agent; do
    task_set "$id" "$key" "" >/dev/null
  done
  task_log "$id" "reconciled legacy Herdr state for $agent"
  info "task $id legacy Herdr state cleared; resume with an explicit --agent"
}

canopy_worker_close() {
  local id=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) _worker_help close; return 0 ;;
      --) shift; break ;;
      -*) usage_error "unknown flag $1 for 'worker close'" "valid flags: --help. usage: canopy worker close <task-id>" ;;
      *) id="$1"; shift; [ "$#" -eq 0 ] || usage_error "unexpected argument: $1" "usage: canopy worker close <task-id>"; break ;;
    esac
    shift
  done
  if [ -z "$id" ] && [ "$#" -gt 0 ]; then id="$1"; fi
  [ -n "$id" ] || usage_error "missing task-id" "usage: canopy worker close <task-id>"
  require_canopy; need jq; _herdr_need
  local tf checkpoint path pane tab agent; _assert_task "$id"; tf="$(task_file "$id")"
  checkpoint="$(jq -r '.checkpoint.note // empty' "$tf")"
  [ "$checkpoint" = ready_for_review ] || die "task $id is not ready_for_review"
  path="$(jq -r '.worktree // empty' "$tf")"
  [ -d "$path" ] || die "task $id has no leased worktree"
  pane="$(jq -r '.herdr_pane_id // empty' "$tf")"; tab="$(jq -r '.herdr_tab_id // empty' "$tf")"
  agent="$(jq -r '.agent // empty' "$tf")"
  [ -n "$agent" ] || die "task $id has no Herdr backend identity"
  [ -n "$pane" ] || [ -n "$tab" ] || die "task $id has no closable Herdr pane or tab"
  [ -z "$pane" ] || _herdr_id_matches pane "$pane" "$(_herdr_agent_label "$id" "$agent")" \
    || die "task $id Herdr pane identity does not match; refusing to close it"
  [ -z "$tab" ] || _herdr_id_matches tab "$tab" "$(_herdr_tab_label "$id" "$agent")" \
    || die "task $id Herdr tab identity does not match; refusing to close it"
  ( cd "$path" && canopy_checks_run ) >&2 || die "task $id checks failed"
  local pane_rc=0 tab_rc=0
  if [ -n "$pane" ]; then
    _herdr_supervisor_stop "$id" "$pane" "$(jq -r '.herdr_agent_session_id // empty' "$tf")"
    "$(_herdr_bin)" pane close "$pane" >/dev/null 2>&1 || pane_rc=$?
    [ "$pane_rc" -eq 0 ] && task_set "$id" herdr_pane_id "" >/dev/null
  fi
  if [ -n "$tab" ]; then
    "$(_herdr_bin)" tab close "$tab" >/dev/null 2>&1 || tab_rc=$?
    [ "$tab_rc" -eq 0 ] && task_set "$id" herdr_tab_id "" >/dev/null
  fi
  if [ "$pane_rc" -ne 0 ] || [ "$tab_rc" -ne 0 ]; then
    task_log "$id" "Herdr close incomplete: pane_rc=$pane_rc tab_rc=$tab_rc; retry close"
    die "task $id Herdr close incomplete (pane=$pane_rc tab=$tab_rc); retry 'canopy worker close $id'"
  fi
  task_status "$id" done >/dev/null
  task_log "$id" "closed Herdr worker after ready_for_review and passing checks"
  toon_obj task "$id" pane "${pane:--}" tab "${tab:--}" status done
  toon_help "Run \`canopy pr open $id\` to open the pull request"
}

# canopy worker clean [--all] [<task-id>]
# Close every safe-to-close worker in one pass (or a single named one). "Safe"
# is decided solely by _herdr_safe_to_close (done+merged AND live pane not
# working), so this can never kill a working or still-unshipped worker — it
# replaces manual pane-id surgery, which lost an unshipped worker this session.
canopy_worker_clean() {
  local all=0 id=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) _worker_help clean; return 0 ;;
      --all) all=1 ;;
      --) shift; break ;;
      -*) usage_error "unknown flag $1 for 'worker clean'" "valid flags: --all (--help always allowed). usage: canopy worker clean [--all] [<task-id>]" ;;
      *) id="$1"; shift; [ "$#" -eq 0 ] || usage_error "unexpected argument: $1" "usage: canopy worker clean [--all] [<task-id>]"; break ;;
    esac
    shift
  done
  if [ -z "$id" ] && [ "$#" -gt 0 ]; then id="$1"; fi
  [ "$all" = 1 ] || [ -n "$id" ] || usage_error "missing task-id or --all" "usage: canopy worker clean [--all] [<task-id>]"
  require_canopy; need jq; _herdr_need
  if [ "$all" = 1 ]; then
    # Herdr ids live only in the per-task detail files (the board omits them), so
    # sweep those, not state.json .tasks[]. Count only tasks that actually carry
    # Herdr state — tasks with nothing to close are neither cleaned nor skipped.
    local f t cleaned=0 skipped=0 pane tab
    for f in "$(tasks_dir)"/*.json; do
      [ -e "$f" ] || continue
      pane="$(jq -r '.herdr_pane_id // empty' "$f" 2>/dev/null || true)"
      tab="$(jq -r '.herdr_tab_id // empty' "$f" 2>/dev/null || true)"
      [ -n "$pane" ] || [ -n "$tab" ] || continue
      t="$(jq -r '.id // empty' "$f" 2>/dev/null || true)"
      [ -n "$t" ] || continue
      if _herdr_clean_one "$t"; then cleaned=$((cleaned+1)); else skipped=$((skipped+1)); fi
    done
    toon_obj cleaned "$cleaned" skipped "$skipped"
    return 0
  fi
  _assert_task "$id"
  if _herdr_clean_one "$id"; then
    toon_obj task "$id" cleaned ok
  else
    die "task $id is not safe to close (still working, or not done+merged); left running"
  fi
}
