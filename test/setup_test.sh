#!/usr/bin/env bash
# canopy setup: a real run installs + is labeled correctly; --dry-run only previews.
# Sandboxed via $HOME (setup.sh respects $HOME). Run: bash test/setup_test.sh
set -uo pipefail
CANOPY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }
command -v git >/dev/null || { echo "git required"; exit 1; }
ver() { sed -n 's/^CANOPY_VERSION="\([^"]*\)".*/\1/p' "$1/lib/common.sh" | head -1; }

S="$WORK/src"; git clone -q "$CANOPY_ROOT" "$S"; S="$(cd "$S" && pwd -P)"
tar -C "$CANOPY_ROOT" --exclude .git -cf - . | tar -C "$S" -xf -
git -C "$S" config user.email t@t; git -C "$S" config user.name t
git -C "$S" add -A
if ! git -C "$S" diff --cached --quiet; then
  git -C "$S" commit -qm "overlay current tree"
fi
git -C "$S" checkout -q -B main
sed -i.bak 's/CANOPY_VERSION="[^"]*"/CANOPY_VERSION="7.7.7"/' "$S/lib/common.sh"; rm -f "$S/lib/common.sh.bak"
git -C "$S" commit -qam "stable version"
git -C "$S" checkout -q -B rhyu/experimental-codex-package
sed -i.bak 's/CANOPY_VERSION="[^"]*"/CANOPY_VERSION="8.8.8"/' "$S/lib/common.sh"; rm -f "$S/lib/common.sh.bak"
git -C "$S" commit -qam "preview version"
git -C "$S" checkout -q -B rhyu/experimental-herdr-tabs
sed -i.bak 's/CANOPY_VERSION="[^"]*"/CANOPY_VERSION="8.9.0"/' "$S/lib/common.sh"; rm -f "$S/lib/common.sh.bak"
git -C "$S" commit -qam "herdr preview version"
ORIGIN="$WORK/origin.git"; git clone -q --bare "$S" "$ORIGIN"
git -C "$S" remote set-url origin "$ORIGIN"
git -C "$S" push -q -u origin main rhyu/experimental-codex-package rhyu/experimental-herdr-tabs 2>/dev/null
git -C "$S" checkout -q main
CANOPY="$S/bin/canopy"

echo "== canopy setup =="

# --- real run (sandboxed HOME) ---
H="$WORK/home"; mkdir -p "$H"
OUT="$(HOME="$H" CANOPY_CHANNEL_UPSTREAM="$ORIGIN" "$CANOPY" setup 2>&1)"
case "$OUT" in
  *"(dry-run)"*) bad "real setup must NOT be labeled (dry-run)" ;;
  *"done"*)      ok "real setup labeled plainly (not dry-run)" ;;
  *)             bad "real setup produced no 'done' line" ;;
esac
[ -f "$H/.claude/agents/worker.md" ]   && ok "worker agent installed"   || bad "worker agent not installed"
[ -f "$H/.claude/commands/yolo.md" ]   && ok "yolo command installed"   || bad "yolo command not installed"
[ -f "$H/.codex/canopy/agents/orchestrator.md" ] && ok "codex orchestrator packaged" || bad "codex orchestrator not packaged"
[ -f "$H/.codex/canopy/commands/yolo.md" ] && ok "codex commands packaged" || bad "codex commands not packaged"
[ -f "$H/.codex/canopy/hooks/session-start-digest.sh" ] && ok "codex hooks packaged" || bad "codex hooks not packaged"
[ -f "$H/.agents/skills/canopy-yolo/SKILL.md" ] && ok "codex yolo skill installed" || bad "codex yolo skill not installed"
[ -f "$H/.agents/skills/canopy-guided/SKILL.md" ] && ok "codex guided skill installed" || bad "codex guided skill not installed"
[ -f "$H/.agents/skills/canopy-hotfix/SKILL.md" ] && ok "codex hotfix skill installed" || bad "codex hotfix skill not installed"
[ -f "$H/.agents/skills/canopy-scribe/SKILL.md" ] && ok "codex scribe skill installed" || bad "codex scribe skill not installed"
[ -f "$H/.codex/skills/canopy-yolo/SKILL.md" ] && ok "legacy codex skill home populated" || bad "legacy codex skill home not populated"
[ -L "$H/.local/bin/canopy" ]          && ok "canopy symlinked on PATH" || bad "canopy not symlinked"
[ "$(cat "$H/.local/share/canopy/.channel" 2>/dev/null)" = "stable" ] && ok "default channel recorded as stable" || bad "default channel not recorded"
[ "$(cat "$H/.local/share/canopy/.channel-ref" 2>/dev/null)" = "main" ] && ok "stable channel maps to main" || bad "stable channel ref not recorded"

# --- stable snapshot: bin+lib+agents copied under ~/.local/share/canopy ---
APP="$H/.local/share/canopy"
[ -f "$APP/bin/canopy" ]               && ok "snapshot has bin/canopy"      || bad "snapshot missing bin/canopy"
[ -f "$APP/lib/common.sh" ]            && ok "snapshot has lib/"            || bad "snapshot missing lib/"
[ -f "$APP/agents/orchestrator.md" ]  && ok "snapshot has agents/"         || bad "snapshot missing agents/"
[ "$(ver "$APP")" = "7.7.7" ]          && ok "stable setup installs main branch version" || bad "stable setup did not install main branch version"
case "$(readlink "$H/.local/bin/canopy")" in
  "$APP/bin/canopy") ok "PATH symlink points at the snapshot, not the repo" ;;
  *)                 bad "PATH symlink does not point at the snapshot" ;;
esac

# --- the recurring bug: the INSTALLED command must find lib/ on its own ---
if OUTV="$(HOME="$H" "$H/.local/bin/canopy" version 2>&1)" && printf '%s' "$OUTV" | grep -q '^canopy '; then
  ok "installed canopy runs standalone (finds lib/)"
else
  bad "installed canopy cannot run: $OUTV"
fi

# --- guard: running setup from the installed snapshot refuses (no self-copy) ---
if HOME="$H" CANOPY_CHANNEL_UPSTREAM="$ORIGIN" "$H/.local/bin/canopy" setup >/dev/null 2>&1; then
  bad "setup from the installed snapshot should refuse"
else
  ok "setup from the installed snapshot refuses"
fi

# --- dry-run (fresh sandbox) previews without touching disk ---
H2="$WORK/home2"; mkdir -p "$H2"
OUT2="$(HOME="$H2" CANOPY_CHANNEL_UPSTREAM="$ORIGIN" "$CANOPY" setup --dry-run 2>&1)"
case "$OUT2" in
  *"(dry-run)"*) ok "dry-run is labeled (dry-run)" ;;
  *)             bad "dry-run not labeled" ;;
esac
[ -e "$H2/.claude/agents/worker.md" ] && bad "dry-run must not copy files" || ok "dry-run copied nothing"

# --- explicit preview channel is accepted and recorded ---
H3="$WORK/home3"; mkdir -p "$H3"
OUT3="$(HOME="$H3" CANOPY_CHANNEL_UPSTREAM="$ORIGIN" "$CANOPY" setup --channel codex-preview 2>&1)"
case "$OUT3" in
  *"channel=codex-preview"*) ok "preview setup reports preview channel" ;;
  *)                         bad "preview setup did not report preview channel" ;;
esac
APP3="$H3/.local/share/canopy"
[ "$(cat "$APP3/.channel" 2>/dev/null)" = "codex-preview" ] && ok "preview channel recorded" || bad "preview channel not recorded"
[ "$(cat "$APP3/.channel-ref" 2>/dev/null)" = "rhyu/experimental-codex-package" ] && ok "preview channel maps to experimental branch" || bad "preview channel ref not recorded"
[ "$(ver "$APP3")" = "8.8.8" ] && ok "preview setup installs preview branch version" || bad "preview setup did not install preview branch version"

# --- Herdr preview channel is explicit and isolated ---
H4="$WORK/home-herdr"; mkdir -p "$H4"
OUT4="$(HOME="$H4" CANOPY_CHANNEL_UPSTREAM="$ORIGIN" "$CANOPY" setup --channel herdr-preview 2>&1)"
case "$OUT4" in
  *"channel=herdr-preview"*) ok "Herdr preview setup reports its channel" ;;
  *)                          bad "Herdr preview setup did not report its channel" ;;
esac
APP4="$H4/.local/share/canopy"
[ "$(cat "$APP4/.channel" 2>/dev/null)" = "herdr-preview" ] && ok "Herdr preview channel recorded" || bad "Herdr preview channel not recorded"
[ "$(cat "$APP4/.channel-ref" 2>/dev/null)" = "rhyu/experimental-herdr-tabs" ] && ok "Herdr preview maps to experimental branch" || bad "Herdr preview branch mapping wrong"

# --- bad channel fails loudly ---
if HOME="$WORK/home4" CANOPY_CHANNEL_UPSTREAM="$ORIGIN" "$CANOPY" setup --channel nope >/dev/null 2>&1; then
  bad "unknown channel should fail"
else
  ok "unknown channel fails"
fi

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
