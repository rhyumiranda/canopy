# consult.sh — headless launch path for the ADVISORY agents (oracle, plan-gate).
# Sourced, not executed.
# shellcheck shell=bash
#
# The oracle/plan-gate defs ship in agents/ but canopy only ever launched
# worker/reviewer/orchestrator, so a DETACHED worker (`canopy worker spawn`) had
# no way to reach a consultant mid-task. This adds a headless `claude` launch
# modeled exactly on the reviewer in lib/review.sh:
#     claude -p [--model M] --allowedTools Read Grep Glob \
#            --append-system-prompt "$(_agent_body <agent>)" "<prompt>"
#
# CRITICAL: `_agent_body` (lib/agent.sh) STRIPS the YAML frontmatter, so the
# def's `model:` line is lost on this path. We parse it back out of the def
# ourselves and pass it explicitly via --model; with no `model:` line we omit
# the flag and inherit the ambient model. (Same lesson the reviewer learned.)

# _agent_model <agent-name> -> the def's `model:` value, or empty.
# grep+sed (not awk) so it parses identically under CI's mawk. Scoped to the
# leading frontmatter block (lines between the first two `---` fences) so a stray
# `model:` in prose can't leak in.
_agent_model() {
  local def="$CANOPY_ROOT/agents/$1.md" m
  [ -f "$def" ] || return 0
  m="$(sed -n '2,/^---$/p' "$def" | grep -m1 '^model:' | sed 's/^model:[[:space:]]*//; s/[[:space:]]*$//' | tr -d '\r')" || m=""
  printf '%s' "$m"
}

_consult_plans_dir() { echo "$(canopy_dir)/plans"; }

# _consult_run <agent> <prompt> [cwd] -> the agent's raw stdout.
# Builds the argv incrementally so --model is present ONLY when the def pins one.
# When a cwd is given (a leased worktree the agent should read), pre-mark it
# trusted first (Claude's folder-trust gate is separate from tool permissions and
# would otherwise wedge a headless launch), then run with cwd set there.
_consult_run() {
  local agent="$1" prompt="$2" cwd="${3:-}" body model out
  body="$(_agent_body "$agent")"
  model="$(_agent_model "$agent")" || model=""
  local -a args
  args=(-p)
  [ -n "$model" ] && args+=(--model "$model")
  args+=(--allowedTools Read Grep Glob --append-system-prompt "$body" "$prompt")
  if [ -n "$cwd" ]; then
    _claude_trust_path "$cwd"
    out="$( cd "$cwd" && claude ${args[@]+"${args[@]}"} 2>/dev/null )" || out=""
  else
    out="$( claude ${args[@]+"${args[@]}"} 2>/dev/null )" || out=""
  fi
  printf '%s' "$out"
}

# canopy oracle [-C <worktree>] "<question>"
# A read-only consultant a worker/orchestrator calls mid-task for one high-stakes
# decision. Returns the agent's prose guidance on stdout. Pass -C/--cwd a leased
# worktree so the oracle can read that code; otherwise it runs in the cwd.
canopy_oracle() {
  require_canopy; need claude
  local cwd="" q out
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -C|--cwd) shift; cwd="${1:-}"; [ -n "$cwd" ] || die "canopy oracle: -C/--cwd needs a path" ;;
      -h|--help)
        cat <<'EOF'
usage: canopy oracle [-C <worktree>] "<question>"

Ask the read-only Canopy oracle (advisory prose, not a verdict) for one
high-stakes mid-task decision. -C points it at a leased worktree to read.
EOF
        return 0 ;;
      --) shift; break ;;
      -*) die "canopy oracle: unknown flag: $1" ;;
      *) break ;;
    esac
    shift
  done
  q="$*"
  [ -n "$q" ] || die "usage: canopy oracle [-C <worktree>] \"<question>\""
  if [ -n "$cwd" ]; then
    [ -d "$cwd" ] || die "canopy oracle: -C path is not a directory: $cwd"
    cwd="$(cd "$cwd" 2>/dev/null && pwd)" || die "canopy oracle: cannot resolve -C path"
  fi
  out="$(_consult_run oracle "$q" "$cwd")" || out=""
  printf '%s\n' "$out"
}

# canopy plan-gate <task-id>
# A fresh-context reviewer of the plan artifact at .canopy/plans/<id>.md. Reads
# the plan, launches the plan-gate agent (cwd = repo root so it can check the
# plan against the real code), and prints the structured verdict JSON.
canopy_plan_gate() {
  require_canopy; need claude; need jq
  local id="" planf plan prompt out
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        cat <<'EOF'
usage: canopy plan-gate <task-id>

Gate the plan at .canopy/plans/<task-id>.md with the fresh-context plan-gate
agent. Prints the structured approve/revise verdict JSON.
EOF
        return 0 ;;
      --) shift; id="${1:-}"; break ;;
      -*) die "canopy plan-gate: unknown flag: $1" ;;
      *) id="$1"; break ;;
    esac
    shift
  done
  [ -n "$id" ] || die "usage: canopy plan-gate <task-id>"
  planf="$(_consult_plans_dir)/$id.md"
  [ -f "$planf" ] || die "no plan artifact at $planf"
  plan="$(cat "$planf")" || plan=""
  prompt="$(printf 'Gate the plan for task %s below. Read the real code it references, then return ONLY the JSON verdict.\n\n%s' "$id" "$plan")"
  out="$(_consult_run plan-gate "$prompt")" || out=""
  # plan-gate emits JSON; pull it out of any fencing/prose (shared with review.sh).
  printf '%s' "$out" | _extract_json
}
