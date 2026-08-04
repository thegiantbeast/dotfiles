#!/usr/bin/env bash
# Snapshots the ICM memory database to the icm-backup branch, encrypted.
#
# Runs unattended from ~/Library/LaunchAgents/eu.ricardoferreira.icm-db-backup.plist.
# The snapshot is gpg-encrypted before git sees it, so the blob is ciphertext
# regardless of branch or .gitattributes state.
set -euo pipefail

no_push=0
[[ "${1:-}" == "--no-push" ]] && no_push=1

DOTFILES_DIR="${HOME}/.dotfiles"
DB="${HOME}/.config/icm/memories.db"
BRANCH="icm-backup"
RECIPIENT="83317FC572C176C3"
KEEP=20
DUMP_NAME="memories.sql.gz.gpg"
SUM_NAME="memories.sha256"
LOG="${HOME}/Library/Logs/icm-db-backup.log"
LOCK="${TMPDIR:-/tmp}/icm-db-backup.lock"

mkdir -p "$(dirname "$LOG")"
# Keep the log from growing without bound.
if [[ -f "$LOG" ]] && (( $(wc -c <"$LOG") > 1048576 )); then
  tail -c 262144 "$LOG" >"${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi

log() { printf '%s %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*" >>"$LOG"; }
die() { log "FAILED: $*"; exit 1; }

# Single instance: a stale lock from a killed run must not wedge the job forever.
if ! mkdir "$LOCK" 2>/dev/null; then
  if [[ -n $(find "$LOCK" -maxdepth 0 -mmin +60 2>/dev/null) ]]; then
    log "removing stale lock"
    rmdir "$LOCK" 2>/dev/null || true
    mkdir "$LOCK" 2>/dev/null || die "could not acquire lock"
  else
    log "another run holds the lock; skipping"
    exit 0
  fi
fi

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; rmdir "$LOCK" 2>/dev/null || true; }
trap cleanup EXIT

for bin in sqlite3 gpg git gzip; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin not found in PATH"
done
[[ -f "$DB" ]] || die "no database at $DB"
cd "$DOTFILES_DIR" || die "no dotfiles repo at $DOTFILES_DIR"

# VACUUM INTO takes a consistent snapshot including WAL content, without
# mutating or locking out the live database.
sqlite3 "$DB" "VACUUM INTO '${WORK}/snapshot.db'" \
  || die "could not snapshot the database"
[[ "$(sqlite3 "${WORK}/snapshot.db" 'PRAGMA integrity_check;')" == "ok" ]] \
  || die "snapshot failed integrity_check; refusing to back up a corrupt database"

sqlite3 "${WORK}/snapshot.db" .dump >"${WORK}/dump.sql" \
  || die "could not dump the snapshot"
# Checksum the plain dump, never the gzip: gzip stores an mtime in its header,
# so its bytes differ on every run and would defeat the unchanged check below.
sum="$(shasum -a 256 <"${WORK}/dump.sql" | awk '{print $1}')"
gzip -9n <"${WORK}/dump.sql" >"${WORK}/dump.sql.gz" || die "could not compress the dump"
rm -f "${WORK}/dump.sql"

git fetch --quiet origin "$BRANCH" 2>/dev/null || true
remote_sha="$(git rev-parse -q --verify "refs/remotes/origin/${BRANCH}" || true)"
local_sha="$(git rev-parse -q --verify "refs/heads/${BRANCH}" || true)"
# The remote is the source of truth: another machine may have pushed since.
if [[ -n "$remote_sha" && "$remote_sha" != "$local_sha" ]]; then
  git update-ref "refs/heads/${BRANCH}" "$remote_sha"
  local_sha="$remote_sha"
fi

# Compare plaintext checksums; ciphertext differs on every run even for
# identical input, so it cannot be used to detect "no change".
if [[ -n "$local_sha" ]]; then
  prev_sum="$(git show "${local_sha}:${SUM_NAME}" 2>/dev/null || true)"
  if [[ "$prev_sum" == "$sum" ]]; then
    log "database unchanged since ${local_sha:0:8}; nothing to do"
    exit 0
  fi
fi

gpg --batch --yes --trust-model always --encrypt --recipient "$RECIPIENT" \
  -o "${WORK}/${DUMP_NAME}" "${WORK}/dump.sql.gz" \
  || die "gpg encryption failed"

# Never push this file unless it is genuinely ciphertext.
gpg --list-packets "${WORK}/${DUMP_NAME}" >/dev/null 2>&1 \
  || die "encrypted output is not a valid gpg message"
if [[ "$(od -An -tx1 -N2 "${WORK}/${DUMP_NAME}" | tr -d ' \n')" == "1f8b" ]]; then
  die "encrypted output still looks like gzip; refusing to push plaintext"
fi

printf '%s\n' "$sum" >"${WORK}/${SUM_NAME}"

# Commit via plumbing against a scratch index so the working tree, the
# checked-out branch and main's index are all left untouched. hash-object
# without --path deliberately bypasses filters: the blob is already encrypted.
stamp="$(date +%Y-%m-%dT%H:%M:%S%z)"
export GIT_INDEX_FILE="${WORK}/index"
git read-tree --empty
for f in "$DUMP_NAME" "$SUM_NAME"; do
  blob="$(git hash-object -w "${WORK}/${f}")"
  git update-index --add --cacheinfo "100644,${blob},${f}"
done
tree="$(git write-tree)"
unset GIT_INDEX_FILE

msg="chore(icm): memory db backup ${stamp}"
if [[ -n "$local_sha" ]]; then
  new="$(git -c commit.gpgsign=false commit-tree "$tree" -p "$local_sha" -m "$msg")"
else
  new="$(git -c commit.gpgsign=false commit-tree "$tree" -m "$msg")"
fi
git update-ref "refs/heads/${BRANCH}" "$new"

# Retain only the newest KEEP snapshots; encrypted blobs never delta-compress,
# so an unbounded chain would grow the repo by a full snapshot every run.
count="$(git rev-list --count "refs/heads/${BRANCH}")"
if (( count > KEEP )); then
  # Read into an array without mapfile: launchd's PATH can resolve to bash 3.2.
  keep=()
  while IFS= read -r line; do keep+=("$line"); done < <(git rev-list -n "$KEEP" "refs/heads/${BRANCH}")
  parent=""
  for (( i=${#keep[@]}-1; i>=0; i-- )); do
    c="${keep[$i]}"
    t="$(git rev-parse "${c}^{tree}")"
    m="$(git log -1 --format=%B "$c")"
    d="$(git log -1 --format=%aI "$c")"
    if [[ -z "$parent" ]]; then
      parent="$(GIT_AUTHOR_DATE="$d" GIT_COMMITTER_DATE="$d" \
        git -c commit.gpgsign=false commit-tree "$t" -m "$m")"
    else
      parent="$(GIT_AUTHOR_DATE="$d" GIT_COMMITTER_DATE="$d" \
        git -c commit.gpgsign=false commit-tree "$t" -p "$parent" -m "$m")"
    fi
  done
  git update-ref "refs/heads/${BRANCH}" "$parent"
  log "pruned branch from ${count} to ${KEEP} snapshots"
fi

if (( no_push )); then
  log "--no-push: local ${BRANCH} is at $(git rev-parse --short "refs/heads/${BRANCH}"), not pushed"
  exit 0
fi

# Pruning rewrites the chain, so the push is necessarily non-fast-forward.
# force-with-lease still refuses to clobber a remote we have not seen.
if [[ -n "$remote_sha" ]]; then
  git push --quiet \
    --force-with-lease="refs/heads/${BRANCH}:${remote_sha}" \
    origin "refs/heads/${BRANCH}:refs/heads/${BRANCH}" \
    || die "push rejected (YubiKey absent, or remote moved unexpectedly)"
else
  git push --quiet origin "refs/heads/${BRANCH}:refs/heads/${BRANCH}" \
    || die "push failed while creating ${BRANCH} (YubiKey absent?)"
fi

log "backed up $(wc -c <"${WORK}/${DUMP_NAME}" | tr -d ' ') bytes as $(git rev-parse --short "refs/heads/${BRANCH}")"
