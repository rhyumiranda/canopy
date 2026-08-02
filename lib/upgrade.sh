# upgrade.sh — update the installed canopy from ANY directory. Sourced.
# shellcheck shell=bash
#
# `canopy setup` records the source checkout at ~/.local/share/canopy/.source.
# `canopy upgrade` reads that, fast-forwards the checkout's main to origin/main,
# and re-installs the snapshot — so you never have to cd into the canopy repo to
# update. Reads .source from the STABLE install path, not $CANOPY_ROOT, so it
# works the same whether run via the PATH symlink or from the checkout.

canopy_upgrade() {
  need git
  local app="$HOME/.local/share/canopy" src before after
  [ -f "$app/.source" ] || die "no install record at $app/.source — run 'canopy setup' once from the canopy checkout first"
  src="$(cat "$app/.source")"
  [ -n "$src" ] && [ -d "$src/.git" ] || die "recorded source is not a git checkout: $src — re-run 'canopy setup' from the checkout"
  [ -x "$src/bin/canopy" ] || die "recorded source has no bin/canopy: $src"

  info "upgrading canopy from $src"
  git -C "$src" diff --quiet && git -C "$src" diff --cached --quiet \
    || die "source checkout has uncommitted changes ($src) — commit or stash there first"

  before="$(sed -n 's/^CANOPY_VERSION="\(.*\)"/\1/p' "$src/lib/common.sh" | head -1)"
  git -C "$src" fetch --quiet origin main || die "cannot fetch origin/main"
  git -C "$src" checkout -q main || die "cannot switch $src to main"
  git -C "$src" merge --ff-only origin/main >/dev/null 2>&1 \
    || die "$src main is not fast-forwardable (local commits?) — resolve it there, then retry"
  after="$(sed -n 's/^CANOPY_VERSION="\(.*\)"/\1/p' "$src/lib/common.sh" | head -1)"

  # Re-install the snapshot from the freshly updated source.
  CANOPY_ROOT="$src" "$src/bin/canopy" setup >/dev/null || die "reinstall (setup) failed"

  if [ "$before" = "$after" ]; then
    info "canopy already up to date (${after:-unknown})"
  else
    info "canopy upgraded: ${before:-?} -> ${after:-?}"
  fi
}
