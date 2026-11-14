#!/usr/bin/env bash
# Runs every Claude data backup in turn. A part that fails never stops the
# next one; the exit status is non-zero when any part failed.
#
#   claude-data-backup.sh [--no-push]
#
# Runs unattended from ~/Library/LaunchAgents/eu.ricardoferreira.claude-data-backup.plist.
# Each part keeps its own log under ~/Library/Logs; a new backup is one more
# entry in PARTS.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARTS=(
  icm-db-backup.sh
  claude-sessions-backup.sh
)

failed=0
for part in "${PARTS[@]}"; do
  if ! "$BASH" "${DIR}/${part}" "$@"; then
    printf '%s %s failed; see its log\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$part" >&2
    failed=1
  fi
done
exit "$failed"
