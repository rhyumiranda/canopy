# watch.sh — external merge-watcher. Sourced, not executed.
# shellcheck shell=bash
#
# Stateless reconcile: for each pr-open task, if its PR merged -> treehouse return
# + status=done. Meant to run from launchd/cron (`canopy watch once`), NOT as an
# in-session loop (those die on /clear). `canopy watch` is a foreground loop for
# testing only.

# best-effort desktop notification (opt-in via CANOPY_NOTIFY=1 to avoid surprises)
_notify() {
  local msg="$1"
  if [ "${CANOPY_NOTIFY:-0}" = "1" ] && command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$msg\" with title \"Canopy\"" >/dev/null 2>&1 || true
  fi
  info "$msg"
}

_pr_is_merged() {
  # Key on the `state:` field (open|merged|closed) — reliable. The `merged:` field
  # is a timestamp when merged, so it's not a yes/no.
  # grep/sed/tr, not awk: ubuntu's awk is mawk, whose regex/[[:space:]] handling
  # differs from BSD awk and silently mis-parses the state line.
  local pr="$1" st
  st="$(gh-axi pr view "$pr" 2>/dev/null \
        | grep -iE '^[[:space:]]*state[[:space:]]*:' | head -1 \
        | sed 's/^[^:]*:[[:space:]]*//' | tr -d '"' | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  [ "$st" = "merged" ]
}

# --- watcher identity + liveness (shared by install/status/ensure) ---
_watch_label() { printf 'com.canopy.watch.%s' "$(printf '%s' "$(repo_root)" | shasum | cut -c1-8)"; }
_watch_plist() { printf '%s/Library/LaunchAgents/%s.plist' "$HOME" "$(_watch_label)"; }
_watch_loaded() { command -v launchctl >/dev/null 2>&1 && launchctl list "$(_watch_label)" >/dev/null 2>&1; }
# repo under a macOS TCC-protected folder? (launchd can't read these without Full Disk Access)
_watch_tcc_risk() { case "$(repo_root)" in "$HOME"/Documents/*|"$HOME"/Desktop/*|"$HOME"/Downloads/*) return 0 ;; *) return 1 ;; esac; }

# canopy watch once  -> reconcile all pr-open tasks in THIS repo's state
canopy_watch_once() {
  require_canopy; need gh-axi; need jq
  local sf ids id pr
  sf="$(state_file)"
  ids="$(jq -r '.tasks[] | select(.status=="pr-open" and .pr!=null) | .id' "$sf")"
  [ -n "$ids" ] || { info "watch: no open PRs"; return 0; }
  while read -r id; do
    [ -n "$id" ] || continue
    pr="$(jq -r --arg id "$id" '.tasks[]|select(.id==$id)|.pr' "$sf")"
    if _pr_is_merged "$pr"; then
      _notify "task $id merged (PR #$pr) — returning worktree"
      # Record the terminal state FIRST, so worktree cleanup can never leave the
      # task stuck at pr-open. Run the return in a subshell: it may `die` (e.g. no
      # treehouse), and `die` exits the shell — a subshell contains that so the
      # reconcile continues.
      task_status "$id" merged >/dev/null
      task_status "$id" "done" >/dev/null
      # Stop any detached/live worker before releasing its worktree. Best effort:
      # a completed worker may already have exited, and cleanup must not block
      # reconciliation.
      ( canopy_worker_stop "$id" ) >/dev/null 2>&1 || warn "watch: worker stop had an issue for $id"
      ( canopy_worktree_return "$id" ) >/dev/null 2>&1 || warn "watch: worktree return had an issue for $id"
    else
      info "watch: PR #$pr still open ($id)"
    fi
  done <<< "$ids"
}

# canopy watch [interval]  -> foreground loop (testing only)
canopy_watch() {
  local interval="${1:-60}"
  info "watch loop every ${interval}s (Ctrl-C to stop) — for real use, install via 'canopy watch install'"
  while :; do canopy_watch_once; sleep "$interval"; done
}

# canopy watch install [--load] [interval]  -> write a launchd plist (+ optionally load it)
canopy_watch_install() {
  need git
  local root canopy_bin label plist interval=60 do_load=0 a
  for a in "$@"; do
    case "$a" in
      --load) do_load=1 ;;
      [0-9]*) interval="$a" ;;
      *) die "usage: canopy watch install [--load] [interval-seconds]" ;;
    esac
  done
  root="$(repo_root)"
  canopy_bin="$CANOPY_ROOT/bin/canopy"
  label="$(_watch_label)"
  plist="$(_watch_plist)"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string><string>-lc</string>
    <string>cd "${root}" &amp;&amp; "${canopy_bin}" watch once</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict><key>CANOPY_NOTIFY</key><string>1</string></dict>
  <key>StartInterval</key><integer>${interval}</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardErrorPath</key><string>${root}/.canopy/watch.log</string>
  <key>StandardOutPath</key><string>${root}/.canopy/watch.log</string>
</dict>
</plist>
EOF
  info "wrote launchd plist: $plist"
  if _watch_tcc_risk; then
    warn "this repo is under a macOS privacy-protected folder (~/Documents|Desktop|Downloads)."
    warn "the background watcher can't read it until you grant Full Disk Access to /bin/bash"
    warn "(System Settings > Privacy & Security > Full Disk Access), or move the repo elsewhere."
  fi
  if [ "$do_load" = 1 ]; then
    canopy_watch_ensure
  else
    log ""
    log "To START the watcher now:  canopy watch ensure    (or install with --load)"
    log "To STOP it:                launchctl bootout gui/\$(id -u)/${label}"
  fi
}

# canopy watch status  -> is the watcher installed, armed, and able to read this repo?
canopy_watch_status() {
  require_canopy
  local label plist log n
  label="$(_watch_label)"; plist="$(_watch_plist)"; log="$(canopy_dir)/watch.log"
  if [ -f "$plist" ]; then info "plist: installed ($plist)"; else warn "plist: NOT installed — run 'canopy watch install --load'"; fi
  if _watch_loaded; then info "daemon: armed ✓ ($label)"
  elif command -v launchctl >/dev/null 2>&1; then warn "daemon: NOT armed — run 'canopy watch ensure'"
  else warn "daemon: launchctl unavailable (non-macOS) — schedule 'canopy watch once' via cron"; fi
  if [ -f "$log" ] && grep -q 'Operation not permitted' "$log" 2>/dev/null; then
    warn "TCC: the watcher is BLOCKED from this folder (macOS privacy). Grant Full Disk Access to /bin/bash, or move the repo out of ~/Documents|Desktop|Downloads."
  fi
  n="$(jq -r '[.tasks[]|select(.status=="pr-open")]|length' "$(state_file)" 2>/dev/null || echo 0)"
  info "in-flight PRs awaiting merge: ${n:-0}"
}

# canopy watch ensure  -> arm the watcher if it isn't already (idempotent re-arm)
canopy_watch_ensure() {
  require_canopy
  local label plist; label="$(_watch_label)"; plist="$(_watch_plist)"
  command -v launchctl >/dev/null 2>&1 || { warn "launchctl unavailable (non-macOS) — schedule 'canopy watch once' via cron"; return 0; }
  [ -f "$plist" ] || { warn "no watcher installed here — run 'canopy watch install --load'"; return 0; }
  if _watch_loaded; then info "watcher already armed ($label)"; return 0; fi
  if launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || launchctl load "$plist" 2>/dev/null; then
    info "armed the merge-watcher ($label)"
    _watch_tcc_risk && warn "note: needs Full Disk Access for /bin/bash to read this ~/Documents repo (see 'canopy watch status')"
  else
    warn "could not arm the watcher — load it manually: launchctl bootstrap gui/\$(id -u) \"$plist\""
  fi
  return 0
}
