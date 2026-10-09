#!/usr/bin/env bash
# Disk usage audit for macOS. Report only: this script never deletes anything.
#
# Part 1 finds where the space is without any prior knowledge of the layout:
# one `du -a` pass per scan root keeps every file and directory at or above
# --min, and renders them as a size-sorted tree (Disk Inventory X style). Each
# node shows its children largest first, then one line for everything smaller
# than --min. Part 2 adds meaning to the heavy nodes: VM images, package and
# IDE caches, git worktrees, node_modules, .terraform, build output, with a
# risk level and the exact command that reclaims each one. Part 3 is the
# ranked candidates table.
#
# Usage:
#   disk-audit.sh [--min 300M] [--depth 8] [--kids 25] [--top 12] [--root DIR]...
#                 [--quick] [--fetch] [--code-root DIR] [--no-color]
#
#   --min SIZE     smallest node the tree shows (K/M/G suffix; default 300M)
#   --depth N      maximum tree depth below a root (default 8)
#   --kids N       children shown per tree node (default 25)
#   --split-min S  budget: split a node only when it is at least this big (default 10G)
#   --split-frac P budget: ...and its largest child is at least P% of it (default 30)
#   --bucket-min S budget: pool lines smaller than this into one (default 1G)
#   --top N        rows per table in the known-location sections (default 12)
#   --root DIR     scan root, repeatable (default: $HOME /Applications /Library
#                  /opt /private/var/folders /private/var/db /private/var/log
#                  /Users/Shared /System/Volumes/Data/System)
#   --quick        skip the code-root and git-worktree sections
#   --fetch        git fetch --prune before the merged check (network; refs move)
#   --code-root    root of code checkouts (default ~/Code)
#
# Risk levels: SAFE = regenerated on demand, REVIEW = look at the list first,
# DECISION = your data or a VM. Output also lands in ~/Library/Logs/disk-audit/.
#
# Adding knowledge: tag_for() maps a path pattern to a short label in the tree;
# known_cache() and the section_* functions register reclaim candidates with
# `cand <kb> <risk> "<label>" "<command>"`.
#
# Requires bash >= 4 (brew install bash).
set -uo pipefail

MIN=300M
DEPTH=8
TOP=12
KIDS=25
SPLIT_MIN=10G
SPLIT_FRAC=30
BUCKET_MIN=1G
QUICK=0
FETCH=0
COLOR=1
CODE_ROOT="${HOME}/Code"
ROOTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --min) MIN="$2"; shift ;;
    --depth) DEPTH="$2"; shift ;;
    --top) TOP="$2"; shift ;;
    --kids) KIDS="$2"; shift ;;
    --split-min) SPLIT_MIN="$2"; shift ;;
    --split-frac) SPLIT_FRAC="$2"; shift ;;
    --bucket-min) BUCKET_MIN="$2"; shift ;;
    --root) ROOTS+=("$2"); shift ;;
    --quick) QUICK=1 ;;
    --fetch) FETCH=1 ;;
    --code-root) CODE_ROOT="$2"; shift ;;
    --no-color) COLOR=0 ;;
    -h|--help) sed -n "2,37p" "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -t 1 ]] || COLOR=0
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  echo "bash >= 4 needed (brew install bash), found ${BASH_VERSION}" >&2; exit 2
fi
[[ ${#ROOTS[@]} -eq 0 ]] && ROOTS=("$HOME" /Applications /Library /opt /private/var/folders /private/var/db /private/var/log /Users/Shared /System/Volumes/Data/System)

# size string -> KB
to_kb() {
  local v=${1^^}
  case "$v" in
    *G) awk -v n="${v%G}" 'BEGIN{printf "%d", n*1048576}' ;;
    *M) awk -v n="${v%M}" 'BEGIN{printf "%d", n*1024}' ;;
    *K) echo "${v%K}" ;;
    *) echo "$v" ;;
  esac
}
MIN_KB=$(to_kb "$MIN")

LOG_DIR="${HOME}/Library/Logs/disk-audit"
mkdir -p "$LOG_DIR"
REPORT="${LOG_DIR}/$(date +%Y-%m-%d_%H%M%S).txt"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/disk-audit.XXXXXX")"
CAND_FILE="$WORK/candidates.tsv"; : > "$CAND_FILE"
HEAVY="$WORK/heavy.tsv"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- helpers ---

c() { if [[ $COLOR -eq 1 ]]; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }
h1() { printf '\n%s\n' "$(c '1;36' "== $* ==")"; }
h2() { printf '\n%s\n' "$(c '1' "-- $* --")"; }
note() { printf '%s\n' "$(c '2' "   $*")"; }

hr() { # KB -> human readable
  local kb=${1:-0}
  if (( kb >= 1048576 )); then awk -v k="$kb" 'BEGIN{printf "%.1fG", k/1048576}'
  elif (( kb >= 1024 )); then awk -v k="$kb" 'BEGIN{printf "%.0fM", k/1024}'
  else printf '%dK' "$kb"; fi
}

kb() { # allocated KB of paths, same filesystem only
  local total=0 s
  for p in "$@"; do
    [[ -e "$p" ]] || continue
    s=$(du -sxk "$p" 2>/dev/null | cut -f1); total=$(( total + ${s:-0} ))
  done
  echo "$total"
}
apparent_kb() { stat -f %z "$1" 2>/dev/null | awk '{printf "%d", $1/1024}'; }
short() { printf '%s' "${1/#$HOME/~}"; }

top_table() { # top_table <n> <path...>
  local n=$1; shift
  local paths=()
  for p in "$@"; do [[ -e "$p" ]] && paths+=("$p"); done
  [[ ${#paths[@]} -eq 0 ]] && { note "(none)"; return; }
  du -sxk "${paths[@]}" 2>/dev/null | sort -rn | head -n "$n" \
    | while IFS=$'\t' read -r size path; do printf '  %8s  %s\n' "$(hr "$size")" "$(short "$path")"; done
}

cand() { # cand <kb> <SAFE|REVIEW|DECISION> <label> <command>
  (( $1 < 51200 )) && return
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$CAND_FILE"
}

known_cache() { # known_cache <path> <risk> <label> <command>
  local path=$1 risk=$2 label=$3 cmd=$4 size
  [[ -e "$path" ]] || return
  size=$(kb "$path")
  printf '  %8s  %-10s %s\n' "$(hr "$size")" "$risk" "$label"
  cand "$size" "$risk" "$label" "$cmd"
}

# tag_for <path> -> short meaning label for the tree (empty if unknown)
tag_for() {
  local p=$1
  case "$p" in
    */node_modules|*/node_modules/*) echo "npm deps, reinstall" ;;
    */.terraform|*/.terraform/*) echo "tf providers, terraform init recreates" ;;
    *.raw|*.qcow2|*.vmdk|*.vdi|*.utm|*.utm/*|*/VM/*|*.img) echo "VM disk image" ;;
    */.bare|*/.bare/*|*/.git|*/.git/*) echo "git objects" ;;
    */Library/Caches|*/Library/Caches/*|*/.cache/*|*/.npm/_cacache*|*/.npm/_npx*) echo "cache" ;;
    */CachedExtensionVSIXs*|*/ShipIt*|*updater*|*Updater*) echo "installer/update leftovers" ;;
    */.vscode/extensions/*) echo "editor extension" ;;
    */Downloads/*) echo "download" ;;
    */Application\ Support/*) echo "app data" ;;
    */Containers/*|*/Group\ Containers/*) echo "sandboxed app data" ;;
    */.pm2/*) echo "pm2 logs" ;;
    *.log|*.log.[0-9]*) echo "log" ;;
    *.iso|*.dmg|*.pkg) echo "installer image" ;;
    *.sql|*.dump|*.sql.gz) echo "db dump" ;;
    *.zip|*.tar|*.tar.gz|*.tgz|*.7z) echo "archive" ;;
    */dist|*/build|*/coverage|*/.next|*/.turbo|*/exported) echo "build/export output" ;;
    /Applications/*.app) echo "app bundle" ;;
    /opt/homebrew/Cellar/*) echo "brew formula" ;;
    /private/var/db/diagnostics*|/private/var/db/uuidtext*) echo "unified log store (sudo log erase --all)" ;;
    /private/var/vm*) echo "swap, leave alone" ;;
    */Library/Mail/*) echo "mail store" ;;
    */Library/Developer/CoreSimulator*) echo "iOS simulators" ;;
  esac
}

git_default_remote_branch() {
  local ref
  ref=$(git -C "$1" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)
  if [[ -n "$ref" ]]; then echo "$ref"; return; fi
  for b in origin/master origin/main; do
    git -C "$1" rev-parse -q --verify "$b" >/dev/null 2>&1 && { echo "$b"; return; }
  done
  echo ""
}

# --------------------------------------------------------- part 1: where ---

section_overview() {
  h1 "Overview  $(date '+%Y-%m-%d %H:%M')  $(hostname -s)"
  df -h /System/Volumes/Data 2>/dev/null | awk 'NR==1 || /Data/ {print "  " $0}'
  h2 "Local APFS snapshots (OS updates hold space until they expire)"
  tmutil listlocalsnapshots / 2>/dev/null | sed 's/^/  /' || note "(tmutil unavailable)"
  note "sizes: sudo diskutil apfs listSnapshots /System/Volumes/Data"
}

# One du -a pass per root; keep nodes >= MIN_KB; sorted largest first.
scan_heavy() {
  : > "$HEAVY"
  local r
  for r in "${ROOTS[@]}"; do
    [[ -e "$r" ]] || continue
    du -xak "$r" 2>/dev/null | awk -v min="$MIN_KB" -F'\t' '$1 >= min' >> "$HEAVY"
  done
  sort -t$'\t' -k1,1rn -o "$HEAVY" "$HEAVY"
}

section_drilldown() {
  h1 "Where the space is: every node >= $MIN, largest first (roots: ${ROOTS[*]/#$HOME/~})"
  note "indent = depth; (+N more) = further children >= $MIN not shown; (rest) = everything smaller than $MIN"
  # awk emits: depth \t kb \t kind \t path \t display    kind: N node, M more, R rest
  # A node with a single heavy child and nothing else above --min is folded
  # into that child ("a/b/c"), so one-directory chains take one line.
  awk -F'\t' -v kidsmax="$KIDS" -v maxdepth="$DEPTH" -v min="$MIN_KB" '
    function base(p) { sub(/.*\//, "", p); return p }
    function pr(p, d, display,   i, n, arr, sum, shown, more, rest, k) {
      n = split(substr(kids[p], 2), arr, "\n")
      while (n == 1 && size[p] - size[arr[1]] < min) {
        p = arr[1]; display = display "/" base(p)
        n = split(substr(kids[p], 2), arr, "\n")
      }
      printf "%d\t%d\tN\t%s\t%s\n", d, size[p], p, display
      if (d >= maxdepth) return
      sum = 0; shown = 0; more = 0
      for (i = 1; i <= n; i++) {
        k = arr[i]; sum += size[k]
        if (shown < kidsmax) { pr(k, d + 1, base(k)); shown++ } else more += size[k]
      }
      if (more > 0) printf "%d\t%d\tM\t-\t(+%d more)\n", d + 1, more, n - shown
      rest = size[p] - sum
      if (rest >= min && n > 0) printf "%d\t%d\tR\t-\t(rest)\n", d + 1, rest
    }
    { size[$2] = $1; order[++N] = $2 }
    END {
      for (i = 1; i <= N; i++) {
        p = order[i]; par = p; sub(/\/[^\/]*$/, "", par); if (par == "") par = "/"
        if (par in size) kids[par] = kids[par] "\n" p; else roots[++nr] = p
      }
      for (i = 1; i <= nr; i++) pr(roots[i], 0, roots[i])
    }' "$HEAVY" > "$WORK/tree.tsv"
  local rootkb=1 depth size kind path display indent name pct10 pct tag
  while IFS=$'\t' read -r depth size kind path display; do
    indent=$(printf '%*s' $((depth * 2)) '')
    if [[ $depth -eq 0 ]]; then rootkb=$size; printf '\n'; fi
    pct10=$(( size * 1000 / rootkb )); pct=$(( pct10 / 10 )).$(( pct10 % 10 ))
    case $kind in
      N)
        if [[ $depth -eq 0 ]]; then name=$(short "$display"); else name=$display; fi
        [[ -d "$path" ]] && name="$name/"
        tag=$(tag_for "$path"); [[ -n "$tag" ]] && tag="  $(c 2 "[$tag]")"
        [[ $depth -eq 0 ]] && name=$(c '1' "$name")
        printf '%8s %5s%%  %s%s%s\n' "$(hr "$size")" "$pct" "$indent" "$name" "$tag" ;;
      M|R) printf '%8s %5s%%  %s%s\n' "$(hr "$size")" "$pct" "$indent" "$(c 2 "$display")" ;;
    esac
  done < "$WORK/tree.tsv"
}

# Container accounting from diskutil (bytes); falls back to df when unavailable.
container_numbers() {
  local info; info=$(diskutil info /System/Volumes/Data 2>/dev/null)
  CONT_TOTAL_KB=$(echo "$info" | awk -F'[()]' '/Container Total Space/ {gsub(/ Bytes/,"",$2); printf "%d", $2/1024}')
  CONT_FREE_KB=$(echo "$info"  | awk -F'[()]' '/Container Free Space/  {gsub(/ Bytes/,"",$2); printf "%d", $2/1024}')
  DATA_USED_KB=$(echo "$info"  | awk -F'[()]' '/Volume Used Space/     {gsub(/ Bytes/,"",$2); printf "%d", $2/1024}')
  OTHER_VOL_KB=$(diskutil apfs list 2>/dev/null | awk '
    /APFS Volume Disk/ { role=$0 }
    /Capacity Consumed/ { if (role !~ /\(Data\)/) s += $4 }
    END { printf "%d", s/1024 }')
  if [[ -z "$CONT_TOTAL_KB" || "$CONT_TOTAL_KB" -eq 0 ]]; then
    read -r CONT_TOTAL_KB DATA_USED_KB CONT_FREE_KB < <(df -k /System/Volumes/Data | awk 'NR==2 {print $2, $3, $4}')
    OTHER_VOL_KB=$(( CONT_TOTAL_KB - DATA_USED_KB - CONT_FREE_KB ))
  fi
}

# The budget answers "where does the disk go" in a few lines that add up.
# A node is split into its children only when it is large (--split-min), one
# child dominates it (--split-frac percent), and it is not an app-level dir.
# Buckets under --bucket-min are pooled into one "everything else" line.
section_budget() {
  container_numbers
  h1 "Budget: where the $(hr "$CONT_TOTAL_KB") disk goes"
  local atomic='/(Application Support|Group Containers|Containers|Caches|Developer|Cellar|Caskroom)/[^/]+$|\.app$|/node_modules$|\.(utm|pvm|vm)$'
  awk -F'\t' -v min="$MIN_KB" -v splitmin="$(to_kb "$SPLIT_MIN")" -v frac="$SPLIT_FRAC" \
      -v bmin="$(to_kb "$BUCKET_MIN")" -v atomic="$atomic" '
    function budget(p,   n, arr, i, rest, big) {
      n = split(substr(kids[p], 2), arr, "\n")
      while (n == 1 && size[p] - size[arr[1]] < min && p !~ atomic) { p = arr[1]; n = split(substr(kids[p], 2), arr, "\n") }
      big = (n > 0) ? size[arr[1]] : 0
      if (size[p] >= splitmin && n >= 2 && big * 100 >= frac * size[p] && p !~ atomic) {
        rest = size[p]
        for (i = 1; i <= n; i++) { rest -= size[arr[i]]; budget(arr[i]) }
        if (rest >= bmin) printf "%d\tR\t%s\n", rest, p; else other += rest
      } else if (size[p] >= bmin) printf "%d\tB\t%s\n", size[p], p
      else other += size[p]
    }
    { size[$2] = $1; order[++N] = $2 }
    END {
      for (i = 1; i <= N; i++) {
        p = order[i]; par = p; sub(/\/[^\/]*$/, "", par); if (par == "") par = "/"
        if (par in size) kids[par] = kids[par] "\n" p; else roots[++nr] = p
      }
      for (i = 1; i <= nr; i++) { budget(roots[i]); scanned += size[roots[i]] }
      printf "%d\tO\t(everything else under the scan roots, below %s)\n", other, "bucket-min"
      printf "%d\tS\tscanned\n", scanned
    }' "$HEAVY" > "$WORK/budget.tsv"
  local scanned; scanned=$(awk -F'\t' '$2=="S"{print $1}' "$WORK/budget.tsv")
  local unscanned=$(( DATA_USED_KB - scanned )); (( unscanned < 0 )) && unscanned=0
  grep -v $'\tS\t' "$WORK/budget.tsv" > "$WORK/rows.tsv"
  printf '%d\tX\tData volume outside the scan roots (Spotlight index, fseventsd, root-only dirs)\n' "$unscanned" >> "$WORK/rows.tsv"
  printf '%d\tV\tOther APFS volumes: macOS system, Preboot, Recovery, swap\n' "$OTHER_VOL_KB" >> "$WORK/rows.tsv"
  printf '%d\tF\tFree\n' "$CONT_FREE_KB" >> "$WORK/rows.tsv"
  # The rows must add up to the container. Whatever they miss is APFS metadata,
  # chain folding below --min, and the rounding of each printed line.
  local rowsum gap
  rowsum=$(awk -F'\t' '{s += $1} END {printf "%d", s}' "$WORK/rows.tsv")
  gap=$(( CONT_TOTAL_KB - rowsum ))
  if (( gap > 0 )); then
    printf '%d\tU\tUnaccounted: APFS metadata, per-line rounding, paths below the scan floor\n' "$gap" >> "$WORK/rows.tsv"
  elif (( gap < 0 )); then
    printf '%d\tU\tOvercount: rows exceed the container by this much (report a bug)\n' "$(( -gap ))" >> "$WORK/rows.tsv"
  fi
  sort -t$'\t' -k1,1rn "$WORK/rows.tsv" | while IFS=$'\t' read -r size kind path; do
    local pct10 label tag=""
    pct10=$(( size * 1000 / CONT_TOTAL_KB ))
    case $kind in
      B) label=$(short "$path"); [[ -d "$path" ]] && label="$label/"; tag=$(tag_for "$path") ;;
      R) label="$(short "$path")/ (rest, after the lines split out of it)" ;;
      *) label=$path ;;
    esac
    [[ -n "$tag" ]] && tag="  $(c 2 "[$tag]")"
    printf '%8s %5s%%  %s%s\n' "$(hr "$size")" "$(( pct10 / 10 )).$(( pct10 % 10 ))" "$label" "$tag"
  done
  printf '%8s %5s   container total (rows above add up to this)\n' "$(hr "$CONT_TOTAL_KB")" "100.0%"
  note "split rule: node >= $SPLIT_MIN, largest child >= ${SPLIT_FRAC}% of it, not an app-level dir; buckets < $BUCKET_MIN pooled"
}

# The macOS Storage panel sorts files into categories of its own. "Documents"
# is its catch-all for user files it cannot put anywhere else, so it grows to
# roughly the size of the home folder. These are the real paths behind it.
section_home_categories() {
  h1 "What the macOS Storage panel calls your categories"
  local home_kb; home_kb=$(kb "$HOME")
  printf '  %8s  home folder total\n' "$(hr "$home_kb")"
  note "the panel's 'Documents' is a catch-all and tracks this number, not ~/Documents"
  note "its figures are cached: reopen System Settings > General > Storage to refresh"
  h2 "Split of the home folder"
  local d s
  for d in Code Library Downloads Desktop Documents Movies Music Pictures Public; do
    [[ -d "$HOME/$d" ]] || continue
    s=$(kb "$HOME/$d")
    (( s < 51200 )) && continue
    printf '  %8s  ~/%s\n' "$(hr "$s")" "$d"
  done
  local dot=0
  while IFS=$'\t' read -r s d; do dot=$(( dot + s )); done < <(du -sxk "$HOME"/.[!.]* 2>/dev/null)
  printf '  %8s  dotfiles and dot-directories in ~\n' "$(hr "$dot")"
  h2 "The panel's own categories, and where they actually live"
  printf '  %-16s %s\n' "Applications" "/Applications plus ~/Applications"
  printf '  %-16s %s\n' "Documents" "catch-all for user files: ~/Code, VM images, archives, anything large"
  printf '  %-16s %s\n' "System Data" "~/Library, caches, logs, sleep image, Spotlight index"
  printf '  %-16s %s\n' "Mail / Photos" "~/Library/Mail, ~/Pictures/Photos Library.photoslibrary"
  printf '  %-16s %s\n' "macOS" "the sealed system volume, read-only, not reclaimable"
  note "the panel double counts and lags; trust the budget above instead"
}

section_big_files() {
  h1 "Largest single files >= $MIN"
  local n=0
  while IFS=$'\t' read -r size path; do
    [[ -f "$path" ]] || continue
    printf '  %8s  %s  %s\n' "$(hr "$size")" "$(stat -f '%Sm' -t '%Y-%m-%d' "$path")" "$(short "$path")"
    n=$((n + 1)); (( n >= TOP * 2 )) && break
  done < "$HEAVY"
  (( n == 0 )) && note "(none)"
}

# --------------------------------------------------------- part 2: what ---

section_vms() {
  h1 "VM and container disk images"
  local f size
  f="$HOME/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data/data.img.raw"
  if [[ -f "$f" ]]; then
    size=$(kb "$f")
    printf '  %8s  OrbStack data.img.raw (allocated; apparent %s, sparse: shrinks when data inside is deleted)\n' \
      "$(hr "$size")" "$(hr "$(apparent_kb "$f")")"
    if pgrep -qf 'OrbStack.app' 2>/dev/null; then
      docker system df 2>/dev/null | sed 's/^/    /'; orb list 2>/dev/null | sed 's/^/    /'
    else
      note "OrbStack not running: start it, then 'docker system df' and 'orb list' show what is inside"
    fi
    cand "$size" DECISION "OrbStack images/volumes/machines (inspect with docker system df first)" \
      "docker system prune -a --volumes   # and 'orb delete <machine>' for unused Linux machines"
  fi
  f="$HOME/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
  if [[ -f "$f" ]]; then
    size=$(kb "$f"); printf '  %8s  Docker Desktop Docker.raw\n' "$(hr "$size")"
    cand "$size" DECISION "Docker Desktop images/volumes" "docker system prune -a --volumes"
  fi
  for f in "$HOME"/Library/Containers/com.utmapp.UTM/Data/Documents/*.utm; do
    [[ -d "$f" ]] || continue
    size=$(kb "$f"); printf '  %8s  UTM VM %s\n' "$(hr "$size")" "$(basename "$f")"
    cand "$size" DECISION "UTM VM $(basename "$f")" "delete it inside UTM, or: rm -rf '$f'"
  done
  f="$HOME/Library/Application Support/Try Omarchy"
  if [[ -d "$f" ]]; then
    size=$(kb "$f" "/Applications/Try Omarchy.app")
    printf '  %8s  Try Omarchy VM + app\n' "$(hr "$size")"
    cand "$size" DECISION "Try Omarchy VM + app" "rm -rf '$f' '/Applications/Try Omarchy.app'"
  fi
  for f in "$HOME"/Parallels/*.pvm "$HOME/VirtualBox VMs"/* "$HOME"/.lima/* "$HOME"/.colima/*; do
    [[ -e "$f" ]] || continue
    size=$(kb "$f"); printf '  %8s  %s\n' "$(hr "$size")" "$(short "$f")"
    cand "$size" DECISION "VM $(short "$f")" "review in its app"
  done
}

section_dev_caches() {
  h1 "Package, tool and app caches (known locations)"
  if command -v brew >/dev/null; then
    local bkb; bkb=$(kb "$(brew --cache 2>/dev/null)")
    printf '  %8s  %-10s Homebrew cache (downloads, old bottles)\n' "$(hr "$bkb")" SAFE
    brew cleanup -n --prune=all 2>/dev/null | grep -i 'would free' | sed 's/^/    /'
    cand "$bkb" SAFE "Homebrew downloads + outdated kegs" "brew cleanup --prune=all"
  fi
  local AS="$HOME/Library/Application Support"
  known_cache "$HOME/.npm/_cacache"   SAFE "npm cache"                 "npm cache clean --force"
  known_cache "$HOME/.npm/_npx"       SAFE "npx package cache"         "rm -rf $HOME/.npm/_npx"
  known_cache "$HOME/Library/pnpm/store" SAFE "pnpm store"             "pnpm store prune"
  known_cache "$HOME/.local/share/pnpm/store" SAFE "pnpm store"        "pnpm store prune"
  known_cache "$HOME/Library/Caches/Yarn" SAFE "yarn cache"            "yarn cache clean"
  known_cache "$HOME/Library/Caches/pip" SAFE "pip cache"              "pip cache purge"
  known_cache "$HOME/.cache/uv"       SAFE "uv cache"                  "uv cache clean"
  known_cache "$HOME/.cargo/registry" SAFE "cargo registry"            "rm -rf $HOME/.cargo/registry"
  known_cache "$HOME/go/pkg/mod"      SAFE "go module cache"           "go clean -modcache"
  known_cache "$HOME/.gradle/caches"  SAFE "gradle caches"             "rm -rf $HOME/.gradle/caches"
  known_cache "$HOME/.m2/repository"  REVIEW "maven repository"        "rm -rf $HOME/.m2/repository"
  known_cache "$HOME/.cache/puppeteer" SAFE "puppeteer browsers"       "rm -rf $HOME/.cache/puppeteer"
  known_cache "$HOME/Library/Caches/ms-playwright" SAFE "playwright browsers (all versions)" \
    "npx playwright uninstall --all   # then 'npx playwright install' inside the project that needs it"
  known_cache "$HOME/Library/Caches/node-gyp" SAFE "node-gyp headers"  "rm -rf $HOME/Library/Caches/node-gyp"
  known_cache "$HOME/Library/Caches/typescript" SAFE "typescript cache" "rm -rf $HOME/Library/Caches/typescript"
  known_cache "$HOME/.cache/prisma"   SAFE "prisma engines"            "rm -rf $HOME/.cache/prisma"
  known_cache "$HOME/Library/Caches/CocoaPods" SAFE "cocoapods cache"  "pod cache clean --all"
  known_cache "$HOME/Library/Developer/Xcode/DerivedData" SAFE "Xcode DerivedData" \
    "rm -rf $HOME/Library/Developer/Xcode/DerivedData"
  known_cache "$HOME/Library/Developer/Xcode/Archives" REVIEW "Xcode Archives" "review in Xcode Organizer"
  known_cache "$HOME/Library/Developer/Xcode/iOS DeviceSupport" SAFE "Xcode iOS DeviceSupport" \
    "rm -rf '$HOME/Library/Developer/Xcode/iOS DeviceSupport'"
  known_cache "$HOME/Library/Developer/CoreSimulator/Devices" REVIEW "iOS simulators" \
    "xcrun simctl delete unavailable   # or 'xcrun simctl delete all'"
  known_cache "$HOME/.pm2/logs"       SAFE "pm2 logs"                  "pm2 flush"
  known_cache "$HOME/.pm2/pm2.log"    SAFE "pm2 daemon log"            ": > $HOME/.pm2/pm2.log"
  known_cache "$HOME/Library/Caches/com.spotify.client" SAFE "Spotify cache" \
    "Spotify > Settings > Storage > Clear cache, then lower the cache limit"
  known_cache "$AS/Google/Chrome/OptGuideOnDeviceModel" REVIEW \
    "Chrome on-device AI model (re-downloads while the feature is on)" \
    "chrome://components > 'Optimization Guide On Device Model' remove; or disable in chrome://flags"
  known_cache "$AS/Google/GoogleUpdater/crx_cache" SAFE "Google Updater crx cache" \
    "rm -rf '$AS/Google/GoogleUpdater/crx_cache'"
  known_cache "$HOME/Library/Caches/com.microsoft.VSCode.ShipIt" SAFE "VS Code update downloads" \
    "rm -rf $HOME/Library/Caches/com.microsoft.VSCode.ShipIt"
  known_cache "$HOME/Library/Caches/loom-updater" SAFE "Loom update downloads" "rm -rf $HOME/Library/Caches/loom-updater"
  known_cache "$HOME/.Trash"          SAFE "Trash"                     "Finder > Empty Trash"
  h2 "Other ~/Library/Caches entries (browsers rebuild theirs; leave unless desperate)"
  top_table "$TOP" "$HOME"/Library/Caches/*
}

section_vscode() {
  local ext="$HOME/.vscode/extensions" AS="$HOME/Library/Application Support/Code"
  [[ -d "$ext" ]] || return
  h1 "VS Code"
  known_cache "$AS/CachedExtensionVSIXs" SAFE "VS Code cached extension VSIX files" "rm -rf '$AS/CachedExtensionVSIXs'"
  known_cache "$AS/Cache" SAFE "VS Code HTTP cache" "rm -rf '$AS/Cache' '$AS/CachedData'"
  known_cache "$AS/logs" SAFE "VS Code logs" "rm -rf '$AS/logs'"
  h2 "Extensions installed in more than one version (older copies are leftovers)"
  local dup_total=0 dup_dirs=()
  while read -r id; do
    [[ -z "$id" ]] && continue
    local versions n newest
    versions=$(ls -d "$ext/$id"-[0-9]*/ 2>/dev/null | sed 's:/$::' | sort -V)
    n=$(echo "$versions" | wc -l | tr -d ' '); (( n < 2 )) && continue
    newest=$(echo "$versions" | tail -n1)
    printf '  %s  keep: %s\n' "$id" "$(basename "$newest")"
    while read -r v; do
      [[ "$v" == "$newest" ]] && continue
      local s; s=$(kb "$v")
      printf '  %8s    old: %s\n' "$(hr "$s")" "$(basename "$v")"
      dup_total=$(( dup_total + s )); dup_dirs+=("$v")
    done <<< "$versions"
  done < <(ls "$ext" | sed -E 's/-[0-9]+\.[0-9]+\.[0-9]+.*$//' | sort | uniq -d)
  (( dup_total > 0 )) && cand "$dup_total" SAFE "VS Code old extension versions (${#dup_dirs[@]} dirs)" \
    "rm -rf $(printf "'%s' " "${dup_dirs[@]}")"
  note "extensions dir total: $(hr "$(kb "$ext")")"
}

section_downloads() {
  h1 "Downloads: files over 100M"
  local total=0
  while IFS= read -r -d '' f; do
    local s; s=$(kb "$f"); total=$(( total + s ))
    printf '  %8s  %s  %s\n' "$(hr "$s")" "$(stat -f '%Sm' -t '%Y-%m-%d' "$f")" "$(basename "$f")"
  done < <(find "$HOME/Downloads" -maxdepth 2 -type f -size +100M -print0 2>/dev/null)
  (( total > 0 )) && cand "$total" DECISION "Large files in ~/Downloads" "review the list in the Downloads section"
  (( total == 0 )) && note "(none)"
}

section_code() {
  [[ -d "$CODE_ROOT" ]] || return
  h1 "Code root $(short "$CODE_ROOT")"
  h2 "node_modules"
  local nm_total=0 nm_count=0 s p
  while IFS=$'\t' read -r s p; do nm_total=$(( nm_total + s )); nm_count=$(( nm_count + 1 )); done \
    < <(find "$CODE_ROOT" -xdev -type d -name node_modules -prune -print0 2>/dev/null | xargs -0 du -sxk 2>/dev/null)
  printf '  %8s  in %d directories\n' "$(hr "$nm_total")" "$nm_count"
  cand "$nm_total" REVIEW "node_modules under $(short "$CODE_ROOT") ($nm_count dirs; reinstall per project)" \
    "find $CODE_ROOT -type d -name node_modules -prune -exec rm -rf {} +   # or only inside stale worktrees"
  h2 ".terraform provider dirs"
  local tf_total=0 tf_count=0
  while IFS=$'\t' read -r s p; do tf_total=$(( tf_total + s )); tf_count=$(( tf_count + 1 )); done \
    < <(find "$CODE_ROOT" -xdev -type d -name node_modules -prune -o -type d -name .terraform -print0 2>/dev/null | xargs -0 du -sxk 2>/dev/null)
  printf '  %8s  in %d directories\n' "$(hr "$tf_total")" "$tf_count"
  (( tf_count > 1 )) && note "TF_PLUGIN_CACHE_DIR=\$HOME/.terraform.d/plugin-cache makes providers download once and hard-link"
  cand "$tf_total" SAFE ".terraform dirs ($tf_count; 'terraform init' recreates them)" \
    "find $CODE_ROOT -type d -name .terraform -prune -exec rm -rf {} +"
  h2 "Build output dirs (dist, build, coverage, .next, .turbo, test-results)"
  find "$CODE_ROOT" -xdev -type d \( -name node_modules -o -name .git -o -name .terraform \) -prune -o \
    -type d \( -name dist -o -name build -o -name coverage -o -name .next -o -name .turbo -o -name test-results -o -name playwright-report \) -print0 2>/dev/null \
    | xargs -0 du -sxk 2>/dev/null | sort -rn | head -n "$TOP" \
    | while IFS=$'\t' read -r s p; do printf '  %8s  %s\n' "$(hr "$s")" "$(short "$p")"; done
}

section_worktrees() {
  [[ -d "$CODE_ROOT" ]] || return
  h1 "Git worktrees (repos with more than one checkout under $(short "$CODE_ROOT"))"
  local bare
  while IFS= read -r -d '' bare; do
    local repo_dir n base; repo_dir=$(dirname "$bare")
    n=$(git -C "$bare" worktree list --porcelain 2>/dev/null | grep -c '^worktree ')
    (( n < 2 )) && continue
    h2 "$(short "$repo_dir")  ($((n-1)) worktrees, objects $(hr "$(kb "$bare/objects")"))"
    [[ $FETCH -eq 1 ]] && git -C "$bare" fetch --prune --quiet origin 2>/dev/null
    base=$(git_default_remote_branch "$bare")
    if [[ -z "$base" ]]; then note "no origin/master or origin/main ref: merged check skipped"
    else note "merged = HEAD is an ancestor of $base (local ref dated $(git -C "$bare" log -1 --format=%cs "$base" 2>/dev/null)); --fetch refreshes it"; fi
    local removable_kb=0 removable=() wt
    printf '  %8s %8s %8s  %-10s %-6s %-5s %s\n' total node_mod other last dirty mergd worktree
    while read -r wt; do
      [[ -d "$wt" && "$wt" != "$bare" ]] || continue
      local total nm=0 other last dirty merged branch mark s p
      total=$(kb "$wt")
      while IFS=$'\t' read -r s p; do nm=$(( nm + s )); done \
        < <(find "$wt" -type d -name node_modules -prune -print0 2>/dev/null | xargs -0 du -sxk 2>/dev/null)
      other=$(( total - nm ))
      last=$(git -C "$wt" log -1 --format=%cs 2>/dev/null)
      dirty=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
      branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)
      merged="-"
      if [[ -n "$base" ]]; then
        if git -C "$wt" merge-base --is-ancestor HEAD "$base" 2>/dev/null; then merged=yes; else merged=no; fi
      fi
      mark=""
      if [[ "$merged" == yes && "$branch" != master && "$branch" != main ]]; then
        if [[ "$dirty" == 0 ]]; then mark="  <- removable"; removable_kb=$(( removable_kb + total )); removable+=("$(basename "$wt")")
        else mark="  <- merged, but $dirty uncommitted paths"; fi
      fi
      printf '  %8s %8s %8s  %-10s %-6s %-5s %s (%s)%s\n' \
        "$(hr "$total")" "$(hr "$nm")" "$(hr "$other")" "$last" "$dirty" "$merged" "$(basename "$wt")" "$branch" "$mark"
    done < <(git -C "$bare" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}' \
             | while read -r p; do echo "$(kb "$p")"$'\t'"$p"; done | sort -rn | cut -f2)
    if (( ${#removable[@]} > 0 )); then
      cand "$removable_kb" REVIEW "merged + clean worktrees in $(short "$repo_dir"): ${removable[*]}" \
        "cd '$bare' && for w in ${removable[*]}; do git worktree remove \"\$w\"; done"
    fi
    local sample; sample=$(git -C "$bare" worktree list --porcelain | awk '/^worktree /{print $2}' | sed -n 2p)
    if [[ -d "$sample" ]]; then
      h2 "Heaviest tracked paths in one checkout ($(basename "$sample")): every worktree pays these"
      git -C "$sample" ls-files -z 2>/dev/null | xargs -0 du -sk 2>/dev/null \
        | awk -F'\t' '{split($2,a,"/"); k=a[1]; if (a[2]!="") k=a[1]"/"a[2]; s[k]+=$1} END{for(k in s) printf "%d\t%s\n", s[k], k}' \
        | sort -rn | head -5 | while IFS=$'\t' read -r s p; do printf '  %8s  %s\n' "$(hr "$s")" "$p"; done
      note "drop a heavy tracked dir from a worktree: git sparse-checkout set --no-cone '/*' '!<dir>'"
    fi
  done < <(find "$CODE_ROOT" -maxdepth 4 -type d \( -name .bare -o -name .git \) -prune -print0 2>/dev/null)
}

# ------------------------------------------------------ part 3: candidates ---

section_summary() {
  h1 "Reclaim candidates, largest first (nothing was deleted)"
  [[ -s "$CAND_FILE" ]] || { note "(none over 50M)"; return; }
  sort -t$'\t' -k1,1rn "$CAND_FILE" | while IFS=$'\t' read -r size risk label cmd; do
    local col; case $risk in SAFE) col=32;; REVIEW) col=33;; *) col=31;; esac
    printf '  %8s  %-9s %s\n' "$(hr "$size")" "$(c $col "$risk")" "$label"
    printf '            %s\n' "$(c 2 "$cmd")"
  done
  local safe=0 review=0 decision=0 size risk label cmd
  while IFS=$'\t' read -r size risk label cmd; do
    case $risk in SAFE) safe=$((safe+size));; REVIEW) review=$((review+size));; DECISION) decision=$((decision+size));; esac
  done < "$CAND_FILE"
  printf '\n  SAFE %s   REVIEW %s   DECISION %s   (sums overlap where one item contains another)\n' \
    "$(hr $safe)" "$(hr $review)" "$(hr $decision)"
  printf '\n  report saved: %s\n' "$(short "$REPORT")"
  local prev; prev=$(ls -1 "$LOG_DIR"/*.txt 2>/dev/null | grep -v "$(basename "$REPORT")" | tail -n1)
  [[ -n "$prev" ]] && printf '  previous:     %s\n' "$(short "$prev")"
}

main() {
  section_overview
  local t0=$SECONDS
  scan_heavy
  note "scanned ${ROOTS[*]/#$HOME/~} in $((SECONDS - t0))s, $(wc -l < "$HEAVY" | tr -d " ") nodes >= $MIN"
  section_budget
  section_home_categories
  section_drilldown
  section_big_files
  section_vms
  section_dev_caches
  section_vscode
  section_downloads
  if [[ $QUICK -eq 0 ]]; then section_code; section_worktrees; else h1 "Code root and worktrees skipped (--quick)"; fi
  section_summary
}
main 2>&1 | tee "$REPORT"
