# upgrade.sh — update the installed canopy from ANY directory. Sourced.
# shellcheck shell=bash
#
# `canopy setup` records the source checkout at ~/.local/share/canopy/.source.
# `canopy upgrade` reads that managed checkout, refreshes the channel branch,
# and re-installs the snapshot — so you never have to cd into the canopy repo to
# update. Reads install metadata from the stable install path, not $CANOPY_ROOT, so it
# works the same whether run via the PATH symlink or from the checkout.

canopy_upgrade() {
  need git
  need jq
  local app="$HOME/.local/share/canopy" src before after channel upstream ref
  [ -f "$app/.source" ] || die "no install record at $app/.source — run 'canopy setup' once from the canopy checkout first"
  src="$(cat "$app/.source")"
  channel="stable"
  upstream=""
  [ -f "$app/.channel" ] && channel="$(cat "$app/.channel")"
  [ -f "$app/.upstream" ] && upstream="$(cat "$app/.upstream")"
  [ -n "$upstream" ] || upstream="$src"
  [ -n "$src" ] && [ -d "$src/.git" ] || die "recorded source is not a git checkout: $src — re-run 'canopy setup' from the checkout"
  [ -x "$src/bin/canopy" ] || die "recorded source has no bin/canopy: $src"
  ref="$(canopy_channel_ref "$channel")"

  info "upgrading canopy from $src ($channel -> $ref)"
  git -C "$src" diff --quiet && git -C "$src" diff --cached --quiet \
    || die "source checkout has uncommitted changes ($src) — commit or stash there first"

  before="$(sed -n 's/^CANOPY_VERSION="\([^"]*\)".*/\1/p' "$src/lib/common.sh" | head -1)"
  canopy_channel_sync_source "$src" "$src" "$upstream" "$channel"
  after="$(sed -n 's/^CANOPY_VERSION="\([^"]*\)".*/\1/p' "$src/lib/common.sh" | head -1)"

  # Re-install the snapshot from the freshly updated source.
  _canopy_install_snapshot "$src" "$app" "$channel" "$src" "$upstream" 0

  if [ "$before" = "$after" ]; then
    info "canopy already up to date (${after:-unknown})"
  else
    info "canopy upgraded: ${before:-?} -> ${after:-?}"
  fi
}
