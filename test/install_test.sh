#!/usr/bin/env bash
# install.sh: the curl one-liner installer (non-Homebrew path). Sandboxed via $HOME +
# a local origin (no network, no touching the real ~/.local / ~/.claude). Proves a
# fresh install, an idempotent re-run that UPDATES, corrupt-source recovery, the
# concurrency lock, and the missing-prereq guard. Run: bash test/install_test.sh
set -uo pipefail
CANOPY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }
command -v git >/dev/null || { echo "git required"; exit 1; }
ver() { sed -n 's/^CANOPY_VERSION="\([^"]*\)".*/\1/p' "$1" | head -1; }

INSTALL="$CANOPY_ROOT/install.sh"
[ -f "$INSTALL" ] || { echo "install.sh not found at $INSTALL"; exit 1; }

# --- build a local origin whose main = current tree, version bumped to observe it ---
S="$WORK/src"; git clone -q "$CANOPY_ROOT" "$S"
tar -C "$CANOPY_ROOT" --exclude .git -cf - . | tar -C "$S" -xf -
git -C "$S" config user.email t@t; git -C "$S" config user.name t
git -C "$S" checkout -q -B main
sed -i.bak 's/CANOPY_VERSION="[^"]*"/CANOPY_VERSION="9.9.9"/' "$S/lib/common.sh"; rm -f "$S/lib/common.sh.bak"
git -C "$S" add -A; git -C "$S" commit -qm "sandbox tree v9.9.9"
ORIGIN="$WORK/origin.git"; git clone -q --bare "$S" "$ORIGIN"
git -C "$S" remote set-url origin "$ORIGIN"

echo "== install.sh =="

# run_install <HOME> — drive the installer against the local origin, hermetic HOME.
run_install() {
  HOME="$1" CANOPY_REPO="$ORIGIN" CANOPY_CHANNEL_UPSTREAM="$ORIGIN" \
    CANOPY_NO_AUTOLINK=1 sh "$INSTALL"
}

# --- fresh install ---------------------------------------------------------
H="$WORK/home"; mkdir -p "$H"
if run_install "$H" >/dev/null 2>&1; then ok "fresh install exits 0"; else bad "fresh install failed"; fi
[ -L "$H/.local/bin/canopy" ] && ok "PATH symlink created" || bad "no PATH symlink"
[ -f "$H/.local/share/canopy/bin/canopy" ] && ok "CLI snapshot installed" || bad "no CLI snapshot"
[ -d "$H/.local/share/canopy/source/.git" ] && ok "managed source checkout created" || bad "no managed source"
[ "$(cat "$H/.local/share/canopy/.channel" 2>/dev/null)" = "stable" ] && ok "channel recorded stable" || bad "channel not recorded"
[ -f "$H/.claude/agents/worker.md" ] && ok "Claude defs wired (setup ran)" || bad "defs not wired"
if V="$(HOME="$H" "$H/.local/bin/canopy" --version 2>&1)" && [ "$V" = "canopy 9.9.9" ]; then
  ok "installed canopy runs standalone at v9.9.9"
else
  bad "installed canopy wrong/absent: $V"
fi
[ -e "$H/.local/share/canopy/source.tmp" ] && bad "source.tmp left behind" || ok "temp clone cleaned up"
[ -e "$H/.local/share/canopy/.install.lock" ] && bad "lock left behind" || ok "lock released"

# --- idempotent re-run UPDATES (advance origin to 9.9.10) ------------------
sed -i.bak 's/CANOPY_VERSION="[^"]*"/CANOPY_VERSION="9.9.10"/' "$S/lib/common.sh"; rm -f "$S/lib/common.sh.bak"
git -C "$S" commit -qam "bump v9.9.10"; git -C "$S" push -q origin main
if run_install "$H" >/dev/null 2>&1; then ok "re-run exits 0" ; else bad "re-run failed"; fi
if V="$(HOME="$H" "$H/.local/bin/canopy" --version 2>&1)" && [ "$V" = "canopy 9.9.10" ]; then
  ok "re-run UPDATED the install to v9.9.10"
else
  bad "re-run did not update: $V"
fi

# --- corrupt-source recovery (valid dir, no .git) --------------------------
rm -rf "$H/.local/share/canopy/source/.git"
if run_install "$H" >/dev/null 2>&1; then ok "recovery run exits 0"; else bad "recovery run failed"; fi
git -C "$H/.local/share/canopy/source" rev-parse --git-dir >/dev/null 2>&1 \
  && ok "corrupt source re-cloned into a valid git repo" || bad "source still corrupt"

# --- concurrency lock refuses a second run ---------------------------------
mkdir -p "$H/.local/share/canopy/.install.lock"
if run_install "$H" >/dev/null 2>&1; then bad "did not refuse while locked"; else ok "refuses to run while another holds the lock"; fi
rmdir "$H/.local/share/canopy/.install.lock"

# --- missing prereq (jq absent) → clear failure ----------------------------
B="$WORK/nojqbin"; mkdir -p "$B"
ln -sf "$(command -v git)" "$B/git"
ln -sf "$(command -v sh)" "$B/sh"
H2="$WORK/home2"; mkdir -p "$H2"
if OUT="$(HOME="$H2" PATH="$B" CANOPY_REPO="$ORIGIN" sh "$INSTALL" 2>&1)"; then
  bad "did not fail with jq missing"
else
  case "$OUT" in
    *"missing required prerequisite"*jq*) ok "missing jq → names it and exits nonzero" ;;
    *) bad "missing-jq error unclear: $OUT" ;;
  esac
fi

echo
echo "install.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
