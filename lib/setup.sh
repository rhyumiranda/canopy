# setup.sh — install Canopy into ~/.claude + PATH. Sourced. Respects $HOME (testable).
# shellcheck shell=bash
#
# `canopy setup` is user-run. It copies agent/command/hook defs into ~/.claude,
# installs a STABLE SNAPSHOT of the CLI (bin+lib+agents) under ~/.local/share/canopy
# and points the PATH symlink at that snapshot, and (only if you have no
# settings.json) writes the hooks; if you already have settings.json it drops the
# snippet beside it for you to merge (never clobbers your existing hooks).
#
# Why a snapshot instead of symlinking PATH straight at the repo: the PATH command
# must not track the dev working tree, or switching branches in the checkout breaks
# `canopy` for every project. Re-run `canopy setup` FROM THE SOURCE CHECKOUT to
# ship changes into the snapshot.

canopy_setup() {
  need jq
  local dry=0; [ "${1:-}" = "--dry-run" ] && dry=1
  local cdir="$HOME/.claude"
  local agents="$cdir/agents" cmds="$cdir/commands" hooks="$cdir/canopy/hooks" bindir="$HOME/.local/bin"
  local app="$HOME/.local/share/canopy"   # stable CLI snapshot; PATH points here
  local settings="$cdir/settings.json" snippet="$CANOPY_ROOT/dist/settings-hooks.json"

  # Refuse to "install" from the snapshot onto itself — that copies nothing new and
  # is the mistake to catch (running the PATH `canopy setup` expecting an update).
  if [ "$CANOPY_ROOT" = "$app" ]; then
    die "run 'canopy setup' from the source checkout (e.g. ./bin/canopy setup), not the installed copy at $app"
  fi

  _do() { if [ "$dry" = 1 ]; then log "[dry-run] $*"; else eval "$*"; fi; }

  _do "mkdir -p '$agents' '$cmds' '$hooks' '$bindir' '$app'"

  # Claude Code integration: agents/commands/hooks are loaded from ~/.claude.
  _do "cp '$CANOPY_ROOT'/agents/*.md '$agents/'"
  _do "cp '$CANOPY_ROOT'/commands/*.md '$cmds/'"
  _do "cp '$CANOPY_ROOT'/hooks/*.sh '$hooks/'"

  # Stable CLI snapshot: bin+lib+agents copied so the PATH command is decoupled from
  # the dev working tree. Remove-then-copy so a renamed/deleted file never lingers.
  _do "rm -rf '$app/bin' '$app/lib' '$app/agents'"
  _do "cp -R '$CANOPY_ROOT/bin' '$app/bin'"
  _do "cp -R '$CANOPY_ROOT/lib' '$app/lib'"
  _do "cp -R '$CANOPY_ROOT/agents' '$app/agents'"
  _do "ln -sf '$app/bin/canopy' '$bindir/canopy'"

  if [ "$dry" = 1 ]; then
    log "[dry-run] install hooks into $settings (or drop snippet beside it)"
  elif [ -f "$settings" ]; then
    cp "$snippet" "$cdir/canopy/settings-hooks.json"
    warn "you already have $settings — I did NOT touch it. Merge the 'hooks' from $cdir/canopy/settings-hooks.json into it."
  else
    jq '{hooks: .hooks}' "$snippet" > "$settings"
    info "wrote $settings with Canopy hooks"
  fi

  # NB: not "${dry:+…}" — dry=0 is a non-empty string, so it would fire on a real run.
  local drytag=""; [ "$dry" = 1 ] && drytag="(dry-run) "
  info "canopy setup ${drytag}done: agents + commands + hooks + CLI snapshot ($app) + PATH symlink"
  info "ensure '$bindir' is on your PATH (e.g. export PATH=\"\$HOME/.local/bin:\$PATH\")"
  info "to update later, re-run 'canopy setup' from the source checkout"
}
