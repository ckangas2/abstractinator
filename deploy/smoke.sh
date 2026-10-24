#!/usr/bin/env bash
# deploy/smoke.sh -- verify the API and MCP server actually work after a deploy.
#
# Checks CONTENT, not status codes. The /fulltext regression of 2026-10-21
# returned HTTP 200 with {"status":"failed","error":"could not find function
# strip_invisible"}, so a status-code check would have passed it. Every check
# below asserts on a field it would be impossible to return while broken.
#
#   ./deploy/smoke.sh            # local, against 127.0.0.1
#   ./deploy/smoke.sh public     # through Cloudflare, as a visitor sees it
#
# Exits non-zero on the first failure, naming the check.

set -uo pipefail

MODE="${1:-local}"
if [ "$MODE" = "public" ]; then
  API="https://abstractinator.me"       # website host; /search is not public
  MCP="https://mcp.abstractinator.me/mcp"
else
  API="http://127.0.0.1:8100"
  MCP="http://127.0.0.1:8200/mcp"
fi

# A PMCID known to be open access. If Europe PMC ever withdraws it the check
# fails loudly, which is correct -- better than silently testing nothing.
OA_PMCID="PMC13318009"

fails=0
ok   () { printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad  () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fails=$((fails+1)); }

jqcheck () {  # jqcheck <label> <json> <python expression over d>
  local label="$1" json="$2" expr="$3"
  if printf '%s' "$json" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception as e:
    sys.exit(1)
sys.exit(0 if ($expr) else 1)
" 2>/dev/null; then ok "$label"; else bad "$label"; fi
}

echo "== $MODE =="

# 1. health
H=$(curl -sS --max-time 15 "$API/health" 2>/dev/null)
jqcheck "/health reports ok" "$H" "d.get('status') == 'ok'"

# 2. search returns records with the fields the UI and agents read
S=$(curl -sS --max-time 60 "$API/search?q=listeria%20monocytogenes&limit=5&abstract_chars=0" 2>/dev/null)
jqcheck "/search returns records"        "$S" "d.get('returned', 0) > 0"
jqcheck "/search records carry fields"   "$S" "all(k in d['results'][0] for k in ('title','url','source','primary_virus'))"
jqcheck "/search reports paging state"   "$S" "'available' in d and 'has_more' in d"

# 3. full text -- the check that would have caught the strip_invisible bug
F=$(curl -sS --max-time 60 "$API/fulltext?pmcid=$OA_PMCID&max_chars=600" 2>/dev/null)
jqcheck "/fulltext succeeds"             "$F" "d.get('status') == 'success'"
jqcheck "/fulltext returns text"         "$F" "d.get('chars', 0) > 0 and len(d.get('full_text') or '') > 0"
jqcheck "/fulltext chars match string"   "$F" "d.get('chars') == len(d.get('full_text') or '')"

# 4. the MCP server lists both tools
SID=$(curl -sS --max-time 20 -D - -o /dev/null -X POST "$MCP" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}' \
  2>/dev/null | grep -i '^mcp-session-id:' | tr -d '\r' | awk '{print $2}')

if [ -z "${SID:-}" ]; then
  bad "MCP initialize returns a session id"
else
  ok "MCP initialize returns a session id"
  curl -sS --max-time 15 -o /dev/null -X POST "$MCP" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -H "mcp-session-id: $SID" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' 2>/dev/null
  T=$(curl -sS --max-time 20 -X POST "$MCP" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -H "mcp-session-id: $SID" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' 2>/dev/null)
  for tool in search_literature get_fulltext; do
    if printf '%s' "$T" | grep -q "$tool"; then ok "MCP exposes $tool"; else bad "MCP exposes $tool"; fi
  done
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "all checks passed"
else
  echo "$fails check(s) FAILED"
fi
exit "$fails"
