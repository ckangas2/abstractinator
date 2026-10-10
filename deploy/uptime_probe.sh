#!/usr/bin/env bash
# One probe tick for The Abstractinator. Appends a row per target to a CSV.
#
# Probes the PUBLIC url and the LOCAL origin for the same thing, so a failure
# can be attributed:
#   public fails + local ok     -> Cloudflare tunnel / edge
#   public fails + local fails  -> the app or the service itself
#   both ok                     -> fine
#
# Run from a systemd timer every minute. Appends to:
#   ~/abstractinator-analytics/uptime.csv
#
# Usage: ./uptime_probe.sh [CSV_PATH]

set -uo pipefail   # NOT -e: a failed probe is data, not a crash

CSV="${1:-$HOME/abstractinator-analytics/uptime.csv}"
mkdir -p "$(dirname "$CSV")"

if [ ! -s "$CSV" ]; then
  echo "timestamp,scope,target,http_code,time_total,size_bytes,curl_exit" > "$CSV"
fi

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

probe() {
  # probe <scope> <label> <url> [extra curl args...]
  local scope="$1" label="$2" url="$3"; shift 3
  local out code time size rc
  out="$(curl -sS -o /dev/null -m 20 \
          -A "abstractinator-uptime-probe/1" \
          -w "%{http_code},%{time_total},%{size_download}" \
          "$@" "$url" 2>/dev/null)"
  rc=$?
  if [ $rc -ne 0 ] || [ -z "$out" ]; then
    out="000,0,0"
  fi
  printf '%s,%s,%s,%s,%s\n' "$TS" "$scope" "$label" "$out" "$rc" >> "$CSV"
}

# --- public, through Cloudflare -------------------------------------------
probe public app          "https://abstractinator.me/"
# llms.txt is static; the / probe already covers edge+origin
probe public mcp_root     "https://mcp.abstractinator.me/"

# --- local, straight at the origin ----------------------------------------
probe local  shiny        "http://localhost:3838/abstractinator/"
probe local  api_health   "http://localhost:8100/health"

# MCP needs a real JSON-RPC body; a bare GET looks like a hang.
probe local  mcp_init     "http://localhost:8200/mcp" \
  -X POST \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"uptime-probe","version":"1"}}}'
