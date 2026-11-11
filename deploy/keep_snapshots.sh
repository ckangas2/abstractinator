#!/bin/bash
# Copy the trial snapshot database aside after each weekly snapshot.
#
# It is the only state that can't be rebuilt: ClinicalTrials.gov serves today's
# record, not last week's, so a lost snapshot database loses the history behind
# the change feed. Everything else (evidence, the built registry database, the
# web pages) is re-derivable from the registry TSVs and the APIs.
#
# Keeps the newest KEEP copies, as a cheap backup on the same machine; run it
# from cron right after tracker/snapshot_trials.py. Copies are compressed and
# named by date, so a week's copy is written once however often this runs.
set -u
KEEP=8
DATA="${ABSTRACTINATOR_DATA_DIR:-/var/lib/abstractinator}"
DEST="${ABSTRACTINATOR_SNAPSHOT_BACKUPS:-$DATA/backups}"
DB="$DATA/trial_snapshots/trials.sqlite"

[ -r "$DB" ] || { echo "keep_snapshots: no $DB yet, nothing to copy"; exit 0; }
mkdir -p "$DEST" || exit 1
OUT="$DEST/trials-$(date +%F).sqlite.gz"
if [ -e "$OUT" ]; then
  echo "keep_snapshots: $OUT already exists, leaving it alone"
else
  TMP="$OUT.part"
  # .backup, not cp: a consistent copy even if something is mid-write.
  if /usr/bin/sqlite3 "file:$DB?mode=ro" ".backup '$TMP.sqlite'" 2>/dev/null; then
    gzip -c "$TMP.sqlite" > "$TMP" && mv "$TMP" "$OUT"
    rm -f "$TMP.sqlite"
  else
    gzip -c "$DB" > "$TMP" && mv "$TMP" "$OUT"     # no sqlite3 binary: plain copy
  fi
  rm -f "$TMP" "$TMP.sqlite"
  echo "keep_snapshots: wrote $OUT ($(du -h "$OUT" 2>/dev/null | cut -f1))"
fi
# Oldest first, delete all but the newest KEEP.
ls -1 "$DEST"/trials-*.sqlite.gz 2>/dev/null | sort | head -n -"$KEEP" | while read -r old; do
  rm -f "$old" && echo "keep_snapshots: removed old copy $(basename "$old")"
done
exit 0
