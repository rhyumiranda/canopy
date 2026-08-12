# scribe.sh — durable, cross-task project knowledge -> AGENTS.md. Sourced.
# shellcheck shell=bash
#
# AGENTS.md is COMMITTED (every agent auto-loads it) — distinct from the per-change
# "document" step and from the gitignored .canopy/ runtime state. Only durable,
# project-intrinsic facts belong here. The judgment (the /scribe ladder) is the
# model's; this file is the sanctioned WRITE path, so curation stays guard-safe
# even for the orchestrator (which has no Edit/Write on the project tree).
#
# File shape the CLI maintains:
#   # AGENTS.md
#   <intro>
#   ## Maintaining this file      <- the durability bar; travels IN the file so
#   <bar, plain prose>               every future editor re-reads it before writing
#   - <fact>                      <- entries: every line starting with "- "
#
# The bar is prose (no leading dash) so entry-parsing ('^- ') never mistakes it
# for a knowledge entry. Entries cluster at the end because 'add' appends there.
#
# Primitives (mechanism only): list / add / replace / rm / show.
# Inspect-then-update: list first, then replace/rm a related entry instead of
# blindly appending — that's how the file stays lean instead of a junk drawer.

# Over this many entries, 'add' warns you to prune/merge (soft, non-blocking).
CANOPY_SCRIBE_SOFT_MAX="${CANOPY_SCRIBE_SOFT_MAX:-40}"

# AGENTS.md is versioned documentation, so it belongs on the CURRENT working
# branch — resolve it from the tree we are in (show-toplevel), NOT repo_root.
# repo_root() intentionally follows git-common-dir to the MAIN tree so gitignored
# .canopy/ state stays a single shared board; using it here would write a worker's
# entry into the main checkout, off its branch, never riding the PR. State stays
# on git-common-dir; only AGENTS.md moves to the worktree.
_scribe_file() {
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
  echo "$top/AGENTS.md"
}

# The durability bar — plain sentences, one per line (never "- ", see above).
_scribe_bar() {
  cat <<'EOF'
## Maintaining this file

Keep only knowledge useful to almost every future agent session in this project.
Don't repeat what the code already shows — point to the file, function, or command instead.
Prefer rewriting or pruning an existing entry over adding a new one; skip trivial tasks that taught nothing durable.
Keep each entry to one line, action first.
EOF
}

_scribe_skeleton() {
  local am="$1"
  {
    printf '# AGENTS.md\n\n'
    printf 'Durable, project-intrinsic knowledge (curated by `/scribe`). Non-obvious facts that change future actions — not task notes.\n\n'
    _scribe_bar
    printf '\n'
  } > "$am"
}

# Add the bar to a file that lacks it (a legacy or foreign AGENTS.md), placed
# just before the first entry so the rule is read before the facts. Idempotent.
_scribe_ensure_bar() {
  local am="$1" first tmp
  grep -qxF '## Maintaining this file' "$am" 2>/dev/null && return 0
  first="$(grep -n '^- ' "$am" 2>/dev/null | head -1 | cut -d: -f1 || true)"
  tmp="$(mktemp "${am}.XXXXXX")"
  if [ -n "$first" ]; then
    { head -n "$((first - 1))" "$am"; _scribe_bar; printf '\n'; tail -n "+$first" "$am"; } > "$tmp"
  else
    { cat "$am"; printf '\n'; _scribe_bar; } > "$tmp"
  fi
  mv -f "$tmp" "$am"
}

_scribe_count() {
  local n; n="$(grep -c '^- ' "$1" 2>/dev/null || true)"; echo "${n:-0}"
}

_scribe_budget_warn() {
  local am="$1" n; n="$(_scribe_count "$am")"
  [ "$n" -gt "$CANOPY_SCRIBE_SOFT_MAX" ] && \
    warn "AGENTS.md has $n entries (soft max $CANOPY_SCRIBE_SOFT_MAX) — prune or merge stale ones ('canopy scribe list', then 'rm'/'replace')"
  return 0
}

_scribe_assert_index() {
  local n="$1" total="$2"
  case "$n" in ''|*[!0-9]*) die "entry number must be a positive integer: $n" ;; esac
  { [ "$n" -ge 1 ] && [ "$n" -le "$total" ]; } || die "no entry #$n (have $total; try 'canopy scribe list')"
}

# canopy scribe list  -> numbered entries (the inspect step, run this first)
canopy_scribe_list() {
  local am; am="$(_scribe_file)"
  [ -f "$am" ] || { info "scribe: no AGENTS.md yet"; return 0; }
  [ "$(_scribe_count "$am")" = 0 ] && { info "scribe: no entries yet"; return 0; }
  awk '/^- / { printf "%2d  %s\n", ++i, substr($0, 3) }' "$am"
}

# canopy scribe add "<fact>"  -> append a new entry (after inspecting via list)
canopy_scribe_add() {
  need git
  local fact="${*:?fact}"
  local am; am="$(_scribe_file)"
  [ -f "$am" ] || _scribe_skeleton "$am"
  _scribe_ensure_bar "$am"
  local line="- $fact"
  if grep -qxF -- "$line" "$am" 2>/dev/null; then info "scribe: already recorded — skipped"; return 0; fi
  printf '%s\n' "$line" >> "$am"
  info "scribe: recorded to AGENTS.md"
  _scribe_budget_warn "$am"
}

# canopy scribe replace <n> "<fact>"  -> supersede entry n (rewrite/prune-in-place)
canopy_scribe_replace() {
  need git
  local n="${1:?entry number}"; shift || true
  local fact="${*:?new fact}"
  local am; am="$(_scribe_file)"
  [ -f "$am" ] || die "no AGENTS.md yet"
  _scribe_assert_index "$n" "$(_scribe_count "$am")"
  local tmp; tmp="$(mktemp "${am}.XXXXXX")"
  # Pass the replacement via ENVIRON, not -v, so backslashes in the fact are
  # taken literally (awk -v processes C escapes in the assigned value).
  CANOPY_SCRIBE_REPL="- $fact" awk -v n="$n" '
    /^- / { if (++c == n) { print ENVIRON["CANOPY_SCRIBE_REPL"]; next } }
    { print }
  ' "$am" > "$tmp"
  mv -f "$tmp" "$am"
  info "scribe: replaced entry #$n"
}

# canopy scribe rm <n>  -> delete a stale entry
canopy_scribe_rm() {
  need git
  local n="${1:?entry number}"
  local am; am="$(_scribe_file)"
  [ -f "$am" ] || die "no AGENTS.md yet"
  _scribe_assert_index "$n" "$(_scribe_count "$am")"
  local tmp; tmp="$(mktemp "${am}.XXXXXX")"
  awk -v n="$n" '
    /^- / { if (++c == n) next }
    { print }
  ' "$am" > "$tmp"
  mv -f "$tmp" "$am"
  info "scribe: removed entry #$n"
}

# canopy scribe show  -> print the whole file
canopy_scribe_show() {
  local am; am="$(_scribe_file)"
  [ -f "$am" ] && cat "$am" || warn "no AGENTS.md yet"
}
