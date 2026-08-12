# state.sh — .canopy/ state layer: init + task board. Sourced, not executed.
# shellcheck shell=bash
#
# state.json (source of truth, the board):
#   { version, updated, mode: yolo|guided, seq, tasks: [ {id,title,status,worktree,branch,pr,worker_session,agent} ] }
# tasks/<id>.json (full detail):
#   { id,title,brief,status,worktree,branch,pr,agent,worker_session,worker_pid,worker_log, log:[{t,msg}] }
# events/lifecycle.json:
#   durable one-shot terminal worker events, consumed by the next Canopy turn.

# --- init -------------------------------------------------------------------
canopy_init() {
  need git; need jq
  local root cdir sf base="" codex_hooks codex_snippet
  # optional: canopy init [--base <branch>]  — set the integration branch now
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) base="${2:?--base needs a branch name}"; shift 2 ;;
      *) die "unknown init arg: $1 (usage: canopy init [--base <branch>])" ;;
    esac
  done
  root="$(repo_root)"
  cdir="$root/.canopy"
  sf="$cdir/state.json"
  mkdir -p "$cdir/tasks"

  if [ -f "$sf" ]; then
    jq_ok "$sf" || die "existing $sf is not valid json"
    info ".canopy/ already initialized"
  else
    printf '%s' '{"version":1,"updated":"","mode":"guided","seq":0,"tasks":[]}' \
      | jq --arg now "$(_c_ts)" '.updated=$now' | write_atomic "$sf"
    info "created $sf"
  fi

  [ -n "$base" ] && state_base "$base"

  [ -f "$cdir/brief.md" ] || printf '# Brief\n\n(intent goes here)\n' > "$cdir/brief.md"

  mkdir -p "$root/.codex"
  codex_hooks="$root/.codex/hooks.json"
  codex_snippet="$root/.codex/canopy-hooks.json"
  if [ -f "$codex_hooks" ]; then
    cp "$CANOPY_ROOT/dist/codex-hooks.json" "$codex_snippet"
    warn "you already have $codex_hooks — I did NOT touch it. Merge the Canopy hooks from $codex_snippet if you want repo-local Codex hooks."
  else
    cp "$CANOPY_ROOT/dist/codex-hooks.json" "$codex_hooks"
    info "wrote $codex_hooks with Canopy Codex hooks"
  fi

  # keep transient task state out of the target repo's PRs
  _gitignore_add "$root" ".canopy/"

  # ensure treehouse is set up for this repo (best-effort, non-fatal)
  if command -v treehouse >/dev/null 2>&1; then
    [ -f "$root/treehouse.toml" ] || (cd "$root" && treehouse init >/dev/null 2>&1 || true)
    info "treehouse ready"
  else
    warn "treehouse not on PATH — workers can't get isolated worktrees until it's installed"
  fi
  info "canopy initialized in $root"
}

_gitignore_add() {
  local root="$1" pat="$2" gi="$1/.gitignore"
  if [ -f "$gi" ] && grep -qxF "$pat" "$gi" 2>/dev/null; then return 0; fi
  printf '%s\n' "$pat" >> "$gi"
}

# --- helpers ----------------------------------------------------------------
_assert_task() { [ -f "$(task_file "$1")" ] || die "no such task: $1"; }
_status_terminal() { case "$1" in done|failed|blocked|interrupted) return 0 ;; *) return 1 ;; esac; }

_lifecycle_init() {
  local ef; ef="$(lifecycle_file)"
  mkdir -p "$(events_dir)"
  [ -f "$ef" ] || printf '%s\n' '{"version":1,"events":[]}' | write_atomic "$ef"
}

# task_lifecycle_event <id> <status> [reason]
# Appends a durable, orchestrator-consumable transition. Returns 0 only when it
# appended a NEW event. Accepts the terminal statuses plus the non-terminal 'idle'
# wake: a worker that finishes its turn and idles at the prompt is a completion
# signal the orchestrator must consume, even though the task itself is not done.
task_lifecycle_event() {
  require_canopy; need jq
  local id="${1:?task id}" status="${2:?status}" reason="${3:-status changed}" tf ef now checkpoint pane tab sid ws agent gen key exists
  _assert_task "$id"; { _status_terminal "$status" || [ "$status" = idle ]; } || return 1
  tf="$(task_file "$id")"; _lifecycle_init; ef="$(lifecycle_file)"; now="$(_c_ts)"
  checkpoint="$(jq -r '.checkpoint.note // empty' "$tf")"
  pane="$(jq -r '.herdr_pane_id // empty' "$tf")"
  tab="$(jq -r '.herdr_tab_id // empty' "$tf")"
  ws="$(jq -r '.herdr_workspace_id // empty' "$tf")"
  agent="$(jq -r '.agent // empty' "$tf")"
  sid="$(jq -r '.herdr_agent_session_id // .worker_session // empty' "$tf")"
  # The generation is bumped each time the worker starts a new active phase (start,
  # resume, or an observed exit from a terminal state). Including it in the dedupe
  # key lets a genuine LATER transition into the same terminal state on the same
  # pane/session wake the orchestrator again, while a repeated probe of the SAME
  # continuous terminal state (same generation) stays deduplicated.
  gen="$(jq -r '.herdr_lifecycle_gen // 0' "$tf")"
  key="${id}|${status}|${pane}|${tab}|${sid}|${gen}"
  exists="$(jq -r --arg key "$key" 'any(.events[]?; .key == $key)' "$ef")"
  [ "$exists" = true ] && return 1
  jq --arg key "$key" --arg id "$id" --arg status "$status" --arg reason "$reason" \
     --arg ws "$ws" --arg pane "$pane" --arg tab "$tab" --arg sid "$sid" --arg agent "$agent" \
     --arg checkpoint "$checkpoint" --arg now "$now" '
    .events += [{
      key:$key, task_id:$id, status:$status, reason:$reason,
      workspace_id:$ws, pane_id:$pane, tab_id:$tab, session_id:$sid, agent:$agent,
      checkpoint:$checkpoint, timestamp:$now, consumed_at:null
    }]
  ' "$ef" | write_atomic "$ef"
  return 0
}

task_lifecycle_list() {
  require_canopy; need jq; _lifecycle_init
  jq -c '.events[] | select(.consumed_at == null)' "$(lifecycle_file)"
}

task_lifecycle_consume() {
  require_canopy; need jq; _lifecycle_init
  local ef out now key; ef="$(lifecycle_file)"; now="$(_c_ts)"
  out="$(jq -c '.events[] | select(.consumed_at == null)' "$ef" | head -1)"
  [ -n "$out" ] || return 1
  key="$(printf '%s\n' "$out" | jq -r '.key')"
  jq --arg key "$key" --arg now "$now" '
    .events |= map(if .key == $key and .consumed_at == null then .consumed_at=$now else . end)
  ' "$ef" | write_atomic "$ef"
  printf '%s\n' "$out"
}

# _events_wake_probe — best-effort: actively probe live Herdr worker panes so a
# terminal outcome (done/failed/blocked/interrupted) is enqueued into
# lifecycle.json even when no launchd supervisor/watcher fires. This runs in the
# ORCHESTRATOR's own foreground process, which holds the user's file-access
# grant, so it works where the launchd push path is dead — macOS TCC blocks
# launchd from reading a repo under ~/Documents|Desktop|Downloads. No-op (and
# never fatal) when Herdr isn't installed; run in a subshell so an inner `die`
# can't abort the wait loop.
_events_wake_probe() {
  command -v "$(_herdr_bin)" >/dev/null 2>&1 || return 0
  ( canopy_herdr_watch_once ) >/dev/null 2>&1 || true
}

canopy_events() {
  local sub="${1:-list}" timeout waited interval
  shift || true
  case "$sub" in
    list) task_lifecycle_list ;;
    consume) task_lifecycle_consume ;;
    wait)
      # PRIMARY, TCC-independent orchestrator wake source. Each interval we (1)
      # actively probe the live Herdr panes ourselves and (2) drain the durable
      # queue, returning the first terminal event as JSON. Events enqueued by the
      # worker's Stop-hook or by a launchd supervisor are consumed here too — the
      # active probe is the backstop for when neither of those fires (TCC).
      timeout="${1:-60}"; interval="${CANOPY_EVENTS_POLL_INTERVAL:-2}"; waited=0
      _events_wake_probe
      task_lifecycle_consume && return 0
      while [ "$waited" -lt "$timeout" ]; do
        sleep "$interval"
        waited=$((waited + interval))
        _events_wake_probe
        task_lifecycle_consume && return 0
      done
      return 1 ;;
    -h|--help) printf '%s\n' 'usage: canopy events [list|consume|wait [seconds]]' ;;
    *) die "unknown 'events' subcommand: $sub" ;;
  esac
}

# --- tasks ------------------------------------------------------------------
# task_add <title...> -> prints new id on stdout
task_add() {
  require_canopy; need jq
  local sf id now title
  sf="$(state_file)"; now="$(_c_ts)"
  title="${*:-untitled}"
  id="$(jq -r '"t\(.seq + 1)"' "$sf")"

  jq --arg id "$id" --arg title "$title" --arg now "$now" '
    .seq += 1 | .updated = $now
    | .tasks += [{id:$id,title:$title,status:"planning",worktree:null,branch:null,pr:null,agent:null,worker_session:null}]
  ' "$sf" | write_atomic "$sf"

  jq -n --arg id "$id" --arg title "$title" --arg now "$now" '
    {id:$id,title:$title,brief:"",status:"planning",worktree:null,branch:null,pr:null,
     agent:null,worker_session:null,worker_pid:null,worker_log:null,log:[{t:$now,msg:"created"}]}
  ' | write_atomic "$(task_file "$id")"

  info "added task $id: $title"
  printf '%s\n' "$id"
}

# task_set <id> <key> <value>
task_set() {
  require_canopy; need jq
  [ "$#" -ge 3 ] || die 'usage: canopy task set <id> <key> <value>'
  local id="${1:?task id}" key="${2:?key}" val="${3}" sf tf now
  _assert_task "$id"
  sf="$(state_file)"; tf="$(task_file "$id")"; now="$(_c_ts)"

  case "$key" in
    title|status|worktree|branch|pr|worker_session|agent)
      jq --arg id "$id" --arg k "$key" --arg v "$val" --arg now "$now" '
        .updated=$now | .tasks |= map(if .id==$id then .[$k]=$v else . end)
      ' "$sf" | write_atomic "$sf" ;;
    *) : ;;  # non-board fields live only in the detail file
  esac

  jq --arg k "$key" --arg v "$val" --arg now "$now" '
    .[$k]=$v | .log += [{t:$now,msg:("set "+$k+"="+$v)}]
  ' "$tf" | write_atomic "$tf"
  info "task $id: $key=$val"
}

# task_status <id> <status>
task_status() {
  require_canopy
  local id="${1:?task id}" st="${2:?status}"
  case "$st" in
    planning|implementing|documenting|checking|reviewing|pr-open|merged|done|failed|blocked|interrupted) ;;
    *) die "invalid status: $st" ;;
  esac
  task_set "$id" status "$st"
  if _status_terminal "$st"; then
    task_lifecycle_event "$id" "$st" "task status set to $st" >/dev/null || true
  fi
}

# task_checkpoint <id> <note...>  (record where the worker "left off" — for recovery)
task_checkpoint() {
  require_canopy; need jq
  local id="${1:?task id}"; shift; local note="${*:?note}"
  _assert_task "$id"
  local tf; tf="$(task_file "$id")"; local now; now="$(_c_ts)"
  jq --arg n "$note" --arg now "$now" \
     '.checkpoint={note:$n,updated:$now} | .log += [{t:$now,msg:("checkpoint: "+$n)}]' \
     "$tf" | write_atomic "$tf"
  info "task $id checkpoint: $note"
}

# task_log <id> <msg...>  (append a timestamped log line to the detail file)
task_log() {
  require_canopy; need jq
  local id="${1:?task id}"; shift
  local tf; tf="$(task_file "$id")"; _assert_task "$id"
  jq --arg now "$(_c_ts)" --arg msg "$*" '.log += [{t:$now,msg:$msg}]' "$tf" | write_atomic "$tf"
}

# task_show <id>
task_show() { require_canopy; _assert_task "${1:?task id}"; cat "$(task_file "$1")"; }

# --- board / mode -----------------------------------------------------------
# canopy status [--all]. Bare = this repo's board (unchanged). --all spans every
# registered project under projects/, printing each board under a project header
# with task ids shown as <name>:tN — a DISPLAY prefix only; stored ids/seq are
# never touched.
state_board() {
  if [ "${1:-}" = "--all" ]; then shift; state_board_all "$@"; return $?; fi
  require_canopy; need jq
  _state_board_one ""
}

# _state_board_one [id-prefix] — render the CURRENT repo's board to stderr. With
# an id-prefix (e.g. "demo:") each task id is shown as <prefix><id> for display
# only. Empty prefix reproduces the historical single-repo output byte-for-byte.
_state_board_one() {
  local prefix="${1:-}" sf; sf="$(state_file)"
  info "mode: $(jq -r '.mode' "$sf")"
  if [ "$(jq '.tasks|length' "$sf")" -eq 0 ]; then log "(no tasks)"; return 0; fi
  jq -r --arg p "$prefix" '.tasks[] | "  \($p)\(.id)\t\(.status)\t\(.title)" + (if .pr then "  (PR #\(.pr))" else "" end)' "$sf" >&2
}

# canopy status --all — every registered project's board, ids namespaced <name>:tN.
# Never require_canopy: the orchestrator's own repo may have no board; each project
# with a board is rendered via a subshell cd so repo_root()/state_file() rescope.
state_board_all() {
  need git; need jq
  local repos=() d
  while IFS= read -r d; do [ -n "$d" ] && repos+=("$d"); done < <(_project_repos)
  if [ "${#repos[@]}" -eq 0 ]; then info "status --all: no projects registered"; return 0; fi
  local name
  for d in ${repos[@]+"${repos[@]}"}; do
    name="$(basename "$d")"
    log ""
    log "project: $name"
    if [ -f "$d/.canopy/state.json" ]; then
      ( cd "$d" && _state_board_one "$name:" )
    else
      log "  (no board)"
    fi
  done
}

# state_mode [--global] [yolo|guided]
# Bare (single-repo behavior, unchanged): get/set THIS repo's own .mode.
# --global: PRINT the orchestrator HOME repo's mode regardless of cwd — the home
#   is the git repo whose projects/ contains the current repo (else the current
#   repo itself, resolved by _home_root). This is the one autonomy switch the
#   orchestrator applies to every routed project; each project's own stored .mode
#   is SUPERSEDED, never mutated. Read-only: flip the session mode with a bare
#   `canopy mode yolo|guided` in the home repo. Falls back to "guided" (the
#   default) when the home has no board yet.
state_mode() {
  need jq
  if [ "${1:-}" = "--global" ]; then
    shift
    [ $# -eq 0 ] || die "canopy mode --global is read-only — set the session mode with 'canopy mode yolo|guided' in the orchestrator home repo"
    local home hsf; home="$(_home_root)"; hsf="$home/.canopy/state.json"
    if [ -f "$hsf" ]; then jq -r '.mode // "guided"' "$hsf"; else printf '%s\n' guided; fi
    return 0
  fi
  require_canopy
  local sf; sf="$(state_file)"
  if [ $# -eq 0 ]; then jq -r '.mode' "$sf"; return 0; fi
  case "$1" in yolo|guided) ;; *) die "mode must be yolo or guided" ;; esac
  jq --arg m "$1" --arg now "$(_c_ts)" '.mode=$m|.updated=$now' "$sf" | write_atomic "$sf"
  info "mode set to $1"
}

# state_base [branch]
# No arg: print the EFFECTIVE base (configured, else auto-detected).
# With arg: set the integration branch every worktree is cut from and every
# PR/review targets — for repos whose real base isn't the default (e.g. develop).
state_base() {
  require_canopy; need jq
  local sf root; sf="$(state_file)"; root="$(repo_root)"
  if [ $# -eq 0 ]; then base_branch "$root"; return 0; fi
  local br="$1"
  if ! git -C "$root" show-ref --verify --quiet "refs/heads/$br" \
     && ! git -C "$root" show-ref --verify --quiet "refs/remotes/origin/$br"; then
    warn "base '$br' not found locally or on origin — set anyway; it'll be fetched when a worktree is leased"
  fi
  jq --arg b "$br" --arg now "$(_c_ts)" '.base=$b|.updated=$now' "$sf" | write_atomic "$sf"
  info "base branch set to $br (worktrees cut from it; PRs target it)"
}
