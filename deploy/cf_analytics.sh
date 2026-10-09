#!/usr/bin/env bash
# Pull Cloudflare analytics for abstractinator.me into CSVs via the GraphQL
# Analytics API. Works on the free plan for the daily/aggregate datasets; the
# per-request "adaptive" datasets are attempted and skipped with a note if the
# plan does not include them.
#
# Usage:  ./cf_analytics.sh [DAYS] [OUTDIR]
#   DAYS   lookback window in days (default 7)
#   OUTDIR where CSVs land (default ~/abstractinator-analytics/<today>)
#
# Reads credentials from ~/.config/abstractinator/cloudflare.env (chmod 600):
#   CLOUDFLARE_API_TOKEN=...
#   CLOUDFLARE_ACCOUNT_ID=...
#   CLOUDFLARE_ZONE_NAME=abstractinator.me

set -euo pipefail

ENV_FILE="${CF_ENV_FILE:-$HOME/.config/abstractinator/cloudflare.env}"
if [ ! -r "$ENV_FILE" ]; then
  echo "ERROR: cannot read $ENV_FILE" >&2
  exit 1
fi
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN not set in $ENV_FILE}"
ZONE_NAME="${CLOUDFLARE_ZONE_NAME:-abstractinator.me}"

DAYS="${1:-7}"
OUTDIR="${2:-$HOME/abstractinator-analytics/$(date -u +%Y-%m-%d)}"
mkdir -p "$OUTDIR"

API="https://api.cloudflare.com/client/v4"
AUTH_H="Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"

command -v jq >/dev/null || { echo "ERROR: jq is required (sudo apt install jq)" >&2; exit 1; }

say() { printf '==> %s\n' "$*"; }

# ---------------------------------------------------------------- token check
# Account-owned tokens (cfat_ prefix) verify under /accounts/<id>/tokens/verify;
# older user-owned tokens verify under /user/tokens/verify. Try whichever fits.
say "Verifying token"
verify_ok=0
if [ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then
  if curl -sS -H "$AUTH_H" \
       "$API/accounts/${CLOUDFLARE_ACCOUNT_ID}/tokens/verify" \
       | jq -e '.success == true' >/dev/null 2>&1; then
    verify_ok=1
    say "  account-owned token, active"
  fi
fi
if [ "$verify_ok" -eq 0 ]; then
  if curl -sS -H "$AUTH_H" "$API/user/tokens/verify" \
       | jq -e '.success == true' >/dev/null 2>&1; then
    verify_ok=1
    say "  user-owned token, active"
  fi
fi
if [ "$verify_ok" -eq 0 ]; then
  echo "WARNING: could not verify the token at either endpoint." >&2
  echo "         Continuing anyway - the queries below will show the real error." >&2
fi

# ------------------------------------------------------------------- zone id
ZONE_ID="$(curl -sS -H "$AUTH_H" "$API/zones?name=${ZONE_NAME}" \
            | jq -r '.result[0].id // empty')"
if [ -z "$ZONE_ID" ]; then
  echo "ERROR: could not resolve zone id for ${ZONE_NAME}." >&2
  echo "       The token needs Zone > Zone > Read on that zone." >&2
  exit 1
fi
say "Zone ${ZONE_NAME} = ${ZONE_ID}"

SINCE_D="$(date -u -d "${DAYS} days ago" +%Y-%m-%d)"
UNTIL_D="$(date -u +%Y-%m-%d)"
SINCE_T="$(date -u -d "${DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ)"
UNTIL_T="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "Window ${SINCE_D} .. ${UNTIL_D} (UTC)"

# ---------------------------------------------------------------- gql helper
RAW_DIR="$OUTDIR/raw"
mkdir -p "$RAW_DIR"

gql() {
  # gql <name> <query> <variables-json>  -> writes raw JSON, returns 0 on success
  local name="$1" query="$2" vars="$3" body resp
  body="$(jq -n --arg q "$query" --argjson v "$vars" '{query:$q, variables:$v}')"
  resp="$(curl -sS -H "$AUTH_H" -H 'Content-Type: application/json' \
            --data "$body" "$API/graphql")"
  printf '%s' "$resp" > "$RAW_DIR/${name}.json"
  if printf '%s' "$resp" | jq -e '(.errors // empty) | length > 0' >/dev/null; then
    echo "    SKIPPED ${name}: $(printf '%s' "$resp" | jq -r '[.errors[].message] | join("; ")')" >&2
    return 1
  fi
  return 0
}

# ============================================================ 1. daily totals
say "Daily totals (httpRequests1dGroups)"
Q_DAILY='query($zone:String!,$since:Date!,$until:Date!){
  viewer{ zones(filter:{zoneTag:$zone}){
    httpRequests1dGroups(limit:1000, filter:{date_geq:$since, date_leq:$until},
                         orderBy:[date_ASC]){
      dimensions{ date }
      sum{ requests cachedRequests bytes cachedBytes pageViews threats
           encryptedRequests
           responseStatusMap{ edgeResponseStatus requests }
           countryMap{ clientCountryName requests threats }
           clientHTTPVersionMap{ clientHTTPProtocol requests } }
      uniq{ uniques }
    } } } }'
V_DAILY="$(jq -n --arg z "$ZONE_ID" --arg s "$SINCE_D" --arg u "$UNTIL_D" \
            '{zone:$z, since:$s, until:$u}')"

if gql daily "$Q_DAILY" "$V_DAILY"; then
  jq -r '
    ["date","requests","cached_requests","page_views","unique_visitors",
     "threats","bytes","cached_bytes","encrypted_requests"],
    (.data.viewer.zones[0].httpRequests1dGroups[] |
      [ .dimensions.date, .sum.requests, .sum.cachedRequests, .sum.pageViews,
        .uniq.uniques, .sum.threats, .sum.bytes, .sum.cachedBytes,
        .sum.encryptedRequests ])
    | @csv' "$RAW_DIR/daily.json" > "$OUTDIR/daily_totals.csv"

  jq -r '
    ["date","status","requests"],
    (.data.viewer.zones[0].httpRequests1dGroups[] as $d
      | $d.sum.responseStatusMap[]
      | [ $d.dimensions.date, .edgeResponseStatus, .requests ])
    | @csv' "$RAW_DIR/daily.json" > "$OUTDIR/daily_status.csv"

  jq -r '
    ["date","country","requests","threats"],
    (.data.viewer.zones[0].httpRequests1dGroups[] as $d
      | $d.sum.countryMap[]
      | [ $d.dimensions.date, .clientCountryName, .requests, .threats ])
    | @csv' "$RAW_DIR/daily.json" > "$OUTDIR/daily_country.csv"

  jq -r '
    ["date","protocol","requests"],
    (.data.viewer.zones[0].httpRequests1dGroups[] as $d
      | $d.sum.clientHTTPVersionMap[]
      | [ $d.dimensions.date, .clientHTTPProtocol, .requests ])
    | @csv' "$RAW_DIR/daily.json" > "$OUTDIR/daily_protocol.csv"
fi

# ======================================================= 2. top paths (adaptive)
say "Top paths (httpRequestsAdaptiveGroups)"
Q_PATHS='query($zone:String!,$since:Time!,$until:Time!){
  viewer{ zones(filter:{zoneTag:$zone}){
    httpRequestsAdaptiveGroups(limit:200,
      filter:{datetime_geq:$since, datetime_leq:$until},
      orderBy:[count_DESC]){
      count
      dimensions{ clientRequestPath edgeResponseStatus clientRequestHTTPHost }
    } } } }'
V_T="$(jq -n --arg z "$ZONE_ID" --arg s "$SINCE_T" --arg u "$UNTIL_T" \
        '{zone:$z, since:$s, until:$u}')"

if gql paths "$Q_PATHS" "$V_T"; then
  jq -r '["host","path","status","requests"],
    (.data.viewer.zones[0].httpRequestsAdaptiveGroups[] |
      [ .dimensions.clientRequestHTTPHost, .dimensions.clientRequestPath,
        .dimensions.edgeResponseStatus, .count ])
    | @csv' "$RAW_DIR/paths.json" > "$OUTDIR/top_paths.csv"
fi

# ==================================================== 3. top client IPs + UAs
say "Top client IPs / user agents (httpRequestsAdaptiveGroups)"
Q_CLIENTS='query($zone:String!,$since:Time!,$until:Time!){
  viewer{ zones(filter:{zoneTag:$zone}){
    httpRequestsAdaptiveGroups(limit:200,
      filter:{datetime_geq:$since, datetime_leq:$until},
      orderBy:[count_DESC]){
      count
      dimensions{ clientIP clientCountryName clientRequestHTTPHost userAgentBrowser }
    } } } }'

if gql clients "$Q_CLIENTS" "$V_T"; then
  jq -r '["client_ip","country","host","ua_browser","requests"],
    (.data.viewer.zones[0].httpRequestsAdaptiveGroups[] |
      [ .dimensions.clientIP, .dimensions.clientCountryName,
        .dimensions.clientRequestHTTPHost, .dimensions.userAgentBrowser,
        .count ])
    | @csv' "$RAW_DIR/clients.json" > "$OUTDIR/top_clients.csv"
fi

# ==================================================== 4. WAF / firewall events
say "Firewall events (firewallEventsAdaptiveGroups)"
Q_FW='query($zone:String!,$since:Time!,$until:Time!){
  viewer{ zones(filter:{zoneTag:$zone}){
    firewallEventsAdaptiveGroups(limit:200,
      filter:{datetime_geq:$since, datetime_leq:$until},
      orderBy:[count_DESC]){
      count
      dimensions{ action source clientCountryName clientRequestPath }
    } } } }'

if gql firewall "$Q_FW" "$V_T"; then
  jq -r '["action","source","country","path","events"],
    (.data.viewer.zones[0].firewallEventsAdaptiveGroups[] |
      [ .dimensions.action, .dimensions.source, .dimensions.clientCountryName,
        .dimensions.clientRequestPath, .count ])
    | @csv' "$RAW_DIR/firewall.json" > "$OUTDIR/firewall_events.csv"
fi

# ================================================= 5. errors by hour (adaptive)
say "Errors by hour (httpRequestsAdaptiveGroups)"
Q_ERRHOUR='query($zone:String!,$since:Time!,$until:Time!){
  viewer{ zones(filter:{zoneTag:$zone}){
    httpRequestsAdaptiveGroups(limit:1000,
      filter:{datetime_geq:$since, datetime_leq:$until,
              edgeResponseStatus_geq:400},
      orderBy:[datetimeHour_ASC]){
      count
      dimensions{ datetimeHour edgeResponseStatus clientRequestHTTPHost
                  clientRequestPath }
    } } } }'

if gql errors_by_hour "$Q_ERRHOUR" "$V_T"; then
  jq -r '["hour","host","path","status","count"],
    (.data.viewer.zones[0].httpRequestsAdaptiveGroups[] |
      [ .dimensions.datetimeHour, .dimensions.clientRequestHTTPHost,
        .dimensions.clientRequestPath, .dimensions.edgeResponseStatus,
        .count ])
    | @csv' "$RAW_DIR/errors_by_hour.json" > "$OUTDIR/errors_by_hour.csv"
fi

# =================================================================== summary
echo
say "Wrote to $OUTDIR"
for f in "$OUTDIR"/*.csv; do
  [ -e "$f" ] || continue
  printf '    %-24s %5d rows\n' "$(basename "$f")" "$(( $(wc -l < "$f") - 1 ))"
done
echo
say "Quick look — requests per day"
if [ -f "$OUTDIR/daily_totals.csv" ]; then
  column -s, -t < "$OUTDIR/daily_totals.csv" | cut -c1-110
fi
