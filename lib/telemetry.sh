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
  local rc="${1:-0}" cmd="${2:-}" sub="${3:-}" start="${4:-}" end duration result website host version payload
  website="${CANOPY_UMAMI_WEBSITE_ID:-${UMAMI_WEBSITE_ID:-}}"
  host="${CANOPY_UMAMI_HOST:-${UMAMI_HOST:-https://telemetry-umami.vercel.app}}"
  version="${CANOPY_VERSION:-dev}"
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
    --argjson duration "$duration" \
    '{
      type: "event",
      payload: {
        website: $website,
        hostname: "cli",
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

  curl -fsS --max-time 1 "$host/api/send" \
    -H "Content-Type: application/json" \
    -H "User-Agent: canopy/$version" \
    --data "$payload" >/dev/null 2>&1 || true
}
