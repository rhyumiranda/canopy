#!/usr/bin/env bash
# canopy setup --link / --unlink, first-run auto-wire, and is_brew_install.
# All wiring is $HOME-scoped, so every case runs under a sandboxed HOME — nothing
# touches the real ~/.claude. Run: env -u CANOPY_ROLE bash test/link_test.sh
set -uo pipefail
CANOPY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANOPY="$CANOPY_ROOT/bin/canopy"
PASS=0; FAIL=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
command -v jq  >/dev/null || { echo "jq required";  exit 1; }
command -v git >/dev/null || { echo "git required"; exit 1; }
ver() { sed -n 's/^CANOPY_VERSION="\([^"]*\)".*/\1/p' "$1/lib/common.sh" | head -1; }
VERSION="$(ver "$CANOPY_ROOT")"

echo "== canopy setup --link / --unlink =="

# --- --link wires the defs only (no CLI snapshot, no PATH symlink) ---
H="$WORK/h-link"; mkdir -p "$H"
OUT="$(HOME="$H" "$CANOPY" setup --link 2>&1)"
case "$OUT" in *"--link"*"done"*) ok "--link reports a done line" ;; *) bad "--link produced no done line: $OUT" ;; esac
[ -f "$H/.claude/agents/worker.md" ]                    && ok "--link installs Claude agents"   || bad "--link did not install Claude agents"
[ -f "$H/.claude/commands/yolo.md" ]                    && ok "--link installs Claude commands" || bad "--link did not install Claude commands"
[ -f "$H/.claude/canopy/hooks/session-start-digest.sh" ] && ok "--link installs Claude hooks"  || bad "--link did not install Claude hooks"
[ -f "$H/.codex/canopy/agents/orchestrator.md" ]        && ok "--link packages Codex defs"      || bad "--link did not package Codex defs"
[ -f "$H/.agents/skills/canopy-yolo/SKILL.md" ]         && ok "--link installs Codex skills"    || bad "--link did not install Codex skills"
[ "$(cat "$H/.claude/canopy/.linked-version" 2>/dev/null)" = "$VERSION" ] && ok "--link writes the version marker" || bad "--link marker missing/wrong"
# the wiring half must NOT build a CLI snapshot or PATH symlink
[ ! -e "$H/.local/share/canopy/bin" ] && ok "--link builds no CLI snapshot" || bad "--link unexpectedly built a snapshot"
[ ! -e "$H/.local/bin/canopy" ]       && ok "--link creates no PATH symlink" || bad "--link unexpectedly created a PATH symlink"
# brew installs have no .source checkout — channel metadata is seeded, .source is NOT
[ "$(cat "$H/.local/share/canopy/.channel" 2>/dev/null)" = "stable" ] && ok "--link seeds channel metadata" || bad "--link did not seed channel metadata"
[ ! -e "$H/.local/share/canopy/.source" ] && ok "--link writes no .source record" || bad "--link unexpectedly wrote .source"

# --- --link is idempotent (re-run succeeds, marker stable) ---
HOME="$H" "$CANOPY" setup --link >/dev/null 2>&1 && ok "--link re-run succeeds (idempotent)" || bad "--link re-run failed"
[ "$(cat "$H/.claude/canopy/.linked-version" 2>/dev/null)" = "$VERSION" ] && ok "--link re-run keeps the marker" || bad "--link re-run lost the marker"

# --- --unlink removes only canopy's files; user agent + settings.json survive ---
H2="$WORK/h-unlink"; mkdir -p "$H2/.claude/agents"
printf 'my own agent\n' > "$H2/.claude/agents/my-own.md"
printf '{"hooks":{"mine":1}}\n' > "$H2/.claude/settings.json"     # a real user settings.json
BEFORE="$(cat "$H2/.claude/settings.json")"
HOME="$H2" "$CANOPY" setup --link >/dev/null 2>&1
[ -f "$H2/.claude/agents/worker.md" ] && ok "planted state: link installed a canopy agent" || bad "planted state: link failed"
OUT2="$(HOME="$H2" "$CANOPY" setup --unlink 2>&1)"
case "$OUT2" in *"removed"*"settings.json left untouched"*) ok "--unlink prints the removed/untouched summary" ;; *) bad "--unlink summary wrong: $OUT2" ;; esac
[ ! -e "$H2/.claude/agents/worker.md" ] && ok "--unlink removes canopy's agent" || bad "--unlink left canopy's agent"
[ -f "$H2/.claude/agents/my-own.md" ]   && ok "--unlink keeps the user's own agent" || bad "--unlink deleted the user's own agent"
[ "$(cat "$H2/.claude/settings.json")" = "$BEFORE" ] && ok "--unlink leaves settings.json untouched" || bad "--unlink modified settings.json"
[ ! -e "$H2/.claude/canopy/.linked-version" ] && ok "--unlink removes the marker" || bad "--unlink left the marker"
[ ! -e "$H2/.codex/canopy" ]            && ok "--unlink removes the Codex package" || bad "--unlink left the Codex package"
[ ! -e "$H2/.agents/skills/canopy-yolo" ] && ok "--unlink removes the Codex skills" || bad "--unlink left the Codex skills"
# --unlink is idempotent (second run is a no-op, still exits 0)
HOME="$H2" "$CANOPY" setup --unlink >/dev/null 2>&1 && ok "--unlink re-run is a no-op" || bad "--unlink re-run failed"

echo
echo "== first-run auto-wire =="
# A scratch git repo so a real (non-skip) command dispatches after auto-wire.
RG="$WORK/repo"; mkdir -p "$RG"
( cd "$RG" && git init -q && git config user.email t@t && git config user.name t \
    && echo hi > f.txt && git add -A && git commit -qm init ) >/dev/null 2>&1

# --- fires once on the first real command, then is skipped when the marker is current ---
HW="$WORK/h-aw"; mkdir -p "$HW"
OUTA="$(cd "$RG" && env -u CANOPY_NO_AUTOLINK HOME="$HW" "$CANOPY" init 2>&1)"
case "$OUTA" in *"wired Claude/Codex defs"*) ok "auto-wire fires on the first real command" ;; *) bad "auto-wire did not fire: $OUTA" ;; esac
[ -f "$HW/.claude/agents/worker.md" ] && ok "auto-wire installs the defs" || bad "auto-wire installed no defs"
[ "$(cat "$HW/.claude/canopy/.linked-version" 2>/dev/null)" = "$VERSION" ] && ok "auto-wire writes the marker" || bad "auto-wire marker missing/wrong"
OUTB="$(cd "$RG" && env -u CANOPY_NO_AUTOLINK HOME="$HW" "$CANOPY" status 2>&1)"
case "$OUTB" in *"wired Claude/Codex defs"*) bad "auto-wire fired again with a current marker" ;; *) ok "auto-wire is skipped once the marker is current" ;; esac

# --- CANOPY_NO_AUTOLINK=1 skips ---
HN="$WORK/h-noauto"; mkdir -p "$HN"
( cd "$RG" && CANOPY_NO_AUTOLINK=1 HOME="$HN" "$CANOPY" status >/dev/null 2>&1 ) || true
[ ! -e "$HN/.claude/agents/worker.md" ] && ok "CANOPY_NO_AUTOLINK=1 skips auto-wire" || bad "CANOPY_NO_AUTOLINK=1 did not skip"

# --- CANOPY_ROLE=worker skips (detached workers must not race to wire) ---
HK="$WORK/h-worker"; mkdir -p "$HK"
( cd "$RG" && env -u CANOPY_NO_AUTOLINK CANOPY_ROLE=worker HOME="$HK" "$CANOPY" status >/dev/null 2>&1 ) || true
[ ! -e "$HK/.claude/agents/worker.md" ] && ok "CANOPY_ROLE=worker skips auto-wire" || bad "worker role did not skip"

# --- --no-autolink skips ---
HF="$WORK/h-flag"; mkdir -p "$HF"
( cd "$RG" && env -u CANOPY_NO_AUTOLINK HOME="$HF" "$CANOPY" status --no-autolink >/dev/null 2>&1 ) || true
[ ! -e "$HF/.claude/agents/worker.md" ] && ok "--no-autolink skips auto-wire" || bad "--no-autolink did not skip"

# --- mkdir-lock: a pre-existing lock means another proc is wiring -> skip silently ---
HL="$WORK/h-lock"; mkdir -p "$HL/.claude/canopy/.wire.lock"
( cd "$RG" && env -u CANOPY_NO_AUTOLINK HOME="$HL" "$CANOPY" status >/dev/null 2>&1 ) || true
{ [ ! -e "$HL/.claude/agents/worker.md" ] && [ ! -e "$HL/.claude/canopy/.linked-version" ]; } \
  && ok "held lock prevents a concurrent double-wire" || bad "held lock did not prevent wiring"

echo
echo "== is_brew_install =="
LIB="$CANOPY_ROOT/lib/common.sh"   # source common.sh from the real checkout, override CANOPY_ROOT
# false: the running canopy checkout is not under a Homebrew Cellar (with or without brew)
if ( . "$LIB"; CANOPY_ROOT="$CANOPY_ROOT"; is_brew_install ); then
  bad "is_brew_install true for a non-Cellar checkout"
else
  ok "is_brew_install false when the root is not under Cellar"
fi
# true: fake a brew that reports a prefix, and place CANOPY_ROOT under <prefix>/Cellar
BSTUB="$WORK/brewbin"; mkdir -p "$BSTUB"
cat > "$BSTUB/brew" <<EOF
#!/usr/bin/env bash
[ "\$1" = "--prefix" ] && echo "$WORK/brewprefix"
exit 0
EOF
chmod +x "$BSTUB/brew"
FAKEROOT="$WORK/brewprefix/Cellar/canopy/9.9.9/libexec"; mkdir -p "$FAKEROOT"
if ( . "$LIB"; PATH="$BSTUB:$PATH"; CANOPY_ROOT="$FAKEROOT"; is_brew_install ); then
  ok "is_brew_install true when the root is under <brew-prefix>/Cellar"
else
  bad "is_brew_install false for a Cellar-resident root"
fi

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
