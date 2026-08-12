#!/usr/bin/env bash
# PreToolUse(Bash) hook — best-effort block on the ORCHESTRATOR writing to the
# project working tree via Bash. Defense-in-depth on top of the orchestrator
# having no Edit/Write tool. Only active when CANOPY_ROLE=orchestrator.
#
# Exit 0 = allow; Exit 2 = block (stderr shown to the model). Reads the tool
# call JSON on stdin ({ tool_name, tool_input:{ command } }).
#
# DRAIN STDIN FIRST, before any early exit. Exiting while the harness is still
# writing the JSON into the pipe delivers SIGPIPE to the writer, and under its
# `set -o pipefail` that surfaces as a flaky exit 141. Read to EOF, then decide.
set -euo pipefail
input="$(cat)"

[ "${CANOPY_ROLE:-}" = "orchestrator" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // .tool_input.cmd // .input.command // .command // empty' 2>/dev/null || true)"
[ -n "$cmd" ] || exit 0

# --- worker-worktree exemption -------------------------------------------------
# In-session workers inherit CANOPY_ROLE=orchestrator from the parent, but they
# run in their OWN treehouse-leased LINKED worktree and are MEANT to write there.
# Exempt when the session cwd is a linked worktree (robust, convention-free: a
# linked worktree's git-dir lives under .../.git/worktrees/<name>) or, as a
# belt-and-suspenders fallback, sits under the treehouse pool path.
_in_worker_worktree() {
  case "$PWD" in */.treehouse/*) return 0 ;; esac
  local gd
  gd="$(git -C "$PWD" rev-parse --absolute-git-dir 2>/dev/null)" || gd=""
  case "$gd" in */worktrees/*) return 0 ;; esac
  return 1
}
if _in_worker_worktree; then exit 0; fi

# --- de-quote ------------------------------------------------------------------
# Strip single- and double-quoted spans BEFORE any redirect/mutation scan, so a
# literal <name>, a>b, or a '>' inside a quoted arg (commit messages, CLI values)
# never looks like a redirection. Real project-tree writes are never hidden
# inside quotes; the trade-off (a quoted redirect target slips through) is
# acceptable for a best-effort defense-in-depth guard.
stripped="$(printf '%s' "$cmd" | sed -e 's/"[^"]*"//g' -e "s/'[^']*'//g")"

# Project working-tree root, for resolving relative redirect targets. When git
# can't answer (not a repo), fall back to the session cwd — the orchestrator's
# cwd IS the project tree, so a relative write still resolves in-tree.
TREE_ROOT="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)" || TREE_ROOT=""
[ -n "$TREE_ROOT" ] || TREE_ROOT="$PWD"

BLOCK_MSG="Canopy guard: the orchestrator must not write to the project tree directly. Delegate the change to a worker (canopy worker spawn / canopy hotfix). State edits go through the 'canopy' CLI."

# _target_in_tree <redirect-target> -> 0 if it lands inside the project tree
# (block-worthy), 1 if it is out-of-tree / scratch / state (allowed).
_target_in_tree() {
  local t="$1" abs
  case "$t" in
    /dev/null|/dev/*)                       return 1 ;;  # not a file in the tree
    *.canopy/*|*CLAUDE*)                    return 1 ;;  # state / $CLAUDE_* scratch
    /tmp/*|*/.treehouse/*)                  return 1 ;;  # scratch / another worktree
    '~'*|'$'*)                              return 1 ;;  # unresolved expansion, best-effort allow
    /*)  abs="$t" ;;                                     # absolute path
    *)   abs="$TREE_ROOT/$t" ;;                          # relative to the project tree
  esac
  case "$abs" in
    "$TREE_ROOT"/*|"$TREE_ROOT") return 0 ;;             # lands inside the project tree
    *)                           return 1 ;;             # out of tree
  esac
}

# Precise redirect scan: block only when a real '>' / '>>' target resolves inside
# the project tree. Non-project targets (/dev/null, /tmp, out-of-tree absolute
# paths, $CLAUDE scratch) are allowed.
targets="$(printf '%s' "$stripped" | grep -oE '>>?[[:space:]]*[^[:space:];|&<>()]+' | sed -E 's/^>>?[[:space:]]*//')" || targets=""
if [ -n "$targets" ]; then
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if _target_in_tree "$t"; then
      echo "$BLOCK_MSG" >&2
      exit 2
    fi
  done <<EOF
$targets
EOF
fi

# Non-redirect mutation verbs. These are harder to target-analyse robustly, so
# keep the allow-list heuristic: block unless a scratch/state/out-of-tree marker
# is present.
if printf '%s' "$stripped" | grep -qE '(sed -i|(^|[^a-z])tee |git apply|git am|git checkout -- |patch +<|dd +of=|^[[:space:]]*(cp|mv|rm|install|truncate|ln)[[:space:]])'; then
  if printf '%s' "$stripped" | grep -qE '\.canopy/|/tmp/|/dev/|/\.treehouse/|CLAUDE'; then
    exit 0
  fi
  echo "$BLOCK_MSG" >&2
  exit 2
fi
exit 0
