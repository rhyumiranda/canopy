# worker.sh — spawn/observe detached workers. Sourced, not executed.
# shellcheck shell=bash

# _worker_model_for -> the model the CLAUDE worker runs on. Canopy launches the
# worker via the CLI (`claude --bg`), which STRIPS an agent-file's frontmatter and
# passes only the body — so a `model:` line in agents/worker.md would be a NO-OP.
# The real pin has to be a `--model` flag at launch, which the claude launch sites
# below pass. Default: Opus 4.8 (claude-opus-4-8); override with CANOPY_WORKER_MODEL.
# Offline-safe: it only names a model, never touches the network. An empty value
# means "don't pass --model" (let the backend pick its own).
#
# Claude-only by design: a Codex worker has no per-exec model pin here — the codex
# worker launch path (_worker_spawn_codex) doesn't pass `-m`, so there is no codex
# lever to expose. Codex model selection is an account/settings concern, not a
# canopy launch flag; don't add a phantom env var that does nothing.
_worker_model_for() {
  printf '%s\n' "${CANOPY_WORKER_MODEL:-claude-opus-4-8}"
}

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

# _worker_claude_settings <id> — write a per-worker Claude settings file whose Stop
# hook fires on every end-of-turn and runs `canopy worker idle <id>`; echo its
# absolute path. That is the completion signal a detached (`worker spawn`) worker
# gets: a worker that finishes its turn and idles at the prompt emits nothing else,
# so without this the orchestrator stays blind to the stall. The hook enqueues a
# durable lifecycle event so the orchestrator wakes (via `canopy events wait` /
# `canopy recover`). Claude MERGES this via --settings on top of the user's global
# settings, so the guard/session hooks are untouched; the task id and canopy binary
# are baked into the command because a Stop hook has no way to learn them at runtime.
# Best-effort: on any failure it echoes nothing and the launch proceeds without the
# hook (older behavior).
_worker_claude_settings() {
  local id="$1" dir file cmd canopy_bin
  command -v jq >/dev/null 2>&1 || return 0
  dir="$(canopy_dir)/worker-settings"
  mkdir -p "$dir" 2>/dev/null || return 0
  file="$dir/$id.json"
  canopy_bin="$CANOPY_ROOT/bin/canopy"
  cmd="'$canopy_bin' worker idle '$id' >/dev/null 2>&1 || true"
  jq -n --arg cmd "$cmd" '{hooks:{Stop:[{hooks:[{type:"command",command:$cmd}]}]}}' \
    > "$file" 2>/dev/null || return 0
  printf '%s\n' "$file"
}

# canopy worker idle <id> — invoked by the worker's Claude Stop hook on every
# end-of-turn. It enqueues a durable, non-terminal 'idle' lifecycle event so the
# orchestrator learns the turn finished and wakes on completion. This queued event
# is the ONLY completion signal a detached `worker spawn` worker gets — a worker
# that finishes its turn and idles at the prompt emits nothing else. Never fails the
# caller (a Stop hook must not block the worker): every step is guarded.
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
  _assert_task "$id"
  if task_lifecycle_event "$id" idle "worker idle at end of turn" >/dev/null; then
    _notify "task $id idle"
    task_log "$id" "idle hook queued lifecycle event: idle"
  fi
}

# _worker_experimental_only [sub] — the interactive Herdr worker subcommands
# (start/attach/send/status/read/resume/reconcile/close/clean) are an experimental
# feature not shipped in stable. Point the user at the detached worker or the opt-in
# channel, and exit 2. (Named without an "herdr" symbol so the no-herdr regression
# guard, which greps for herdr symbols in lib/, stays green.)
_worker_experimental_only() {
  local sub="${1:-}"
  {
    printf '%s\n' "canopy worker ${sub:-<cmd>}: interactive Herdr workers are an experimental feature not shipped in stable."
    printf '%s\n' "Use \`canopy worker spawn [id]\` for a detached worker, or install the experimental channel: \`canopy setup --channel herdr-preview\`."
  } >&2
  return 2
}

_worker_spawn_claude() {
  local id="${1:?task id}" path="${2:?worktree}" title="${3:?title}" brief="${4:-}" sid settings
  local model; local -a settings_arg=() model_arg=()
  # Pre-trust the leased worktree so claude never stalls on the trust dialog.
  _claude_trust_path "$path"
  # Seed the Stop hook so this worker reports idle + a lifecycle event on completion.
  settings="$(_worker_claude_settings "$id" || true)"
  [ -z "$settings" ] || settings_arg=(--settings "$settings")
  # Pin the worker model (Opus 4.8 by default) at launch — frontmatter model is
  # stripped by _agent_body, so this flag is the ONLY thing that takes effect.
  model="$(_worker_model_for)"; [ -z "$model" ] || model_arg=(--model "$model")
  # CANOPY_ROLE=worker so the worker can't mutate the shared orchestrator .canopy
  # (resolved via git-common-dir); without it the worker inherits orchestrator.
  sid="$( cd "$path" && CANOPY_ROLE=worker claude --bg --dangerously-skip-permissions \
            ${model_arg[@]+"${model_arg[@]}"} \
            ${settings_arg[@]+"${settings_arg[@]}"} \
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
        printf '%s' "$prompt" | CANOPY_ROLE=worker codex "${codex_args[@]}" \
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
        printf '%s' "$prompt" | CANOPY_ROLE=worker codex "${codex_args[@]}" \
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
      # Pre-trust the leased worktree so claude never stalls on the trust dialog.
      _claude_trust_path "$path"
      local settings model; local -a settings_arg=() model_arg=()
      settings="$(_worker_claude_settings "$id" || true)"
      [ -z "$settings" ] || settings_arg=(--settings "$settings")
      # Same worker-model pin as the initial spawn — the fix round must run on the
      # same model, and frontmatter alone can't set it (see _worker_model_for).
      model="$(_worker_model_for)"; [ -z "$model" ] || model_arg=(--model "$model")
      # CANOPY_ROLE=worker so the worker can't mutate the shared orchestrator .canopy
      # (resolved via git-common-dir); without it the worker inherits orchestrator.
      sid="$( cd "$path" && CANOPY_ROLE=worker claude --bg --dangerously-skip-permissions \
                ${model_arg[@]+"${model_arg[@]}"} \
                ${settings_arg[@]+"${settings_arg[@]}"} \
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
  # Two `local` lines on purpose: `local ref=… sid="$ref"` reads $ref before the
  # first assignment lands, which aborts under `set -u` (see AGENTS.md).
  local ref="${1:?worker id or session}"
  local sid="$ref" id="" agent="" logf=""
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
  local ref=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) printf '%s\n' "usage: canopy worker stop <task-id|session-id>"; return 0 ;;
      --) shift; break ;;
      -*) usage_error "unknown flag $1 for 'worker stop'" "valid flags: --help. usage: canopy worker stop <task-id|session-id>" ;;
      *) ref="$1"; shift; [ "$#" -eq 0 ] || usage_error "unexpected argument: $1" "usage: canopy worker stop <task-id|session-id>"; break ;;
    esac
    shift
  done
  if [ -z "$ref" ] && [ "$#" -gt 0 ]; then ref="$1"; fi
  [ -n "$ref" ] || usage_error "missing task-id or session-id" "usage: canopy worker stop <task-id|session-id>"
  require_canopy; need jq
  local tf
  tf="$(task_file "$ref" 2>/dev/null || true)"
  # Automated-cleanup path: `CANOPY_WORKER_CLEANUP=1 canopy worker stop <id>` — the
  # merge-watcher calls this before returning a merged task's worktree, so stop the
  # detached worker process or it keeps running against a returned worktree. Best
  # effort — a completed worker may already have exited.
  if [ -f "$tf" ] && [ "${CANOPY_WORKER_CLEANUP:-0}" = 1 ]; then
    _canopy_worker_stop_headless "$ref" >/dev/null 2>&1 || true
    toon_obj task "$ref" cleaned ok
    return 0
  fi
  _canopy_worker_stop_headless "$ref"
  toon_obj worker "$ref" stopped ok
}

_canopy_worker_stop_headless() {
  local ref sid id="" agent="" pid=""
  ref="${1:?worker id or session}"
  sid="$ref"
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
      _canopy_stop_pid "$pid"
      ;;
  esac
}

_canopy_stop_pid() {
  local pid="${1:-}"
  [ -n "$pid" ] || return 0
  if kill -0 "$pid" >/dev/null 2>&1; then
    kill "$pid" >/dev/null 2>&1 || true
    sleep 1
    kill -0 "$pid" >/dev/null 2>&1 && kill -9 "$pid" >/dev/null 2>&1 || true
  fi
}
