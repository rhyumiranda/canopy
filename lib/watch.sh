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
  local pr="$1" st
  st="$(gh-axi pr view "$pr" 2>/dev/null | awk -F': *' 'tolower($1)~/(^|[[:space:]])state$/{print tolower($2); exit}')"
  st="${st//\"/}"
  [ "$st" = "merged" ]
}

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
      canopy_worktree_return "$id" 2>/dev/null || warn "watch: return had an issue for $id"
      task_status "$id" merged >/dev/null
      task_status "$id" done >/dev/null
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

# canopy watch install  -> write a launchd plist; DOES NOT load it (you run launchctl)
canopy_watch_install() {
  need git
  local root canopy_bin label plist interval="${1:-60}"
  root="$(repo_root)"
  canopy_bin="$CANOPY_ROOT/bin/canopy"
  label="com.canopy.watch.$(printf '%s' "$root" | shasum | cut -c1-8)"
  plist="$HOME/Library/LaunchAgents/${label}.plist"
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
  <key>StartInterval</key><integer>${interval}</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardErrorPath</key><string>${root}/.canopy/watch.log</string>
  <key>StandardOutPath</key><string>${root}/.canopy/watch.log</string>
</dict>
</plist>
EOF
  info "wrote launchd plist: $plist"
  log ""
  log "To START the watcher (run this yourself — Canopy will not touch launchd for you):"
  log "  launchctl bootstrap gui/\$(id -u) \"$plist\"   # or: launchctl load \"$plist\""
  log "To STOP it:"
  log "  launchctl bootout gui/\$(id -u)/${label}       # or: launchctl unload \"$plist\""
}
