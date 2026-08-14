# recover.sh — resume orphaned in-flight tasks after a /clear. Sourced.
# shellcheck shell=bash
#
# In-session workers (the steerable default) die when the orchestrator is /clear'd.
# Recovery is durable elsewhere: .canopy/ state + the committed worktree survive.
# `canopy recover` reconstructs a resume-brief (intent + what's committed + last
# checkpoint) so the orchestrator re-spawns a worker that CONTINUES, not restarts.

# statuses that mean "work is in flight and should resume if orphaned"
CANOPY_ACTIVE_RE='implementing|documenting|checking|reviewing'

# canopy recover list  -> ids of in-flight tasks
canopy_recover_list() {
  require_canopy; need jq
  jq -r --arg re "$CANOPY_ACTIVE_RE" '.tasks[] | select(.status|test($re)) | .id' "$(state_file)"
}

# canopy recover [<id>]  -> print a resume-brief for in-flight task(s)
# canopy recover --all   -> run the same per-repo recover in every registered project.
# shellcheck disable=SC2120  # also invoked bare (no args) by canopy_recover_all
canopy_recover() {
  if [ "${1:-}" = "--all" ]; then shift; canopy_recover_all "$@"; return $?; fi
  require_canopy; need jq; need git
  local ids ev saw_event=0
  if [ "${1:-}" = "list" ]; then canopy_recover_list; return 0; fi

  # Redundancy for the merge-watcher (Layers 1 & 2): on every startup/recover,
  # reconcile merged PRs ourselves — this runs in the session's permission context,
  # so merges are caught even if the background watcher is dead or TCC-blocked —
  # and re-arm the daemon if it dropped. Best-effort; never blocks recovery.
  canopy_watch_once >/dev/null 2>&1 || true
  canopy_watch_ensure >/dev/null 2>&1 || true

  while ev="$(task_lifecycle_consume 2>/dev/null)"; do
    saw_event=1
    printf '%s\n' "$ev" | jq -r '"### CANOPY EVENT task \(.task_id) [\(.status)]\nreason: \(.reason)\npane:   \(.pane_id // "")\ntab:    \(.tab_id // "")\nsession:\(.session_id // "")\ncheckpoint: \(.checkpoint // "")\nat: \(.timestamp)\n"'
  done
  [ "$saw_event" = 1 ] && printf '\n'

  if [ $# -gt 0 ]; then ids="$1"; else ids="$(canopy_recover_list)"; fi
  if [ -z "$ids" ]; then info "recover: nothing in flight"; return 0; fi

  while read -r id; do
    [ -n "$id" ] || continue
    local tf status wt branch brief ckpt committed base
    tf="$(task_file "$id")"; [ -f "$tf" ] || continue
    status="$(jq -r '.status' "$tf")"
    wt="$(jq -r '.worktree // empty' "$tf")"
    branch="$(jq -r '.branch // empty' "$tf")"
    brief="$(jq -r '.brief // ""' "$tf")"
    ckpt="$(jq -r '.checkpoint.note // "(none yet)"' "$tf")"
    committed="  (nothing committed yet)"
    if [ -n "$wt" ] && [ -d "$wt" ]; then
      base="$(git -C "$wt" merge-base HEAD "$(base_branch "$wt")" 2>/dev/null || echo '')"
      if [ -n "$base" ]; then
        local log; log="$(git -C "$wt" log --oneline "$base"..HEAD 2>/dev/null)"
        [ -n "$log" ] && committed="$log"
      fi
    fi
    cat <<EOF
### RESUME task ${id}  [status: ${status}]
worktree: ${wt:-<none>}
branch:   ${branch:-<none>}
intent:   ${brief:-<none>}
last checkpoint: ${ckpt}
committed so far:
${committed}

EOF
    cat <<EOF
→ Re-spawn a worker in this worktree (steerable, in-session) and CONTINUE from the checkpoint. Do not redo committed work.
EOF
  done <<< "$ids"
}

# canopy recover --all  -> iterate every registered project under projects/ and
# run the existing per-repo recover in each (re-arm watcher, reconcile merged
# PRs, report in-flight). The orchestrator's own repo may have no .canopy/, so we
# never require_canopy here — we cd into each project and let its own board drive
# recover. A project that is a bare git repo with no board is skipped, not fatal.
canopy_recover_all() {
  need git; need jq
  local repos=() d
  while IFS= read -r d; do [ -n "$d" ] && repos+=("$d"); done < <(_project_repos)
  if [ "${#repos[@]}" -eq 0 ]; then info "recover --all: no projects registered"; return 0; fi
  local name
  for d in ${repos[@]+"${repos[@]}"}; do
    name="$(basename "$d")"
    printf '\n=== project: %s ===\n' "$name"
    if [ -f "$d/.canopy/state.json" ]; then
      ( cd "$d" && canopy_recover ) || warn "recover --all: $name had an issue"
    else
      info "recover --all: $name has no board — skipping"
    fi
  done
}
