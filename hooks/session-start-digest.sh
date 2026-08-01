#!/usr/bin/env bash
# SessionStart hook — re-inject a <=10k digest of .canopy/state.json so the
# orchestrator re-orients after startup/resume/clear/compact. No-op outside a
# canopy repo. Emits the documented hookSpecificOutput JSON on stdout.
set -euo pipefail
root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
sf="$root/.canopy/state.json"
[ -f "$sf" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

mode="$(jq -r '.mode // "guided"' "$sf")"
board="$(jq -r '.tasks[]? | "- \(.id) [\(.status)] \(.title)" + (if .pr then " (PR #\(.pr))" else "" end)' "$sf" 2>/dev/null || true)"
[ -n "$board" ] || board="(no tasks yet)"

digest="CANOPY STATE — source of truth is .canopy/state.json (read it for full detail).
mode: ${mode}
tasks:
${board}

You are the orchestrator: read .canopy/ first, delegate all project-code changes to workers, never edit the project tree yourself."

# hard cap well under the 10k additionalContext limit
digest="${digest:0:9500}"

jq -n --arg c "$digest" \
  '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}'
