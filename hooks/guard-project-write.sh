#!/usr/bin/env bash
# PreToolUse(Bash) hook — best-effort block on the ORCHESTRATOR writing to the
# project working tree via Bash. Defense-in-depth on top of the orchestrator
# having no Edit/Write tool. Only active when CANOPY_ROLE=orchestrator.
#
# Exit 0 = allow; Exit 2 = block (stderr shown to the model). Reads the tool
# call JSON on stdin ({ tool_name, tool_input:{ command } }).
set -euo pipefail
[ "${CANOPY_ROLE:-}" = "orchestrator" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // .tool_input.cmd // .input.command // .command // empty' 2>/dev/null || true)"
[ -n "$cmd" ] || exit 0

# file-mutation patterns
if printf '%s' "$cmd" | grep -qE '(>>|[^0-9&|]>[^&]|[^0-9&|]>$|sed -i|(^|[^a-z])tee |git apply|git am|git checkout -- |patch +<|dd +of=|^[[:space:]]*(cp|mv|rm|install|truncate|ln)[[:space:]])'; then
  # allow when the only targets are .canopy/, /tmp, or $CLAUDE_* scratch
  if printf '%s' "$cmd" | grep -qE '\.canopy/|/tmp/|\$CLAUDE|CLAUDE_JOB_DIR|CLAUDE_PROJECT_DIR'; then
    exit 0
  fi
  echo "Canopy guard: the orchestrator must not write to the project tree directly. Delegate the change to a worker (canopy worker spawn / canopy hotfix). State edits go through the 'canopy' CLI." >&2
  exit 2
fi
exit 0
