#!/bin/bash
# Delete search, agent and feedback logs older than 24 months: the retention
# period stated on www/privacy.html. Logs are one folder per day, named
# YYYY-MM-DD, under .cache/s3_mimic/{logs,feedback}/ (R/log_utils_local.R,
# agent/mcp_server.py, app/server/help_feedback.R). Run daily from cron.
set -u
ROOT=${1:-/srv/shiny-server/abstractinator}
CUTOFF=$(date -d "24 months ago" +%Y-%m-%d)
n=0
for base in "$ROOT/.cache/s3_mimic/logs" "$ROOT/.cache/s3_mimic/feedback"; do
  [ -d "$base" ] || continue
  for d in "$base"/????-??-??; do
    [ -d "$d" ] || continue
    day=$(basename "$d")
    if [[ "$day" < "$CUTOFF" ]]; then rm -rf -- "$d"; n=$((n+1)); fi
  done
done
echo "$(date -Is) prune_logs: removed $n day folder(s) older than $CUTOFF"
