#!/bin/sh
# install.sh — one-command Canopy install for systems WITHOUT Homebrew (Linux/CI).
#
#   curl -fsSL https://raw.githubusercontent.com/rhyumiranda/canopy/main/install.sh | sh
#
# What it does (idempotent — re-running updates in place):
#   1. Checks the two hard prerequisites `git` + `jq` up front.
#   2. Clones (or updates) a managed Canopy checkout under
#      ~/.local/share/canopy/source — clone to source.tmp, then atomic `mv` into
#      place; if source already exists and is a valid git repo it is updated; a
#      corrupt source is removed and re-cloned. A mkdir-lock guards concurrent runs.
#   3. Runs `bin/canopy setup` from that checkout — the SAME install the from-source
#      clone flow performs: the CLI snapshot under ~/.local/share/canopy, the PATH
#      symlink at ~/.local/bin/canopy, and the Claude/Codex def wiring.
#   4. Prints the PATH line if ~/.local/bin isn't already on PATH and points you at
#      `canopy doctor`.
#
# Homebrew users should prefer: brew install rhyumiranda/tap/canopy
#
# Canopy also needs (but this installer does NOT install): claude v2.1+, treehouse,
# gh-axi. Run `canopy doctor` after install to check every prerequisite.
#
# Env knobs (all optional):
#   CANOPY_CHANNEL  stable | codex-preview | herdr-preview   (default: stable)
#   CANOPY_REF      git ref for the initial source checkout  (default: channel's)
#   CANOPY_REPO     clone URL/path                            (default: GitHub)
#
# POSIX sh (dash-safe) on purpose — this runs under /bin/sh on Linux/CI, so NO
# bashisms (no arrays, no [[ ]], no `local`).

set -eu

CANOPY_REPO="${CANOPY_REPO:-https://github.com/rhyumiranda/canopy.git}"
CANOPY_CHANNEL="${CANOPY_CHANNEL:-stable}"
CANOPY_REF="${CANOPY_REF:-}"

info() { printf '\033[36m[canopy-install]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m[canopy-install] warn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[canopy-install] error:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- 1. prerequisites -------------------------------------------------------
missing=""
have git || missing="git"
have jq  || missing="${missing:+$missing }jq"
if [ -n "$missing" ]; then
  die "missing required prerequisite(s): $missing
  Install them, then re-run this installer.
  (Canopy also needs, but does NOT install here: claude v2.1+, treehouse, gh-axi.
   After install, run 'canopy doctor' to check every prerequisite.)"
fi

case "$CANOPY_CHANNEL" in
  stable|codex-preview|herdr-preview) ;;
  *) die "unknown CANOPY_CHANNEL: $CANOPY_CHANNEL (use stable, codex-preview, or herdr-preview)" ;;
esac

# --- 2. managed checkout under ~/.local/share/canopy/source -----------------
app="$HOME/.local/share/canopy"
source_dir="$app/source"
tmp_dir="$app/source.tmp"
lock_dir="$app/.install.lock"
bindir="$HOME/.local/bin"

mkdir -p "$app"

# Guard concurrent installs (mkdir is atomic; no flock for portability).
if ! mkdir "$lock_dir" 2>/dev/null; then
  die "another canopy install appears to be running (lock: $lock_dir).
  If no other install is running, remove that directory and retry."
fi
# Always release the lock and clean a half-finished temp clone on the way out.
trap 'rmdir "$lock_dir" 2>/dev/null || true; rm -rf "$tmp_dir" 2>/dev/null || true' EXIT INT TERM HUP

# Clone fresh into source.tmp, then atomically swap into place — never leave a
# partially-cloned source behind for the next run to trip on.
clone_fresh() {
  info "cloning canopy from $CANOPY_REPO"
  rm -rf "$tmp_dir"
  if [ -n "$CANOPY_REF" ]; then
    git clone -q --branch "$CANOPY_REF" "$CANOPY_REPO" "$tmp_dir" 2>/dev/null \
      || git clone -q "$CANOPY_REPO" "$tmp_dir" \
      || die "cannot clone canopy from $CANOPY_REPO"
  else
    git clone -q "$CANOPY_REPO" "$tmp_dir" || die "cannot clone canopy from $CANOPY_REPO"
  fi
  rm -rf "$source_dir"
  mv "$tmp_dir" "$source_dir"
}

if [ -d "$source_dir/.git" ] && git -C "$source_dir" rev-parse --git-dir >/dev/null 2>&1; then
  # Existing, valid managed checkout → update it in place. The dir is entirely
  # canopy-owned, so discard any local drift (a user should never edit it) to keep
  # the clean-tree check inside `canopy setup` happy, then pull the ref.
  info "updating managed canopy checkout at $source_dir"
  git -C "$source_dir" remote set-url origin "$CANOPY_REPO" >/dev/null 2>&1 || true
  git -C "$source_dir" reset -q --hard >/dev/null 2>&1 || true
  git -C "$source_dir" clean -qfd >/dev/null 2>&1 || true
  if [ -n "$CANOPY_REF" ]; then
    if git -C "$source_dir" fetch -q origin "$CANOPY_REF" >/dev/null 2>&1; then
      git -C "$source_dir" checkout -q -B "$CANOPY_REF" FETCH_HEAD >/dev/null 2>&1 || true
    fi
  else
    git -C "$source_dir" pull -q --ff-only >/dev/null 2>&1 || true
  fi
elif [ -e "$source_dir" ]; then
  # Present but not a valid git repo → corrupt. Remove and re-clone.
  warn "existing checkout at $source_dir is not a valid git repo — re-cloning"
  clone_fresh
else
  clone_fresh
fi

[ -x "$source_dir/bin/canopy" ] \
  || die "clone did not produce $source_dir/bin/canopy — is $CANOPY_REPO a canopy repo?"

# --- 3. install via the standard setup --------------------------------------
# `canopy setup` re-syncs the managed source to the channel ref, builds the CLI
# snapshot + PATH symlink, and wires the Claude/Codex defs — identical to the
# documented clone-and-`setup` flow. Keep the clone source and setup's channel
# upstream consistent by defaulting the upstream to CANOPY_REPO.
info "running canopy setup (channel: $CANOPY_CHANNEL)"
CANOPY_CHANNEL_UPSTREAM="${CANOPY_CHANNEL_UPSTREAM:-$CANOPY_REPO}" \
  "$source_dir/bin/canopy" setup --channel "$CANOPY_CHANNEL"

# --- 4. PATH hint + next step -----------------------------------------------
case ":${PATH:-}:" in
  *":$bindir:"*) on_path=1 ;;
  *) on_path=0 ;;
esac

info "canopy installed (channel: $CANOPY_CHANNEL)."
if [ "$on_path" = 0 ]; then
  info "add ~/.local/bin to your PATH — put this in your shell profile, then reopen your shell:"
  # shellcheck disable=SC2016  # the literal $HOME/$PATH is what the user pastes.
  printf '\n    export PATH="$HOME/.local/bin:$PATH"\n\n' >&2
fi
info "next: run 'canopy doctor' to verify prerequisites (claude, treehouse, gh-axi) and PATH."
