# state.sh — .canopy/ state layer: init + task board. Sourced, not executed.
# shellcheck shell=bash
#
# state.json (source of truth, the board):
#   { version, updated, mode: yolo|guided, seq, tasks: [ {id,title,status,worktree,branch,pr,worker_session} ] }
# tasks/<id>.json (full detail):
#   { id,title,brief,status,worktree,branch,pr,worker_session, log:[{t,msg}] }

# --- init -------------------------------------------------------------------
canopy_init() {
  need git; need jq
  local root cdir sf base=""
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
    | .tasks += [{id:$id,title:$title,status:"planning",worktree:null,branch:null,pr:null,worker_session:null}]
  ' "$sf" | write_atomic "$sf"

  jq -n --arg id "$id" --arg title "$title" --arg now "$now" '
    {id:$id,title:$title,brief:"",status:"planning",worktree:null,branch:null,pr:null,
     worker_session:null, log:[{t:$now,msg:"created"}]}
  ' | write_atomic "$(task_file "$id")"

  info "added task $id: $title"
  printf '%s\n' "$id"
}

# task_set <id> <key> <value>
task_set() {
  require_canopy; need jq
  local id="${1:?task id}" key="${2:?key}" val="${3:?value}" sf tf now
  _assert_task "$id"
  sf="$(state_file)"; tf="$(task_file "$id")"; now="$(_c_ts)"

  case "$key" in
    title|status|worktree|branch|pr|worker_session)
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
    planning|implementing|documenting|checking|reviewing|pr-open|merged|done|blocked) ;;
    *) die "invalid status: $st" ;;
  esac
  task_set "$id" status "$st"
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
state_board() {
  require_canopy; need jq
  local sf; sf="$(state_file)"
  info "mode: $(jq -r '.mode' "$sf")"
  if [ "$(jq '.tasks|length' "$sf")" -eq 0 ]; then log "(no tasks)"; return 0; fi
  jq -r '.tasks[] | "  \(.id)\t\(.status)\t\(.title)" + (if .pr then "  (PR #\(.pr))" else "" end)' "$sf" >&2
}

# state_mode [yolo|guided]
state_mode() {
  require_canopy; need jq
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
