#!/usr/bin/env bash
# SessionStart hook — re-inject a <=10k digest of .canopy/state.json so the
# ORCHESTRATOR re-orients after startup/resume/clear/compact. No-op outside a
# canopy repo. Only the full orchestrator playbook+board is injected when
# CANOPY_ROLE=orchestrator; any other session in a canopy repo (e.g. a plain
# Claude/Herdr session) gets only a one-line hint, so it never mistakes itself
# for the orchestrator. Claude expects hookSpecificOutput JSON; Codex accepts
# plain text.
set -euo pipefail
root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
sf="$root/.canopy/state.json"
[ -f "$sf" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

if [ "${CANOPY_ROLE:-}" = "orchestrator" ]; then
  mode="$(jq -r '.mode // "guided"' "$sf")"
  board="$(jq -r '.tasks[]? | "- \(.id) [\(.status)] \(.title)" + (if .pr then " (PR #\(.pr))" else "" end)' "$sf" 2>/dev/null || true)"
  [ -n "$board" ] || board="(no tasks yet)"

  # Registered projects: any git repo directly under this home repo's projects/.
  # This home repo's own .mode is the session-wide (global) mode applied to them all.
  projects=""
  for d in "$root"/projects/*/; do
    d="${d%/}"
    [ -e "$d/.git" ] || continue
    projects="${projects}- $(basename "$d")
"
  done
  if [ -n "$projects" ]; then
    projects="registered projects (route by name; global mode ${mode} applies to all):
${projects}"
  else
    projects=""
  fi

  digest="CANOPY STATE — source of truth is .canopy/state.json (read it for full detail).
global mode: ${mode} (this home repo's .mode; applies to every routed project)
home board:
${board}
${projects}
You are the orchestrator: read .canopy/ first, delegate all project-code changes to workers, never edit the project tree yourself.
Startup: run \`canopy recover --all\` and show \`canopy project ls\` so the human sees every project + in-flight work.
Route a named request with \`canopy project path <name>\`, cd there, then run the normal loop in that project's board. Canopy itself is the home, never a routed project under projects/."
else
  # Not the orchestrator: don't hand over the board or claim the role. Just hint.
  digest="This is a Canopy repo — run \`canopy start\` to orchestrate."
fi

# hard cap well under the 10k additionalContext limit
digest="${digest:0:9500}"

if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  jq -n --arg c "$digest" \
    '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}'
else
  printf '%s\n' "$digest"
fi
