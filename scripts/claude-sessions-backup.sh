#!/usr/bin/env bash
# Mirrors this machine's Claude Code transcripts (~/.claude/projects) and
# file-history to the claude-sessions branch, encrypted.
#
#   claude-sessions-backup.sh [--no-push]
#
# Runs unattended as part of scripts/claude-data-backup.sh.
# Each machine owns one folder on the branch, named in .git/claude-sessions.machine,
# and replaces it whole on every run; other machines' folders are carried over.
#
# Layout of <machine>/:
#   key.gpg            the machine's data key, encrypted to RECIPIENT
#   index.tsv.gz.gpg   <relpath> TAB <blob name> TAB <size> TAB <lines>, under the data key
#   b/<id>.gpg         one file each, gzip then the data key; <id> is a hash of
#                      the path so the public tree shows no project names
#
# The data key lives in plaintext at .git/claude-sessions.key: the backup runs
# with no YubiKey, and a restore decrypts key.gpg once instead of every file.
set -euo pipefail

no_push=0
[[ "${1:-}" == "--no-push" ]] && no_push=1

DOTFILES_DIR="${DOTFILES_DIR:-${HOME}/.dotfiles}"
CLAUDE_DIR="${CLAUDE_DIR:-${HOME}/.claude}"
SOURCES=(projects file-history)
BRANCH="claude-sessions"
RECIPIENT="${RECIPIENT:-83317FC572C176C3}"
KEEP=3
MAX_BLOB=$((95 * 1024 * 1024))
LOG="${LOG:-${HOME}/Library/Logs/claude-sessions-backup.log}"
LOCK="${TMPDIR:-/tmp}/claude-sessions-backup.lock"

mkdir -p "$(dirname "$LOG")"
if [[ -f "$LOG" ]] && (( $(wc -c <"$LOG") > 1048576 )); then
  tail -c 262144 "$LOG" >"${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi

log() { printf '%s %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*" >>"$LOG"; }
die() { log "FAILED: $*"; exit 1; }

if ! mkdir "$LOCK" 2>/dev/null; then
  if [[ -n $(find "$LOCK" -maxdepth 0 -mmin +120 2>/dev/null) ]]; then
    log "removing stale lock"
    rmdir "$LOCK" 2>/dev/null || true
    mkdir "$LOCK" 2>/dev/null || die "could not acquire lock"
  else
    log "another run holds the lock; skipping"
    exit 0
  fi
fi

WORK=""
cleanup() {
  [[ -n "$WORK" ]] && rm -rf "$WORK"
  rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT
WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-sessions.XXXXXX")" || die "could not create a working directory"

for bin in gpg git gzip shasum; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin not found in PATH"
done
cd "$DOTFILES_DIR" || die "no dotfiles repo at $DOTFILES_DIR"
GIT_DIR_ABS="$(git rev-parse --absolute-git-dir)"
KEY="${GIT_DIR_ABS}/claude-sessions.key"
CACHE="${GIT_DIR_ABS}/claude-sessions.cache"
# The branch folder name, fixed at the first run: hostnames change with the
# network, and two machines can share one.
ID_FILE="${GIT_DIR_ABS}/claude-sessions.machine"
if [[ ! -s "$ID_FILE" ]]; then
  printf '%s-%s\n' "$(hostname -s)" "$(openssl rand -hex 2)" >"$ID_FILE"
fi
MACHINE="$(cat "$ID_FILE")"

if [[ ! -s "$KEY" ]]; then
  (umask 077 && openssl rand -hex 32 >"$KEY") || die "could not create the data key"
  log "created a new data key"
fi

# OpenPGP packet tags a gpg message starts with; a gzip header is 1f8b.
is_ciphertext() {
  local head
  head="$(od -An -tx1 -N1 "$1" | tr -d ' \n')"
  [[ "$head" == "8c" || "$head" == "8d" || "$head" == "84" || "$head" == "85" || "$head" == "c3" || "$head" == "c1" ]]
}

seal() { # <plain file> <out>
  gzip -9nc "$1" | gpg --batch --yes --quiet --pinentry-mode loopback \
    --passphrase-file "$KEY" --symmetric --cipher-algo AES256 \
    --s2k-mode 3 --s2k-count 1024 --compress-algo none -o "$2" \
    || return 1
  is_ciphertext "$2"
}

stat_all() { # prints: size TAB mtime TAB path
  if stat -f '%z' / >/dev/null 2>&1; then
    find "$@" -type f ! -name .DS_Store -exec stat -f $'%z\t%m\t%N' {} +
  else
    find "$@" -type f ! -name .DS_Store -exec stat -c $'%s\t%Y\t%n' {} +
  fi
}

git fetch --quiet origin "$BRANCH" 2>/dev/null || true
remote_sha="$(git rev-parse -q --verify "refs/remotes/origin/${BRANCH}" || true)"
local_sha="$(git rev-parse -q --verify "refs/heads/${BRANCH}" || true)"
if [[ -n "$remote_sha" && "$remote_sha" != "$local_sha" ]]; then
  git update-ref "refs/heads/${BRANCH}" "$remote_sha"
  local_sha="$remote_sha"
fi

# Cache columns: relpath size mtime name blob lines
declare -A cached=()
if [[ -f "$CACHE" ]]; then
  while IFS=$'\t' read -r rel size mtime name blob lines; do
    cached["$rel"]="${size}"$'\t'"${mtime}"$'\t'"${name}"$'\t'"${blob}"$'\t'"${lines}"
  done <"$CACHE"
fi

cd "$CLAUDE_DIR" || die "no ${CLAUDE_DIR}"
present=()
for s in "${SOURCES[@]}"; do [[ -d "$s" ]] && present+=("$s"); done
(( ${#present[@]} )) || die "nothing to back up under ${CLAUDE_DIR}"

: >"${WORK}/cache.new"
: >"${WORK}/index.tsv"
: >"${WORK}/entries"
sealed=0
skipped=0
while IFS=$'\t' read -r size mtime rel; do
  rel="${rel#./}"
  prev="${cached[$rel]:-}"
  name=""; blob=""; lines=""
  if [[ -n "$prev" ]]; then
    IFS=$'\t' read -r psize pmtime pname pblob plines <<<"$prev"
    if [[ "$psize" == "$size" && "$pmtime" == "$mtime" ]] \
      && git -C "$DOTFILES_DIR" cat-file -e "$pblob" 2>/dev/null; then
      name="$pname"; blob="$pblob"; lines="$plines"
    fi
  fi
  if [[ -z "$blob" ]]; then
    name="$(printf '%s' "$rel" | shasum -a 256 | cut -c1-32).gpg"
    # Seal a copy: a live transcript can grow while gzip reads it.
    cp "$rel" "${WORK}/plain" || { log "could not read ${rel}; skipped"; continue; }
    lines="$(wc -l <"${WORK}/plain" | tr -d ' ')"
    seal "${WORK}/plain" "${WORK}/sealed" || die "encryption of ${rel} did not produce ciphertext"
    if (( $(wc -c <"${WORK}/sealed") > MAX_BLOB )); then
      log "skipped ${rel}: over GitHub's per-file limit after compression"
      skipped=$((skipped + 1))
      continue
    fi
    blob="$(git -C "$DOTFILES_DIR" hash-object -w "${WORK}/sealed")"
    sealed=$((sealed + 1))
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rel" "$size" "$mtime" "$name" "$blob" "$lines" >>"${WORK}/cache.new"
  printf '%s\t%s\t%s\t%s\n' "$rel" "$name" "$size" "$lines" >>"${WORK}/index.tsv"
  printf '100644 blob %s\t%s/b/%s\n' "$blob" "$MACHINE" "$name" >>"${WORK}/entries"
done < <(stat_all "${present[@]}" | sort -t $'\t' -k3)
cd "$DOTFILES_DIR"

if [[ -n "$local_sha" && -f "$CACHE" ]] && cmp -s "$CACHE" "${WORK}/cache.new" \
  && git cat-file -e "${local_sha}:${MACHINE}/index.tsv.gz.gpg" 2>/dev/null; then
  log "no transcript changed since ${local_sha:0:8}; nothing to do"
  exit 0
fi

seal "${WORK}/index.tsv" "${WORK}/index.gpg" || die "index encryption did not produce ciphertext"
printf '100644 blob %s\t%s/index.tsv.gz.gpg\n' "$(git hash-object -w "${WORK}/index.gpg")" "$MACHINE" >>"${WORK}/entries"

gpg --batch --yes --quiet --trust-model always --encrypt --recipient "$RECIPIENT" \
  -o "${WORK}/key.gpg" "$KEY" || die "could not encrypt the data key"
gpg --list-packets --list-only "${WORK}/key.gpg" >/dev/null 2>&1 \
  || die "encrypted data key is not a valid gpg message"
printf '100644 blob %s\t%s/key.gpg\n' "$(git hash-object -w "${WORK}/key.gpg")" "$MACHINE" >>"${WORK}/entries"

# Scratch index: the working tree, the checked-out branch and main's index
# stay untouched.
export GIT_INDEX_FILE="${WORK}/git-index"
git read-tree --empty
if [[ -n "$local_sha" ]]; then
  git ls-tree -r "$local_sha" | grep -v $'\t'"${MACHINE}/" | git update-index --index-info || true
fi
git update-index --index-info <"${WORK}/entries"
tree="$(git write-tree)"
unset GIT_INDEX_FILE

stamp="$(date +%Y-%m-%dT%H:%M:%S%z)"
msg="chore(claude): ${MACHINE} sessions backup ${stamp}"
if [[ -n "$local_sha" ]]; then
  new="$(git commit-tree "$tree" -p "$local_sha" -m "$msg")"
else
  new="$(git commit-tree "$tree" -m "$msg")"
fi
git update-ref "refs/heads/${BRANCH}" "$new"

# Encrypted blobs never delta-compress; keep the chain short.
count="$(git rev-list --count "refs/heads/${BRANCH}")"
if (( count > KEEP )); then
  keep=()
  while IFS= read -r line; do keep+=("$line"); done < <(git rev-list -n "$KEEP" "refs/heads/${BRANCH}")
  parent=""
  for (( i=${#keep[@]}-1; i>=0; i-- )); do
    c="${keep[$i]}"
    t="$(git rev-parse "${c}^{tree}")"
    m="$(git log -1 --format=%B "$c")"
    d="$(git log -1 --format=%aI "$c")"
    if [[ -z "$parent" ]]; then
      parent="$(GIT_AUTHOR_DATE="$d" GIT_COMMITTER_DATE="$d" git commit-tree "$t" -m "$m")"
    else
      parent="$(GIT_AUTHOR_DATE="$d" GIT_COMMITTER_DATE="$d" git commit-tree "$t" -p "$parent" -m "$m")"
    fi
  done
  git update-ref "refs/heads/${BRANCH}" "$parent"
  log "pruned branch from ${count} to ${KEEP} snapshots"
fi

if (( no_push )); then
  mv "${WORK}/cache.new" "$CACHE"
  log "--no-push: sealed ${sealed}, skipped ${skipped}; local ${BRANCH} at $(git rev-parse --short "refs/heads/${BRANCH}")"
  exit 0
fi

push_url="$(git config --get remote.origin.url)"
push_url="${push_url/#git@github.com:/https://github.com/}"
if [[ -n "$remote_sha" ]]; then
  git push --quiet \
    --force-with-lease="refs/heads/${BRANCH}:${remote_sha}" \
    "$push_url" "refs/heads/${BRANCH}:refs/heads/${BRANCH}" \
    || die "push rejected (gh not authenticated, or another machine pushed first; the next run retries)"
else
  git push --quiet "$push_url" "refs/heads/${BRANCH}:refs/heads/${BRANCH}" \
    || die "push failed while creating ${BRANCH} (gh not authenticated?)"
fi
git update-ref "refs/remotes/origin/${BRANCH}" "refs/heads/${BRANCH}"
mv "${WORK}/cache.new" "$CACHE"

log "sealed ${sealed}, skipped ${skipped}; ${MACHINE} at $(git rev-parse --short "refs/heads/${BRANCH}")"
