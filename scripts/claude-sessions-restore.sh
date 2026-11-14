#!/usr/bin/env bash
# Restores Claude Code transcripts and file-history from the claude-sessions
# branch into ~/.claude, mapping another machine's paths onto this one.
#
#   claude-sessions-restore.sh --list
#   claude-sessions-restore.sh [--from <machine>] [--map OLD=NEW]... [--dry-run] [--force]
#
# --map rewrites a path prefix, e.g. --map /Users/alice/Code=/home/alice/code.
# It renames the project folders (Claude Code names them after the encoded
# working directory, which `claude --resume` looks up) and rewrites the same
# prefix inside .json and .jsonl files. The longest OLD wins; repeat as needed.
#
# A local .jsonl is replaced only when the backup's copy has more lines
# (transcripts only grow); any other local file is kept. --force replaces all.
# Decrypting the data key needs the YubiKey; DATA_KEY_FILE=<path> uses a
# plaintext data key instead.
set -euo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-${HOME}/.dotfiles}"
CLAUDE_DIR="${CLAUDE_DIR:-${HOME}/.claude}"
BRANCH="claude-sessions"
SELF="$(cat "$(git -C "$DOTFILES_DIR" rev-parse --absolute-git-dir)/claude-sessions.machine" 2>/dev/null || true)"

list_only=0; dry=0; force=0; from=""
maps=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) list_only=1 ;;
    --dry-run) dry=1 ;;
    --force) force=1 ;;
    --from) from="${2:?--from needs a machine name}"; shift ;;
    --map) [[ "${2:-}" == *=* ]] || { echo "--map needs OLD=NEW" >&2; exit 2; }; maps+=("$2"); shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

for bin in gpg git gzip perl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: $bin not found in PATH" >&2; exit 1; }
done
cd "$DOTFILES_DIR"

echo "--> Fetching ${BRANCH}"
git fetch --quiet origin "$BRANCH" 2>/dev/null \
  || { echo "ERROR: no ${BRANCH} branch on origin; nothing to restore." >&2; exit 1; }
tip="$(git rev-parse --verify "refs/remotes/origin/${BRANCH}")"

machines=()
while IFS= read -r m; do machines+=("$m"); done < <(git ls-tree --name-only "$tip")

if (( list_only )); then
  git log -1 --format='tip %h  %ad' --date=iso "$tip"
  for m in "${machines[@]}"; do
    n="$(git ls-tree "$tip" "${m}/b/" | wc -l | tr -d ' ')"
    printf '  %s  (%s files)%s\n' "$m" "$n" "$([[ "$m" == "$SELF" ]] && echo '  <- this machine')"
  done
  exit 0
fi

if [[ -z "$from" ]]; then
  others=()
  for m in "${machines[@]}"; do [[ "$m" != "$SELF" ]] && others+=("$m"); done
  (( ${#others[@]} == 1 )) || { echo "ERROR: pick a machine with --from (see --list)" >&2; exit 1; }
  from="${others[0]}"
fi
git cat-file -e "${tip}:${from}/key.gpg" 2>/dev/null || { echo "ERROR: no backup for ${from}" >&2; exit 1; }

# Claude Code's project folder name: every character outside [A-Za-z0-9] becomes '-'.
encode() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }

olds=(); news=()
while IFS= read -r pair; do
  [[ -n "$pair" ]] || continue
  olds+=("${pair%%=*}"); news+=("${pair#*=}")
done < <(for p in "${maps[@]+"${maps[@]}"}"; do printf '%d\t%s\n' "${#p}" "$p"; done | sort -rn | cut -f2-)

map_rel() { # projects/<encoded dir>/rest -> the same under the mapped dir
  local rel="$1" dir rest i eo
  [[ "$rel" == projects/* ]] || { printf '%s' "$rel"; return; }
  dir="${rel#projects/}"; rest="${dir#*/}"; dir="${dir%%/*}"
  [[ "$rest" == "$dir" ]] && rest=""
  for i in "${!olds[@]}"; do
    eo="$(encode "${olds[$i]}")"
    if [[ "$dir" == "$eo" || "$dir" == "$eo"-* ]]; then
      dir="$(encode "${news[$i]}")${dir#"$eo"}"
      break
    fi
  done
  printf 'projects/%s%s' "$dir" "${rest:+/$rest}"
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-sessions.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
umask 077

if [[ -n "${DATA_KEY_FILE:-}" ]]; then
  cp "$DATA_KEY_FILE" "${WORK}/key"
else
  echo "--> Decrypting the data key of ${from} (touch your YubiKey if prompted)"
  git cat-file blob "${tip}:${from}/key.gpg" | gpg --quiet --decrypt >"${WORK}/key" \
    || { echo "ERROR: decryption failed (is the YubiKey inserted?)" >&2; exit 1; }
fi

open_blob() { # <blob spec> -> stdout
  git cat-file blob "$1" | gpg --batch --quiet --pinentry-mode loopback \
    --passphrase-file "${WORK}/key" --decrypt | gzip -dc
}

open_blob "${tip}:${from}/index.tsv.gz.gpg" >"${WORK}/index.tsv"


restored=0; kept=0
while IFS=$'\t' read -r rel name size lines; do
  dest_rel="$(map_rel "$rel")"
  dest="${CLAUDE_DIR}/${dest_rel}"
  if [[ -e "$dest" && $force -eq 0 ]]; then
    if [[ "$dest_rel" != *.jsonl ]] || (( $(wc -l <"$dest") >= lines )); then
      kept=$((kept + 1)); continue
    fi
  fi
  if (( dry )); then
    echo "  would restore ${dest_rel}"; restored=$((restored + 1)); continue
  fi
  mkdir -p "$(dirname "$dest")"
  open_blob "${tip}:${from}/b/${name}" >"${WORK}/plain"
  if (( ${#olds[@]} )) && [[ "$dest_rel" == *.json || "$dest_rel" == *.jsonl ]]; then
    for i in "${!olds[@]}"; do
      O="${olds[$i]}" N="${news[$i]}" perl -pi -e 's/\Q$ENV{O}\E/$ENV{N}/g' "${WORK}/plain"
    done
  fi
  mv "${WORK}/plain" "$dest"
  restored=$((restored + 1))
done <"${WORK}/index.tsv"

echo "--> ${from}: $( (( dry )) && echo 'would restore' || echo 'restored') ${restored}; kept ${kept} local copies that were current"
