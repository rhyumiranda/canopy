#!/usr/bin/env bash
# PreToolUse(Bash) hook — block opening a PR directly with gh/gh-axi. Every PR
# must go through `canopy pr open`, which renders the ONE standard PR body and
# enforces the review + checks gate; a direct `gh pr create` bypasses both and is
# how PR formats drift. Only active when CANOPY_ROLE=orchestrator (the PR-opener).
#
# Exit 0 = allow; Exit 2 = block (stderr shown to the model). Reads the tool call
# JSON on stdin ({ tool_name, tool_input:{ command } }).
set -euo pipefail
[ "${CANOPY_ROLE:-}" = "orchestrator" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -n "$cmd" ] || exit 0

# Match `gh pr create` / `gh-axi pr create` (any spacing), not `canopy pr open`.
if printf '%s' "$cmd" | grep -qE '(^|[^a-zA-Z0-9_./-])gh(-axi)?[[:space:]]+pr[[:space:]]+create'; then
  echo "Canopy guard: open PRs with 'canopy pr open <id>', never 'gh/gh-axi pr create' directly — that bypasses the standard PR template and the review+checks gate." >&2
  exit 2
fi
exit 0
