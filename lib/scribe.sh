# scribe.sh — durable, cross-task project knowledge -> AGENTS.md. Sourced.
# shellcheck shell=bash
#
# AGENTS.md is COMMITTED (every agent auto-loads it) — distinct from the per-change
# "document" step and from the gitignored .canopy/ runtime state. Only durable,
# project-intrinsic facts belong here (gate: non-obvious AND changes future action);
# that judgment is the model's, per the /scribe command.

# canopy scribe add "<fact>"
canopy_scribe_add() {
  need git
  local fact="${*:?fact}"
  local root am; root="$(repo_root)"; am="$root/AGENTS.md"
  if [ ! -f "$am" ]; then
    printf '# AGENTS.md\n\nDurable, project-intrinsic knowledge (curated by `/scribe`). Non-obvious facts that change future actions — not task notes.\n\n' > "$am"
  fi
  local line="- $fact"
  if grep -qxF -- "$line" "$am" 2>/dev/null; then info "scribe: already recorded — skipped"; return 0; fi
  printf '%s\n' "$line" >> "$am"
  info "scribe: recorded to AGENTS.md"
}

# canopy scribe show
canopy_scribe_show() {
  local am; am="$(repo_root)/AGENTS.md"
  [ -f "$am" ] && cat "$am" || warn "no AGENTS.md yet"
}
