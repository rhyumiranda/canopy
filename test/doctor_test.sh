#!/usr/bin/env bash
# canopy doctor — read-only install/prereq health check.
# Hermetic: every run uses a sandbox PATH (stub prereqs) + a sandbox HOME, so the
# result never depends on what's installed on the host and nothing real is touched.
# Run: env -u CANOPY_ROLE bash test/doctor_test.sh
set -uo pipefail
unset CANOPY_ROLE 2>/dev/null || true   # doctor isn't worker-allowlisted; run role-free
CANOPY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANOPY="$CANOPY_ROOT/bin/canopy"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
has()  { case "$2" in *"$1"*) ok "$3" ;; *) bad "$3 — output was: $2" ;; esac; }
hasnt(){ case "$2" in *"$1"*) bad "$3 — unexpectedly saw '$1'" ;; *) ok "$3" ;; esac; }
command -v jq  >/dev/null || { echo "jq required";  exit 1; }
command -v git >/dev/null || { echo "git required"; exit 1; }
BASH_REAL="$(command -v bash)"
VERSION="$(sed -n 's/^CANOPY_VERSION="\([^"]*\)".*/\1/p' "$CANOPY_ROOT/lib/common.sh" | head -1)"

# make_sandbox <dir> [omit] — symlink the real tools doctor+bin/canopy need into a
# clean bin dir and drop stub prereqs (claude/treehouse/gh-axi). Pass a name in [omit]
# to leave that prereq OUT (simulating a missing dependency).
make_sandbox() {
  local sb="$1" omit="${2:-}" t p
  mkdir -p "$sb"
  for t in bash sh env dirname basename grep head cat uname sed date mktemp ln readlink git jq; do
    p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$sb/$t"
  done
  if [ "$omit" != claude ]; then
    printf '#!/bin/sh\n[ "$1" = "--version" ] && echo "2.1.0 (Claude Code)"\n' > "$sb/claude"; chmod +x "$sb/claude"
  fi
  [ "$omit" != treehouse ] && { printf '#!/bin/sh\nexit 0\n' > "$sb/treehouse"; chmod +x "$sb/treehouse"; }
  [ "$omit" != gh-axi ]    && { printf '#!/bin/sh\nexit 0\n' > "$sb/gh-axi";    chmod +x "$sb/gh-axi"; }
}

# run_doctor <sandbox> <home> — end-to-end via bin/canopy with a sandbox PATH + HOME.
# Prints combined output; the caller inspects $? separately.
run_doctor() {
  PATH="$1" HOME="$2" CANOPY_NO_AUTOLINK=1 "$BASH_REAL" "$CANOPY" doctor 2>&1
}

echo "== canopy doctor: green path (all prereqs present, marker current) =="
SB="$WORK/sb-green"; make_sandbox "$SB"
HG="$WORK/h-green"; mkdir -p "$HG/.claude/canopy"
printf '%s\n' "$VERSION" > "$HG/.claude/canopy/.linked-version"
OUT="$(run_doctor "$SB" "$HG")"; RC=$?
[ "$RC" = 0 ] && ok "green path exits 0" || bad "green path exit was $RC"
has "all hard prerequisites present" "$OUT" "green path reports all hard prereqs present"
has "wired, current" "$OUT" "green path sees the wiring marker as current"
has "source clone" "$OUT" "green path reports the clone install method"
has "canopy upgrade" "$OUT" "green path shows the clone update command"

echo
echo "== canopy doctor: red path (missing hard prereq -> non-zero) =="
SBR="$WORK/sb-noclaude"; make_sandbox "$SBR" claude
HR="$WORK/h-red"; mkdir -p "$HR"
OUT="$(run_doctor "$SBR" "$HR")"; RC=$?
[ "$RC" != 0 ] && ok "missing claude exits non-zero" || bad "missing claude still exited 0"
has "missing (required)" "$OUT" "missing claude is flagged required"
has "hard prerequisite" "$OUT" "red path prints the hard-prereq summary"
has "https://claude.com/claude-code" "$OUT" "red path prints the claude install fix"

echo
echo "== canopy doctor: soft prereq missing stays green (exit 0) =="
SBS="$WORK/sb-notree"; make_sandbox "$SBS" treehouse
HS="$WORK/h-soft"; mkdir -p "$HS/.claude/canopy"
printf '%s\n' "$VERSION" > "$HS/.claude/canopy/.linked-version"
OUT="$(run_doctor "$SBS" "$HS")"; RC=$?
[ "$RC" = 0 ] && ok "missing treehouse (soft) still exits 0" || bad "soft-miss exit was $RC"
has "missing (optional)" "$OUT" "missing treehouse is flagged optional, not required"

echo
echo "== canopy doctor: stale wiring marker is detected (soft, exit 0) =="
SBT="$WORK/sb-stale"; make_sandbox "$SBT"
HT="$WORK/h-stale"; mkdir -p "$HT/.claude/canopy"
printf '%s\n' "0.0.1-old" > "$HT/.claude/canopy/.linked-version"
OUT="$(run_doctor "$SBT" "$HT")"; RC=$?
[ "$RC" = 0 ] && ok "stale marker still exits 0 (wiring is soft)" || bad "stale-marker exit was $RC"
has "stale" "$OUT" "stale marker is reported"
has "canopy setup --link" "$OUT" "stale marker suggests the relink fix"

echo
echo "== canopy doctor: not-wired marker is detected =="
SBN="$WORK/sb-nowire"; make_sandbox "$SBN"
HN="$WORK/h-nowire"; mkdir -p "$HN"
OUT="$(run_doctor "$SBN" "$HN")"
has "not wired" "$OUT" "missing marker reports not wired"
has "canopy setup --link" "$OUT" "missing marker suggests the relink fix"

echo
echo "== canopy doctor: brew vs clone PATH + update line =="
# Source-based so we can override CANOPY_ROOT into a fake Cellar (bin/canopy exports
# its own CANOPY_ROOT from its real path, so a brew layout can't be faked end-to-end).
# A brew stub reports a prefix; run from a NON-git dir so the macOS watch block skips.
NONGIT="$WORK/nongit"; mkdir -p "$NONGIT"
SBB="$WORK/sb-brew"; mkdir -p "$SBB"
printf '#!/bin/sh\n[ "$1" = "--prefix" ] && echo "%s/fakeprefix"\nexit 0\n' "$WORK" > "$SBB/brew"; chmod +x "$SBB/brew"
printf '#!/bin/sh\n[ "$1" = "--version" ] && echo "2.1.0"\n' > "$SBB/claude"; chmod +x "$SBB/claude"

# brew install: root under <prefix>/Cellar -> Homebrew method + brew update line + brew bin
BREW_OUT="$(
  cd "$NONGIT" || exit 1
  . "$CANOPY_ROOT/lib/common.sh"
  . "$CANOPY_ROOT/lib/doctor.sh"
  PATH="$SBB:$PATH"
  CANOPY_ROOT="$WORK/fakeprefix/Cellar/canopy/9.9.9/libexec"
  canopy_doctor 2>&1 || true
)"
has "Homebrew" "$BREW_OUT" "brew install reports the Homebrew method"
has "brew upgrade canopy" "$BREW_OUT" "brew install shows the brew update command"
has "$WORK/fakeprefix/bin" "$BREW_OUT" "brew install checks/prints the Homebrew bin dir"
hasnt "canopy upgrade" "$BREW_OUT" "brew install does NOT show the clone update command"

# clone install: no brew -> clone method + ~/.local/bin PATH fix line
CLONE_OUT="$(
  cd "$NONGIT" || exit 1
  . "$CANOPY_ROOT/lib/common.sh"
  . "$CANOPY_ROOT/lib/doctor.sh"
  PATH="$SBB:$PATH"
  unset -f brew 2>/dev/null || true
  rm -f "$SBB/brew"      # ensure no brew on PATH -> not a brew install
  HOME="$WORK/h-clonepath"
  canopy_doctor 2>&1 || true
)"
has "source clone" "$CLONE_OUT" "clone install reports the clone method"
has "$WORK/h-clonepath/.local/bin" "$CLONE_OUT" "clone install checks/prints ~/.local/bin"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
