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
} >> "$LOG" 2>&1

tail -n 2000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
