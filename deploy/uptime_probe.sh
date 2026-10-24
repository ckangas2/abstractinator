#!/usr/bin/env bash
# One probe tick for The Abstractinator. Appends a row per target to a CSV,
# and notifies on state CHANGES if an alert webhook is configured.
#
# Probes the PUBLIC url and the LOCAL origin for the same thing, so a failure
# can be attributed:
#   public fails + local ok     -> Cloudflare tunnel / edge
#   public fails + local fails  -> the app or the service itself
#   both ok                     -> fine
#
# Run from a systemd timer. Appends to:
#   ~/abstractinator-analytics/uptime.csv
# and keeps one state file per target under .../uptime-state/ so an outage is
# reported once rather than every tick.
#
# ALERTING (optional). Put a webhook URL in ~/.config/abstractinator/alert.env:
#   ABSTRACTINATOR_ALERT_URL="https://ntfy.sh/your-private-topic-name"
# Any endpoint accepting a POST with a plain-text body works -- ntfy, Discord
# and Slack webhooks, Pushover, your own handler. With nothing configured the
# probe behaves exactly as before. Keep that file chmod 600: a webhook URL is
# a credential, the same as the Cloudflare token beside it.
#
# Verify a webhook without waiting for an outage:
#   ABSTRACTINATOR_ALERT_TEST=1 ./deploy/uptime_probe.sh
#
# Usage: ./uptime_probe.sh [CSV_PATH]

set -uo pipefail   # NOT -e: a failed probe is data, not a crash

CSV="${1:-$HOME/abstractinator-analytics/uptime.csv}"
mkdir -p "$(dirname "$CSV")"
STATE_DIR="$(dirname "$CSV")/uptime-state"
mkdir -p "$STATE_DIR"

# How many consecutive failures before alerting. 2 rides out a single blip or
# a restart landing on a tick; with a 15-minute timer that delays a real alert
# by one interval. Set to 1 for faster alerts and more false positives.
FAIL_THRESHOLD="${ABSTRACTINATOR_FAIL_THRESHOLD:-2}"

# shellcheck disable=SC1090
[ -r "$HOME/.config/abstractinator/alert.env" ] && . "$HOME/.config/abstractinator/alert.env"
ALERT_URL="${ABSTRACTINATOR_ALERT_URL:-}"

notify() {
  # notify <message>. Always logged to the journal; POSTed only if configured.
  local msg="$1"
  echo "[uptime] $msg" >&2
  [ -n "$ALERT_URL" ] || return 0
  curl -sS -m 10 -X POST --data-binary "$msg" "$ALERT_URL" >/dev/null 2>&1 || \
    echo "[uptime] alert POST failed" >&2
}

if [ "${ABSTRACTINATOR_ALERT_TEST:-0}" = "1" ]; then
  if [ -z "$ALERT_URL" ]; then
    echo "No ABSTRACTINATOR_ALERT_URL set in ~/.config/abstractinator/alert.env" >&2
    exit 1
  fi
  notify "Abstractinator: uptime probe test alert ($(date -u +%Y-%m-%dT%H:%M:%SZ)). If you can read this, alerting works."
  exit 0
fi

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

track() {
  # track <label> <ok:0|1> <code> <scope>
  local label="$1" ok="$2" code="$3" scope="$4"
  local f="$STATE_DIR/$label" prev="ok" streak=0
  if [ -r "$f" ]; then read -r prev streak < "$f" 2>/dev/null || { prev=ok; streak=0; }; fi
  [ -n "${streak//[!0-9]/}" ] || streak=0

  if [ "$ok" = "1" ]; then
    if [ "$prev" = "down" ]; then
      notify "Abstractinator RECOVERED: $scope/$label is back (HTTP $code) at $TS"
    fi
    printf 'ok 0\n' > "$f"
  else
    streak=$((streak + 1))
    if [ "$prev" != "down" ] && [ "$streak" -ge "$FAIL_THRESHOLD" ]; then
      notify "Abstractinator DOWN: $scope/$label failing (HTTP $code, $streak consecutive) at $TS"
      printf 'down %s\n' "$streak" > "$f"
    elif [ "$prev" = "down" ]; then
      printf 'down %s\n' "$streak" > "$f"
    else
      printf 'ok %s\n' "$streak" > "$f"
    fi
  fi
}

if [ ! -s "$CSV" ]; then
  echo "timestamp,scope,target,http_code,time_total,size_bytes,curl_exit" > "$CSV"
fi

probe() {
  # probe <scope> <label> <url> [extra curl args...]
  local scope="$1" label="$2" url="$3"; shift 3
  local out code rc
  out="$(curl -sS -o /dev/null -m 20 \
          -A "abstractinator-uptime-probe/1" \
          -w "%{http_code},%{time_total},%{size_download}" \
          "$@" "$url" 2>/dev/null)"
  rc=$?
  if [ $rc -ne 0 ] || [ -z "$out" ]; then
    out="000,0,0"
  fi
  printf '%s,%s,%s,%s,%s\n' "$TS" "$scope" "$label" "$out" "$rc" >> "$CSV"

  # 2xx and 3xx are healthy: mcp_root is a deliberate 302 to llms.txt.
  code="${out%%,*}"
  case "$code" in
    2??|3??) track "$label" 1 "$code" "$scope" ;;
    *)       track "$label" 0 "$code" "$scope" ;;
  esac
}

# --- public, through Cloudflare -------------------------------------------
probe public app          "https://abstractinator.me/"
# llms.txt is static; the / probe already covers edge+origin
probe public mcp_root     "https://mcp.abstractinator.me/"

# --- local, straight at the origin ----------------------------------------
probe local  shiny        "http://localhost:3838/"
probe local  api_health   "http://localhost:8100/health"

# MCP needs a real JSON-RPC body; a bare GET looks like a hang.
probe local  mcp_init     "http://localhost:8200/mcp" \
  -X POST \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"uptime-probe","version":"1"}}}'
