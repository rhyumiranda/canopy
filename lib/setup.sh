# setup.sh — install Canopy into Claude/Codex + PATH. Sourced. Respects $HOME (testable).
# shellcheck shell=bash
#
# `canopy setup` is user-run. It has two halves, now split into two functions:
#   * _canopy_install_snapshot — the CLI SNAPSHOT: copy bin+lib+agents+dist and the
#     wiring assets (commands+hooks+skills) into ~/.local/share/canopy, point the
#     PATH symlink at that snapshot, and record channel metadata. No ~/.claude writes.
#   * _canopy_link_defs — the WIRING: copy Claude defs into ~/.claude, package
#     Codex-readable defs under ~/.codex/canopy, install the Codex skills, and merge
#     dist/settings-hooks.json beside ~/.claude/settings.json (never clobbering it).
#     Writes the marker ~/.claude/canopy/.linked-version so first-run auto-wire can
#     tell whether the installed defs are current.
#
# `canopy setup` (no flags) = snapshot + link (today's behavior, unchanged).
# `canopy setup --link`   = wiring only (what a Homebrew install uses — brew can't
#                           write ~/.claude at install time, so the defs are wired
#                           from the running canopy on first use / on demand).
# `canopy setup --unlink` = remove canopy's own wired defs, conservatively.
#
# Why a snapshot instead of symlinking PATH straight at the repo: the PATH command
# must not track the dev working tree, or switching branches in the checkout breaks
# `canopy` for every project. Re-run `canopy setup` FROM THE SOURCE CHECKOUT to
# ship changes into the snapshot.

# _canopy_install_snapshot <source_root> <app> <channel> <source_record> <upstream> <dry>
# The CLI-snapshot half ONLY (no ~/.claude/~/.codex wiring). The snapshot copies the
# full source tree canopy needs both to RUN and to WIRE itself — bin/lib/agents/dist
# plus the wiring assets commands/hooks/skills — because CANOPY_ROOT is THIS snapshot
# when canopy runs via the PATH symlink, and first-run auto-wire / `setup --link`
# copy their defs from CANOPY_ROOT (see _canopy_link_defs).
_canopy_install_snapshot() {
  local source_root="$1" app="$2" channel="$3" source_record="$4" upstream="$5" dry="$6"
  local bindir="$HOME/.local/bin"

  _do() { if [ "$dry" = 1 ]; then log "[dry-run] $*"; else eval "$*"; fi; }

  _do "mkdir -p '$bindir' '$app'"

  # Stable CLI snapshot: bin+lib+agents+dist so the PATH command is decoupled from the
  # dev working tree, PLUS the wiring assets (commands/hooks/skills) so the installed
  # snapshot is a self-sufficient source for first-run auto-wire and `setup --link`.
  # `dist/` MUST ship: `canopy init` reads $CANOPY_ROOT/dist/codex-hooks.json, and
  # $CANOPY_ROOT is this snapshot when canopy runs via the PATH symlink. Omitting any
  # of these leaves the installed CLI unable to wire itself.
  # Remove-then-copy so a renamed/deleted file never lingers.
  _do "rm -rf '$app/bin' '$app/lib' '$app/agents' '$app/dist' '$app/commands' '$app/hooks' '$app/skills'"
  _do "cp -R '$source_root/bin' '$app/bin'"
  _do "cp -R '$source_root/lib' '$app/lib'"
  _do "cp -R '$source_root/agents' '$app/agents'"
  _do "cp -R '$source_root/dist' '$app/dist'"
  _do "cp -R '$source_root/commands' '$app/commands'"
  _do "cp -R '$source_root/hooks' '$app/hooks'"
  _do "cp -R '$source_root/skills' '$app/skills'"
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
}

# _canopy_link_defs <source_root> <dry>
# The WIRING half of setup: copy Claude defs into ~/.claude, package Codex-readable
# defs under ~/.codex/canopy, install the Codex skills, and merge
# dist/settings-hooks.json beside ~/.claude/settings.json (never clobbering an
# existing settings.json). Idempotent (`cp -f` overwrites). Fully $HOME-scoped so the
# $HOME-override tests stay hermetic. AFTER all copies succeed, writes the marker
# ~/.claude/canopy/.linked-version (= the source tree's CANOPY_VERSION, not the
# running process's — so the marker matches the version a later canopy will report)
# via an atomic temp+mv, so a partial/aborted wire never leaves a marker claiming a
# good install. NO ~/.local snapshot, NO PATH symlink — that is
# _canopy_install_snapshot's job. Dies with path context on any mkdir/copy failure.
_canopy_link_defs() {
  local source_root="$1" dry="$2"
  local cdir="$HOME/.claude" xdir="$HOME/.codex/canopy"
  local codex_user_skills="$HOME/.agents/skills"
  local codex_legacy_skills="$HOME/.codex/skills"
  local agents="$cdir/agents" cmds="$cdir/commands" hooks="$cdir/canopy/hooks"
  local settings="$cdir/settings.json" snippet="$source_root/dist/settings-hooks.json"
  local marker="$cdir/canopy/.linked-version"

  # Die with path context on failure (vs bare set -e) so a broken wire is diagnosable.
  _wire() { if [ "$dry" = 1 ]; then log "[dry-run] $*"; else eval "$*" || die "canopy: wiring step failed: $*"; fi; }

  _wire "mkdir -p '$agents' '$cmds' '$hooks' '$xdir/agents' '$xdir/commands' '$xdir/hooks' '$codex_user_skills' '$codex_legacy_skills'"

  # Claude Code integration: agents/commands/hooks are loaded from ~/.claude.
  _wire "cp -f '$source_root'/agents/*.md '$agents/'"
  _wire "cp -f '$source_root'/commands/*.md '$cmds/'"
  _wire "cp -f '$source_root'/hooks/*.sh '$hooks/'"

  # Codex integration is explicit: keep Canopy defs packaged, but don't write a
  # global ~/.codex/AGENTS.md that would turn every Codex session into Canopy.
  _wire "cp -f '$source_root'/agents/*.md '$xdir/agents/'"
  _wire "cp -f '$source_root'/commands/*.md '$xdir/commands/'"
  _wire "cp -f '$source_root'/hooks/*.sh '$xdir/hooks/'"

  # Codex native skills: install globally so `$yolo`/`$hotfix`/`$scribe` are
  # available the same way Claude gets reusable commands. Install to both the
  # current and legacy skill homes so different Codex surfaces can find them.
  _wire "rm -rf '$codex_user_skills/canopy-'* '$codex_legacy_skills/canopy-'*"
  _wire "cp -R '$source_root/skills/yolo' '$codex_user_skills/canopy-yolo'"
  _wire "cp -R '$source_root/skills/guided' '$codex_user_skills/canopy-guided'"
  _wire "cp -R '$source_root/skills/hotfix' '$codex_user_skills/canopy-hotfix'"
  _wire "cp -R '$source_root/skills/scribe' '$codex_user_skills/canopy-scribe'"
  _wire "cp -R '$source_root/skills/yolo' '$codex_legacy_skills/canopy-yolo'"
  _wire "cp -R '$source_root/skills/guided' '$codex_legacy_skills/canopy-guided'"
  _wire "cp -R '$source_root/skills/hotfix' '$codex_legacy_skills/canopy-hotfix'"
  _wire "cp -R '$source_root/skills/scribe' '$codex_legacy_skills/canopy-scribe'"

  # Hooks settings: never clobber a user's real settings.json — write it only when
  # absent, else drop the snippet beside it for the user to merge.
  if [ "$dry" = 1 ]; then
    log "[dry-run] install hooks into $settings (or drop snippet beside it)"
  elif [ -f "$settings" ]; then
    cp -f "$snippet" "$cdir/canopy/settings-hooks.json" || die "canopy: cannot copy $snippet -> $cdir/canopy/settings-hooks.json"
    warn "you already have $settings — I did NOT touch it. Merge the 'hooks' from $cdir/canopy/settings-hooks.json into it."
  else
    jq '{hooks: .hooks}' "$snippet" > "$settings" || die "canopy: cannot write $settings from $snippet"
    info "wrote $settings with Canopy hooks"
  fi

  # Marker: record the SOURCE tree's version (what a later canopy run of this
  # snapshot will report), so a version match means "defs current". Atomic temp+mv
  # AFTER all copies, so an aborted wire never leaves a marker that lies.
  local linkver
  linkver="$(sed -n 's/^CANOPY_VERSION="\([^"]*\)".*/\1/p' "$source_root/lib/common.sh" 2>/dev/null | head -1)" || linkver=""
  [ -n "$linkver" ] || linkver="$CANOPY_VERSION"
  if [ "$dry" = 1 ]; then
    log "[dry-run] record linked version ($linkver) in $marker"
  else
    local mtmp
    mtmp="$(mktemp "${marker}.XXXXXX")" || die "canopy: cannot create temp marker beside $marker"
    printf '%s\n' "$linkver" > "$mtmp"
    mv -f "$mtmp" "$marker" || die "canopy: cannot write linked-version marker $marker"
  fi
}

# _canopy_unlink_defs — remove canopy's OWN wired defs, conservatively. Matches by
# the filenames canopy ships (derived from $CANOPY_ROOT/agents/*.md +
# commands/*.md + hooks/*.sh) so a user's own agents/commands are never deleted.
# Also removes the canopy-* Codex skills, the whole ~/.codex/canopy package, the
# settings-hooks snippet, and the .linked-version marker. Idempotent (missing = no
# error). Does NOT un-merge the user's real ~/.claude/settings.json.
_canopy_unlink_defs() {
  local source_root="$CANOPY_ROOT"
  local cdir="$HOME/.claude" xdir="$HOME/.codex/canopy"
  local codex_user_skills="$HOME/.agents/skills"
  local codex_legacy_skills="$HOME/.codex/skills"
  local agents="$cdir/agents" cmds="$cdir/commands" hooks="$cdir/canopy/hooks"
  local n=0 f base d

  _count_files() { find "$1" -type f 2>/dev/null | wc -l | tr -d ' '; }

  # Claude agents/commands/hooks — only canopy's shipped filenames.
  for f in "$source_root"/agents/*.md; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    [ -f "$agents/$base" ] && { rm -f "$agents/$base" && n=$((n+1)); }
  done
  for f in "$source_root"/commands/*.md; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    [ -f "$cmds/$base" ] && { rm -f "$cmds/$base" && n=$((n+1)); }
  done
  for f in "$source_root"/hooks/*.sh; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    [ -f "$hooks/$base" ] && { rm -f "$hooks/$base" && n=$((n+1)); }
  done

  # settings-hooks snippet (NOT the user's settings.json) + the marker.
  [ -f "$cdir/canopy/settings-hooks.json" ] && { rm -f "$cdir/canopy/settings-hooks.json" && n=$((n+1)); }
  [ -f "$cdir/canopy/.linked-version" ]     && { rm -f "$cdir/canopy/.linked-version" && n=$((n+1)); }

  # canopy-* Codex skills (both skill homes) — entirely canopy-owned.
  for d in "$codex_user_skills"/canopy-* "$codex_legacy_skills"/canopy-*; do
    [ -e "$d" ] || continue
    n=$((n + $(_count_files "$d")))
    rm -rf "$d"
  done

  # ~/.codex/canopy package (canopy's packaged agents/commands/hooks) — entirely ours.
  if [ -d "$xdir" ]; then
    n=$((n + $(_count_files "$xdir")))
    rm -rf "$xdir"
  fi

  log "canopy: removed $n files; ~/.claude/settings.json left untouched"
}

# _canopy_ensure_channel_metadata — create the channel records a Homebrew install
# lacks (brew has no managed git checkout, so `canopy setup` never ran to write
# them). Fills ~/.local/share/canopy/.channel|.channel-ref|.upstream ONLY when
# absent — never overwrites a clone install's real records — and DELIBERATELY does
# NOT write .source (there is no managed checkout for brew; Unit C's upgrade path
# keys off is_brew_install and never reads .source for a brew install).
_canopy_ensure_channel_metadata() {
  local app="$HOME/.local/share/canopy"
  mkdir -p "$app" 2>/dev/null || return 0
  [ -f "$app/.channel" ]     || printf '%s\n' "stable" > "$app/.channel"
  [ -f "$app/.channel-ref" ] || printf '%s\n' "main" > "$app/.channel-ref"
  [ -f "$app/.upstream" ]    || printf '%s\n' "$(canopy_channel_upstream)" > "$app/.upstream"
}

# _canopy_maybe_autowire <cmd> [args...] — first-run lazy wiring. A Homebrew install
# can't write ~/.claude at install time, so the first REAL canopy command wires the
# Claude/Codex defs when the marker is missing or stale, then records the brew-style
# channel metadata. Fires only if ALL hold: cmd not in the skip-set; CANOPY_NO_AUTOLINK
# unset/≠1; `--no-autolink` not among the args; CANOPY_ROLE ≠ worker (detached workers
# skip — see lib/worker.sh); marker missing OR ≠ CANOPY_VERSION. Race-safe via
# mkdir-lock (no flock — portability on bash 3.2): the first proc to `mkdir` the lock
# wires; a concurrent proc's mkdir fails and it skips silently. Runs the wire in a
# subshell so a wiring failure surfaces a warning WITHOUT bricking the user's actual
# command, and the lock is always released.
_canopy_maybe_autowire() {
  local cmd="${1:-}"; shift || true

  [ "${CANOPY_NO_AUTOLINK:-0}" = 1 ] && return 0
  [ "${CANOPY_ROLE:-}" = worker ] && return 0
  local a
  for a in "$@"; do
    [ "$a" = "--no-autolink" ] && return 0
  done

  # Skip-set: meta/help/self commands that must not trigger a wire.
  case "$cmd" in
    ""|-h|--help|help|-v|-V|--version|version|doctor|setup) return 0 ;;
  esac

  local marker="$HOME/.claude/canopy/.linked-version" cur=""
  if [ -f "$marker" ]; then cur="$(cat "$marker" 2>/dev/null)" || cur=""; fi
  [ "$cur" = "$CANOPY_VERSION" ] && return 0

  local lockdir="$HOME/.claude/canopy/.wire.lock"
  mkdir -p "$HOME/.claude/canopy" 2>/dev/null || return 0
  if mkdir "$lockdir" 2>/dev/null; then
    if ( _canopy_link_defs "$CANOPY_ROOT" 0 ); then
      _canopy_ensure_channel_metadata
      rmdir "$lockdir" 2>/dev/null || true
      log "canopy: wired Claude/Codex defs (v$CANOPY_VERSION) — canopy setup --unlink to remove"
    else
      rmdir "$lockdir" 2>/dev/null || true
      warn "canopy: first-run wiring failed — run 'canopy setup --link' to retry (or set CANOPY_NO_AUTOLINK=1 to silence)"
    fi
  fi
  return 0
}

canopy_setup() {
  need jq
  need git
  local dry=0 channel="stable" mode="full"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1 ;;
      --link)    mode="link" ;;
      --unlink)  mode="unlink" ;;
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
       canopy setup --link [--dry-run]
       canopy setup --unlink

  (no flags)               Install the CLI snapshot + wire Claude/Codex defs (default)
  --link                   Wire Claude/Codex defs only (no CLI snapshot / PATH symlink)
  --unlink                 Remove canopy's wired defs (leaves ~/.claude/settings.json)
  --channel stable         Install the stable channel (default)
  --channel codex-preview  Install the experimental Codex preview channel
  --channel herdr-preview  Install the experimental Herdr worker channel
EOF
        return 0 ;;
      *) die "unknown setup option: $1" ;;
    esac
    shift
  done

  # --unlink: remove canopy's own defs and stop (no snapshot, no channel work).
  if [ "$mode" = unlink ]; then
    _canopy_unlink_defs
    return 0
  fi

  # --link: wire the defs from the RUNNING canopy (this is the Homebrew path — brew
  # already placed the CLI, so there is no channel to sync / snapshot to build).
  if [ "$mode" = link ]; then
    _canopy_link_defs "$CANOPY_ROOT" "$dry"
    _canopy_ensure_channel_metadata
    local linktag=""; [ "$dry" = 1 ] && linktag="(dry-run) "
    info "canopy setup --link ${linktag}done: wired Claude defs + Codex package + Codex skills from $CANOPY_ROOT"
    return 0
  fi

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

  # Snapshot + link = today's default behavior, unchanged.
  _canopy_install_snapshot "$source" "$app" "$channel" "$source" "$upstream" "$dry"
  _canopy_link_defs "$source" "$dry"

  # NB: not "${dry:+…}" — dry=0 is a non-empty string, so it would fire on a real run.
  local drytag=""; [ "$dry" = 1 ] && drytag="(dry-run) "
  info "canopy setup ${drytag}done: channel=$channel ref=$(canopy_channel_ref "$channel"), Claude defs + Codex package + Codex skills + CLI snapshot ($app) + PATH symlink"
  info "ensure '$bindir' is on your PATH (e.g. export PATH=\"\$HOME/.local/bin:\$PATH\")"
  info "to update later, re-run 'canopy setup' from the source checkout"
}
