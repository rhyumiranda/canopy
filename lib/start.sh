# start.sh — launch an interactive agent session that IS the orchestrator. Sourced.
# shellcheck shell=bash
#
# This is the "just works" entry point. `canopy start` opens Claude Code with the
# orchestrator playbook loaded and CANOPY_ROLE=orchestrator set (so the write-guard
# hook is active), then orients itself from .canopy/ and recovers in-flight work.
# `canopy start --codex` is experimental: Codex gets the same playbook in the
# initial prompt because it has no Claude-style --append-system-prompt flag.

canopy_start() {
  require_canopy
  local dry=0 agent="${CANOPY_AGENT:-claude}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1 ;;
      --agent) shift; agent="$(_canopy_agent_validate "${1:-}")" ;;
      --codex) agent=codex ;;
      --claude) agent=claude ;;
      -h|--help)
        cat <<'EOF'
usage: canopy start [--dry-run] [--agent claude|codex] [--claude|--codex]

  --agent   Launch the selected runtime
  --claude  Alias for --agent claude
  --codex   Alias for --agent codex
EOF
        return 0 ;;
      *) die "unknown start option: $1" ;;
    esac
    shift
  done
  local body prompt
  body="$(_agent_body orchestrator)"
  [ -n "$body" ] || die "orchestrator agent def not found — run from the canopy repo, or 'canopy setup' first"

  prompt="You are the Canopy orchestrator for this repo. First run \`canopy recover\` and \`canopy status\`, summarize the board and any in-flight work, then wait for my intent. Delegate every code change to a worker; never edit the project tree yourself."

  if [ "$dry" = 1 ]; then
    log "[dry-run] would launch:"
    if [ "$agent" = codex ]; then
      log "  CANOPY_ROLE=orchestrator CANOPY_ORCHESTRATOR_AGENT=codex codex -s ${CANOPY_CODEX_START_SANDBOX:-workspace-write} -a ${CANOPY_CODEX_START_APPROVAL:-never} \"<orchestrator playbook + orient prompt: $((${#body} + ${#prompt})) chars>\""
    else
      log "  CANOPY_ROLE=orchestrator CANOPY_ORCHESTRATOR_AGENT=claude claude --append-system-prompt <orchestrator playbook: ${#body} chars> \"<orient prompt>\""
    fi
    return 0
  fi

  if [ "$agent" = codex ]; then
    need codex
    info "launching Codex as the Canopy orchestrator..."
    CANOPY_ROLE=orchestrator CANOPY_ORCHESTRATOR_AGENT=codex exec codex -s "${CANOPY_CODEX_START_SANDBOX:-workspace-write}" -a "${CANOPY_CODEX_START_APPROVAL:-never}" "$(printf '%s\n\n%s\n' "$body" "$prompt")"
  else
    need claude   # only a real launch needs claude; --dry-run is a dependency-free preview
    info "launching Claude Code as the Canopy orchestrator..."
    CANOPY_ROLE=orchestrator CANOPY_ORCHESTRATOR_AGENT=claude exec claude --append-system-prompt "$body" "$prompt"
  fi
}
