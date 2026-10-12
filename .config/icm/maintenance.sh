#!/bin/bash
# Weekly ICM health report. Report-only: never deletes or consolidates.
set -u
export PATH="/opt/homebrew/bin:/usr/bin:/bin"

LOG="$HOME/Library/Logs/icm-maintenance.log"
DB="$HOME/.config/icm/memories.db"

{
  echo "=== icm maintenance $(date '+%F %T') ==="
  icm health
  echo ""
  echo "--- prune candidates (dry-run, threshold 0.15) ---"
  echo "--- weight measures access, not value: rescue keepers with 'icm update' before any real prune ---"
  icm prune --dry-run --threshold 0.15
  echo ""
  echo "--- topics due for consolidation (>10 entries, no new entry for 14 days) ---"
  sqlite3 -separator ' | ' "$DB" \
    "SELECT topic, count(*), substr(max(created_at),1,10) FROM memories \
     GROUP BY topic HAVING count(*) > 10 AND max(created_at) < datetime('now','-14 days')"
  echo ""
  echo "--- drift from the ICM write rules (taxonomy entry in conventions/icm) ---"
  echo "topics outside the taxonomy:"
  sqlite3 -separator ' | ' "$DB" \
    "SELECT topic, count(*) FROM memories \
     WHERE topic <> 'parking-lot' \
       AND topic NOT GLOB 'conventions/*' AND topic NOT GLOB 'projects/*' \
       AND topic NOT GLOB 'investigations/*' AND topic NOT GLOB 'architecture/*' \
       AND topic NOT GLOB 'homelab/*' AND topic NOT GLOB 'reference/*' \
     GROUP BY topic ORDER BY 2 DESC"
  echo "entries over 1500 chars (one subject, ~1200 max):"
  sqlite3 -separator ' | ' "$DB" \
    "SELECT topic, length(summary), substr(summary,1,70) FROM memories \
     WHERE topic <> 'parking-lot' AND length(summary) > 1500 ORDER BY 2 DESC LIMIT 20"
  echo "critical entries (target 15-20, standing rules only): $(sqlite3 "$DB" "SELECT count(*) FROM memories WHERE importance='critical'")"
  echo "parking-lot items older than 30 days:"
  sqlite3 -separator ' | ' "$DB" \
    "SELECT substr(created_at,1,10), substr(summary,1,80) FROM memories \
     WHERE topic='parking-lot' AND created_at < datetime('now','-30 days') ORDER BY created_at"
  echo ""
} >> "$LOG" 2>&1

tail -n 2000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
