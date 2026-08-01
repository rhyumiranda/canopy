# start.sh — launch an interactive Claude Code session that IS the orchestrator. Sourced.
# shellcheck shell=bash
#
# This is the "just works" entry point. `canopy start` opens Claude Code with the
# orchestrator playbook loaded and CANOPY_ROLE=orchestrator set (so the write-guard
# hook is active), then orients itself from .canopy/ and recovers in-flight work.

canopy_start() {
  require_canopy; need claude
  local dry=0; [ "${1:-}" = "--dry-run" ] && dry=1
  local body prompt
  body="$(_agent_body orchestrator)"
  [ -n "$body" ] || die "orchestrator agent def not found — run from the canopy repo, or 'canopy setup' first"

  prompt="You are the Canopy orchestrator for this repo. First run \`canopy recover\` and \`canopy status\`, summarize the board and any in-flight work, then wait for my intent. Delegate every code change to a worker; never edit the project tree yourself."

  if [ "$dry" = 1 ]; then
    log "[dry-run] would launch:"
    log "  CANOPY_ROLE=orchestrator claude --append-system-prompt <orchestrator playbook: ${#body} chars> \"<orient prompt>\""
    return 0
  fi

  info "launching Claude Code as the Canopy orchestrator…"
  CANOPY_ROLE=orchestrator exec claude --append-system-prompt "$body" "$prompt"
}
