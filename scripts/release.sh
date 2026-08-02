#!/usr/bin/env bash
# release.sh — cut a canopy release: bump CANOPY_VERSION, tag vX.Y.Z, push.
# The pushed tag triggers .github/workflows/release.yml (test gate -> GitHub Release).
#
# usage: scripts/release.sh <major|minor|patch|X.Y.Z> [--dry-run]
#   major|minor|patch  bump that component of the current version (SemVer)
#   X.Y.Z              set an explicit version (use for the first release)
#   --dry-run          print the plan and the computed version; touch nothing
#
# CANOPY_VERSION in lib/common.sh is the single source of truth; this script and
# the release workflow both read it. Set CANOPY_VERSION_OVERRIDE to feed a version
# in for testing without editing the file.
#
# Safety (real run only): must be on an up-to-date, tracked-clean 'main', and the
# target tag must not already exist — so a release is never cut from a stray state.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="$ROOT/lib/common.sh"

die() { printf 'release: %s\n' "$*" >&2; exit 1; }

DRY=0; ARG=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    major|minor|patch) ARG="$a" ;;
    [0-9]*.[0-9]*.[0-9]*) ARG="$a" ;;
    *) die "usage: scripts/release.sh <major|minor|patch|X.Y.Z> [--dry-run]" ;;
  esac
done
[ -n "$ARG" ] || die "usage: scripts/release.sh <major|minor|patch|X.Y.Z> [--dry-run]"

# Current version: override (tests) else the single source of truth in common.sh.
cur="${CANOPY_VERSION_OVERRIDE:-$(sed -n 's/^CANOPY_VERSION="\(.*\)"/\1/p' "$COMMON" | head -1)}"
[ -n "$cur" ] || die "cannot read CANOPY_VERSION from $COMMON"

base="${cur%%-*}"   # strip any -dev / -pre suffix before bumping
IFS=. read -r MA MI PA <<EOF
$base
EOF
case "${MA:-}.${MI:-}.${PA:-}" in
  *[!0-9.]*|.*|*.|*..*) die "current version not numeric MAJOR.MINOR.PATCH: $cur" ;;
esac

case "$ARG" in
  major) new="$((MA + 1)).0.0" ;;
  minor) new="$MA.$((MI + 1)).0" ;;
  patch) new="$MA.$MI.$((PA + 1))" ;;
  *)     new="$ARG" ;;
esac
tag="v$new"

echo "current: $cur"
echo "new:     $new  (tag $tag)"

if [ "$DRY" = 1 ]; then
  echo "[dry-run] would: set CANOPY_VERSION=$new, commit, tag $tag, push origin main + $tag"
  exit 0
fi

# --- real run: safety gates -------------------------------------------------
need_git() { command -v git >/dev/null 2>&1 || die "git required"; }
need_git
br="$(git -C "$ROOT" symbolic-ref --quiet --short HEAD || true)"
[ "$br" = main ] || die "release from 'main' only (currently on '$br')"
git -C "$ROOT" diff --quiet && git -C "$ROOT" diff --cached --quiet \
  || die "tracked changes present — commit or stash before releasing"
git -C "$ROOT" fetch --quiet origin main || die "cannot fetch origin/main"
[ "$(git -C "$ROOT" rev-parse HEAD)" = "$(git -C "$ROOT" rev-parse '@{u}')" ] \
  || die "local main is not in sync with origin/main — pull/push first"
git -C "$ROOT" rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1 \
  && die "tag $tag already exists"

# --- bump (idempotent), commit, tag, push -----------------------------------
if [ "$cur" != "$new" ]; then
  tmp="$(mktemp)"
  sed "s/^CANOPY_VERSION=\".*\"/CANOPY_VERSION=\"$new\"/" "$COMMON" > "$tmp"
  mv "$tmp" "$COMMON"
  git -C "$ROOT" add lib/common.sh
  git -C "$ROOT" commit -q -m "chore(release): $tag"
fi
git -C "$ROOT" tag -a "$tag" -m "canopy $tag"
git -C "$ROOT" push --quiet origin main "$tag"
echo "released $tag — the release workflow will run the test gate and publish the GitHub Release."
