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
canopy_recover() {
  require_canopy; need jq; need git
  local ids
  if [ "${1:-}" = "list" ]; then canopy_recover_list; return 0; fi
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
      base="$(git -C "$wt" merge-base HEAD "$(_default_branch "$wt")" 2>/dev/null || echo '')"
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

→ Re-spawn a worker in this worktree (steerable, in-session) and CONTINUE from the checkpoint. Do not redo committed work.
EOF
  done <<< "$ids"
}
