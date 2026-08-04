#!/usr/bin/env bash
# Restores the ICM memory database from the icm-backup branch.
#
#   icm-db-restore.sh [--list] [--force] [--commit <sha>]
#
# Decryption needs the YubiKey: the gpg encryption subkey is a card stub.
# Refuses to overwrite an existing database unless --force is given.
set -euo pipefail

DOTFILES_DIR="${HOME}/.dotfiles"
BRANCH="icm-backup"
DUMP_NAME="memories.sql.gz.gpg"
TARGET="${HOME}/.config/icm/memories.db"

list_only=0
force=0
commit=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) list_only=1 ;;
    --force) force=1 ;;
    --commit) commit="${2:?--commit needs a sha}"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

for bin in sqlite3 gpg git gzip; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: $bin not found in PATH" >&2; exit 1; }
done
cd "$DOTFILES_DIR" || { echo "ERROR: no dotfiles repo at $DOTFILES_DIR" >&2; exit 1; }

echo "--> Fetching ${BRANCH}"
if ! git fetch --quiet origin "$BRANCH" 2>/dev/null; then
  echo "ERROR: no ${BRANCH} branch on origin; nothing to restore." >&2
  exit 1
fi
tip="$(git rev-parse -q --verify "refs/remotes/origin/${BRANCH}")" \
  || { echo "ERROR: could not resolve origin/${BRANCH}" >&2; exit 1; }

if (( list_only )); then
  git log --format='%h  %ad  %s' --date=iso "$tip"
  exit 0
fi

src="${commit:-$tip}"
git cat-file -e "${src}:${DUMP_NAME}" 2>/dev/null \
  || { echo "ERROR: ${src} has no ${DUMP_NAME}" >&2; exit 1; }

if [[ -e "$TARGET" && $force -eq 0 ]]; then
  echo "ERROR: ${TARGET} already exists. Re-run with --force to replace it." >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "--> Decrypting snapshot $(git rev-parse --short "$src") (touch your YubiKey if prompted)"
git cat-file blob "${src}:${DUMP_NAME}" >"${WORK}/dump.sql.gz.gpg"
gpg --quiet --decrypt "${WORK}/dump.sql.gz.gpg" >"${WORK}/dump.sql.gz" \
  || { echo "ERROR: decryption failed (is the YubiKey inserted?)" >&2; exit 1; }

echo "--> Rebuilding database"
gzip -dc "${WORK}/dump.sql.gz" | sqlite3 "${WORK}/restored.db" \
  || { echo "ERROR: could not rebuild the database from the dump" >&2; exit 1; }
[[ "$(sqlite3 "${WORK}/restored.db" 'PRAGMA integrity_check;')" == "ok" ]] \
  || { echo "ERROR: restored database failed integrity_check" >&2; exit 1; }

# Follow an existing symlink so a stowed layout keeps pointing where it did.
dest="$TARGET"
[[ -L "$dest" ]] && dest="$(cd "$(dirname "$dest")" && cd "$(dirname "$(readlink "$dest")")" && pwd)/$(basename "$(readlink "$dest")")"
mkdir -p "$(dirname "$dest")"
if [[ -e "$dest" ]]; then
  backup="${dest}.replaced-$(date +%Y%m%d%H%M%S)"
  mv "$dest" "$backup"
  echo "--> Existing database moved to ${backup}"
fi
mv "${WORK}/restored.db" "$dest"
chmod 644 "$dest"

echo "--> Restored $(wc -c <"$dest" | tr -d ' ') bytes to ${dest}"
