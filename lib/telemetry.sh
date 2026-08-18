# telemetry.sh — best-effort private Umami events. Sourced, not executed.
# shellcheck shell=bash

_canopy_telemetry_now() { date +%s; }

_canopy_telemetry_enabled() {
  [ "${CANOPY_TELEMETRY:-1}" = 0 ] && return 1
  [ "${UMAMI_TELEMETRY:-1}" = 0 ] && return 1
  [ -n "${CANOPY_UMAMI_WEBSITE_ID:-${UMAMI_WEBSITE_ID:-}}" ] || return 1
  command -v curl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  return 0
}

_canopy_telemetry_track_command() {
  _canopy_telemetry_enabled || return 0
  local rc="${1:-0}" cmd="${2:-}" sub="${3:-}" start="${4:-}" end duration result website host version user_agent payload
  website="${CANOPY_UMAMI_WEBSITE_ID:-${UMAMI_WEBSITE_ID:-}}"
  host="${CANOPY_UMAMI_HOST:-${UMAMI_HOST:-https://telemetry-umami.vercel.app}}"
  version="${CANOPY_VERSION:-dev}"
  user_agent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  end="$(_canopy_telemetry_now)"
  duration=0
  [ -n "$start" ] && duration=$(( (end - start) * 1000 ))
  result="success"
  [ "$rc" -eq 0 ] || result="error"

  payload="$(jq -n \
    --arg website "$website" \
    --arg tool "canopy" \
    --arg version "$version" \
    --arg command "${cmd:-none}" \
    --arg subcommand "${sub:-none}" \
    --arg result "$result" \
    --arg user_agent "$user_agent" \
    --argjson duration "$duration" \
    '{
      type: "event",
      payload: {
        website: $website,
        hostname: "cli",
        userAgent: $user_agent,
        url: ("/commands/" + $command),
        title: "canopy",
        name: "command-run",
        data: {
          tool: $tool,
          version: $version,
          command: $command,
          subcommand: $subcommand,
          result: $result,
          duration_ms: $duration
        }
      }
    }')" || return 0

  # Fire-and-forget: this runs inside canopy's EXIT trap (bin/canopy), so it must
  # NEVER delay command exit. Detach fully — a plain `&` child could catch SIGHUP as
  # the parent shell ends, so run it in a subshell with `nohup` (macOS bash 3.2 has no
  # `setsid`): the subshell backgrounds the curl and exits at once, reparenting it, and
  # nohup makes it ignore the hangup. All output already goes to /dev/null. --max-time
  # is now just a safety bound on the detached process, not a block on the user.
  ( nohup curl -fsS --max-time "${CANOPY_TELEMETRY_TIMEOUT:-3}" "$host/api/send" \
      -H "Content-Type: application/json" \
      -H "User-Agent: $user_agent" \
      --data "$payload" >/dev/null 2>&1 & ) >/dev/null 2>&1 || true
}
