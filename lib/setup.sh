# setup.sh — install Canopy into ~/.claude + PATH. Sourced. Respects $HOME (testable).
# shellcheck shell=bash
#
# `canopy setup` is user-run. It copies agent/command/hook defs into ~/.claude,
# symlinks the CLI onto PATH, and (only if you have no settings.json) writes the
# hooks; if you already have settings.json it drops the snippet beside it for you
# to merge (never clobbers your existing hooks).

canopy_setup() {
  need jq
  local dry=0; [ "${1:-}" = "--dry-run" ] && dry=1
  local cdir="$HOME/.claude"
  local agents="$cdir/agents" cmds="$cdir/commands" hooks="$cdir/canopy/hooks" bindir="$HOME/.local/bin"
  local settings="$cdir/settings.json" snippet="$CANOPY_ROOT/dist/settings-hooks.json"

  _do() { if [ "$dry" = 1 ]; then log "[dry-run] $*"; else eval "$*"; fi; }

  _do "mkdir -p '$agents' '$cmds' '$hooks' '$bindir'"
  _do "cp '$CANOPY_ROOT'/agents/*.md '$agents/'"
  _do "cp '$CANOPY_ROOT'/commands/*.md '$cmds/'"
  _do "cp '$CANOPY_ROOT'/hooks/*.sh '$hooks/'"
  _do "ln -sf '$CANOPY_ROOT/bin/canopy' '$bindir/canopy'"

  if [ "$dry" = 1 ]; then
    log "[dry-run] install hooks into $settings (or drop snippet beside it)"
  elif [ -f "$settings" ]; then
    cp "$snippet" "$cdir/canopy/settings-hooks.json"
    warn "you already have $settings — I did NOT touch it. Merge the 'hooks' from $cdir/canopy/settings-hooks.json into it."
  else
    jq '{hooks: .hooks}' "$snippet" > "$settings"
    info "wrote $settings with Canopy hooks"
  fi

  info "canopy setup ${dry:+(dry-run) }done: agents + commands + hooks + PATH symlink"
  info "ensure '$bindir' is on your PATH (e.g. export PATH=\"\$HOME/.local/bin:\$PATH\")"
}
