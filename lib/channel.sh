# channel.sh — map install channels to real git refs and manage the install source.
# shellcheck shell=bash

canopy_channel_ref() {
  case "${1:-}" in
    stable) printf '%s\n' "main" ;;
    codex-preview) printf '%s\n' "rhyu/experimental-codex-package" ;;
    *) die "unknown setup channel: ${1:-<none>} (use stable or codex-preview)" ;;
  esac
}

canopy_channel_seed() {
  printf '%s\n' "$CANOPY_ROOT"
}

canopy_channel_upstream() {
  printf '%s\n' "${CANOPY_CHANNEL_UPSTREAM:-https://github.com/rhyumiranda/canopy.git}"
}

canopy_channel_source_dir() {
  printf '%s/source\n' "$1"
}

canopy_channel_sync_source() {
  need git
  local src="$1" seed="$2" upstream="$3" channel="$4" ref
  ref="$(canopy_channel_ref "$channel")"

  if [ ! -d "$src/.git" ]; then
    rm -rf "$src"
    git clone -q "$seed" "$src" || die "cannot clone install source from $seed"
  fi

  git -C "$src" remote set-url origin "$upstream" >/dev/null 2>&1 || true

  git -C "$src" diff --quiet && git -C "$src" diff --cached --quiet \
    || die "managed install source has uncommitted changes ($src) — delete it or clean it first"

  if git -C "$src" fetch --quiet origin "$ref" >/dev/null 2>&1; then
    git -C "$src" checkout -q -B "$ref" FETCH_HEAD || die "cannot switch $src to fetched $ref"
  elif git -C "$src" show-ref --verify --quiet "refs/heads/$ref"; then
    git -C "$src" checkout -q "$ref" || die "cannot switch $src to $ref"
  elif git -C "$src" show-ref --verify --quiet "refs/remotes/origin/$ref"; then
    git -C "$src" branch -f "$ref" "origin/$ref" >/dev/null 2>&1 \
      || die "cannot materialize origin/$ref in $src"
    git -C "$src" checkout -q "$ref" || die "cannot switch $src to $ref"
  else
    die "channel '$channel' expects branch '$ref', but it was not found in $upstream or $seed"
  fi
}
