# setup.sh — install Canopy into Claude/Codex + PATH. Sourced. Respects $HOME (testable).
# shellcheck shell=bash
#
# `canopy setup` is user-run. It copies Claude defs into ~/.claude, packages
# Codex-readable defs under ~/.codex/canopy, installs a STABLE SNAPSHOT of the
# CLI (bin+lib+agents) under ~/.local/share/canopy
# and points the PATH symlink at that snapshot, and (only if you have no
# settings.json) writes the hooks; if you already have settings.json it drops the
# snippet beside it for you to merge (never clobbers your existing hooks).
#
# Why a snapshot instead of symlinking PATH straight at the repo: the PATH command
# must not track the dev working tree, or switching branches in the checkout breaks
# `canopy` for every project. Re-run `canopy setup` FROM THE SOURCE CHECKOUT to
# ship changes into the snapshot.

_canopy_install_snapshot() {
  local source_root="$1" app="$2" channel="$3" source_record="$4" upstream="$5" dry="$6"
  local cdir="$HOME/.claude" xdir="$HOME/.codex/canopy"
  local codex_user_skills="$HOME/.agents/skills"
  local codex_legacy_skills="$HOME/.codex/skills"
  local agents="$cdir/agents" cmds="$cdir/commands" hooks="$cdir/canopy/hooks" bindir="$HOME/.local/bin"
  local settings="$cdir/settings.json" snippet="$source_root/dist/settings-hooks.json"

  _do() { if [ "$dry" = 1 ]; then log "[dry-run] $*"; else eval "$*"; fi; }

  _do "mkdir -p '$agents' '$cmds' '$hooks' '$bindir' '$app' '$xdir/agents' '$xdir/commands' '$xdir/hooks' '$codex_user_skills' '$codex_legacy_skills'"

  # Claude Code integration: agents/commands/hooks are loaded from ~/.claude.
  _do "cp '$source_root'/agents/*.md '$agents/'"
  _do "cp '$source_root'/commands/*.md '$cmds/'"
  _do "cp '$source_root'/hooks/*.sh '$hooks/'"

  # Codex integration is explicit: keep Canopy defs packaged, but don't write a
  # global ~/.codex/AGENTS.md that would turn every Codex session into Canopy.
  _do "cp '$source_root'/agents/*.md '$xdir/agents/'"
  _do "cp '$source_root'/commands/*.md '$xdir/commands/'"
  _do "cp '$source_root'/hooks/*.sh '$xdir/hooks/'"

  # Codex native skills: install globally so `$yolo`/`$hotfix`/`$scribe` are
  # available the same way Claude gets reusable commands. Install to both the
  # current and legacy skill homes so different Codex surfaces can find them.
  _do "rm -rf '$codex_user_skills/canopy-'* '$codex_legacy_skills/canopy-'*"
  _do "cp -R '$source_root/skills/yolo' '$codex_user_skills/canopy-yolo'"
  _do "cp -R '$source_root/skills/guided' '$codex_user_skills/canopy-guided'"
  _do "cp -R '$source_root/skills/hotfix' '$codex_user_skills/canopy-hotfix'"
  _do "cp -R '$source_root/skills/scribe' '$codex_user_skills/canopy-scribe'"
  _do "cp -R '$source_root/skills/yolo' '$codex_legacy_skills/canopy-yolo'"
  _do "cp -R '$source_root/skills/guided' '$codex_legacy_skills/canopy-guided'"
  _do "cp -R '$source_root/skills/hotfix' '$codex_legacy_skills/canopy-hotfix'"
  _do "cp -R '$source_root/skills/scribe' '$codex_legacy_skills/canopy-scribe'"

  # Stable CLI snapshot: bin+lib+agents copied so the PATH command is decoupled from
  # the dev working tree. Remove-then-copy so a renamed/deleted file never lingers.
  # `dist/` MUST ship in the snapshot: `canopy init` reads
  # $CANOPY_ROOT/dist/codex-hooks.json, and $CANOPY_ROOT is this snapshot when
  # canopy runs via the PATH symlink. Omitting it made `canopy init` die (exit 1)
  # for every installed user — before it gitignored `.canopy/` or ran `treehouse
  # init` — while still passing tests, which run bin/canopy from the checkout.
  _do "rm -rf '$app/bin' '$app/lib' '$app/agents' '$app/dist'"
  _do "cp -R '$source_root/bin' '$app/bin'"
  _do "cp -R '$source_root/lib' '$app/lib'"
  _do "cp -R '$source_root/agents' '$app/agents'"
  _do "cp -R '$source_root/dist' '$app/dist'"
  _do "ln -sf '$app/bin/canopy' '$bindir/canopy'"

  if [ "$dry" = 1 ]; then
    log "[dry-run] record install source ($source_record) in $app/.source"
    log "[dry-run] record install upstream ($upstream) in $app/.upstream"
    log "[dry-run] record install channel ($channel) in $app/.channel"
    log "[dry-run] record install ref ($(canopy_channel_ref "$channel")) in $app/.channel-ref"
  else
    printf '%s\n' "$source_record" > "$app/.source"
    printf '%s\n' "$upstream" > "$app/.upstream"
    printf '%s\n' "$channel" > "$app/.channel"
    printf '%s\n' "$(canopy_channel_ref "$channel")" > "$app/.channel-ref"
  fi

  if [ "$dry" = 1 ]; then
    log "[dry-run] install hooks into $settings (or drop snippet beside it)"
  elif [ -f "$settings" ]; then
    cp "$snippet" "$cdir/canopy/settings-hooks.json"
    warn "you already have $settings — I did NOT touch it. Merge the 'hooks' from $cdir/canopy/settings-hooks.json into it."
  else
    jq '{hooks: .hooks}' "$snippet" > "$settings"
    info "wrote $settings with Canopy hooks"
  fi
}

canopy_setup() {
  need jq
  need git
  local dry=0 channel="stable"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1 ;;
      --channel)
        shift
        case "${1:-}" in
          stable|codex-preview|herdr-preview) channel="$1" ;;
          *) die "unknown setup channel: ${1:-<none>} (use stable, codex-preview, or herdr-preview)" ;;
        esac
        ;;
      -h|--help)
        cat <<'EOF'
usage: canopy setup [--dry-run] [--channel stable|codex-preview|herdr-preview]

  --channel stable         Install the stable channel (default)
  --channel codex-preview  Install the experimental Codex preview channel
  --channel herdr-preview  Install the experimental Herdr worker channel
EOF
        return 0 ;;
      *) die "unknown setup option: $1" ;;
    esac
    shift
  done
  local app="$HOME/.local/share/canopy"  # stable CLI snapshot; PATH points here
  local app_real="$app"
  local source seed upstream bindir="$HOME/.local/bin"

  # Refuse to "install" from the snapshot onto itself — that copies nothing new and
  # is the mistake to catch (running the PATH `canopy setup` expecting an update).
  if [ -d "$app" ]; then
    app_real="$(cd -P "$app" && pwd)"
  fi
  if [ "$CANOPY_ROOT" = "$app" ] || [ "$CANOPY_ROOT" = "$app_real" ]; then
    die "run 'canopy setup' from the source checkout (e.g. ./bin/canopy setup), not the installed copy at $app"
  fi
  seed="$(canopy_channel_seed)"
  upstream="$(canopy_channel_upstream)"
  source="$(canopy_channel_source_dir "$app")"

  if [ "$dry" = 1 ]; then
    log "[dry-run] sync channel '$channel' from $(canopy_channel_ref "$channel") into $source"
  else
    canopy_channel_sync_source "$source" "$seed" "$upstream" "$channel"
  fi

  _canopy_install_snapshot "$source" "$app" "$channel" "$source" "$upstream" "$dry"

  # NB: not "${dry:+…}" — dry=0 is a non-empty string, so it would fire on a real run.
  local drytag=""; [ "$dry" = 1 ] && drytag="(dry-run) "
  info "canopy setup ${drytag}done: channel=$channel ref=$(canopy_channel_ref "$channel"), Claude defs + Codex package + Codex skills + CLI snapshot ($app) + PATH symlink"
  info "ensure '$bindir' is on your PATH (e.g. export PATH=\"\$HOME/.local/bin:\$PATH\")"
  info "to update later, re-run 'canopy setup' from the source checkout"
}
