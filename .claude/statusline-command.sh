#!/bin/bash
# gruvbox_dark powerline statusline mirroring ~/.config/starship.toml (dir / git / time)

input=$(cat)
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd')

FG0="251;241;199"
YELLOW="215;153;33"
AQUA="104;157;106"
BG1="60;56;54"
SEP=$(printf '\xee\x82\xb0')          # powerline arrow U+E0B0
GIT_ICON=$(printf '\xee\x82\xa0')     # branch glyph U+E0A0

fg() { printf '\033[38;2;%sm' "$1"; }
bg() { printf '\033[48;2;%sm' "$1"; }
rst() { printf '\033[0m'; }

dir_display=$(printf '%s' "$cwd" | awk -F/ '{
  n=0
  for (i=1;i<=NF;i++) if ($i!="") parts[++n]=$i
  if (n>3) printf "…/%s/%s/%s", parts[n-2], parts[n-1], parts[n]
  else { out=""; for (i=1;i<=n;i++) out=out "/" parts[i]; printf "%s", (out==""?"/":out) }
}')

bg "$YELLOW"; fg "$FG0"
printf ' %s ' "$dir_display"

git_branch=""
if git -C "$cwd" --no-optional-locks rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git_branch=$(git -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null)
  [ -z "$git_branch" ] && git_branch=$(git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
fi

last_bg="$YELLOW"
if [ -n "$git_branch" ]; then
  fg "$YELLOW"; bg "$AQUA"; printf '%s' "$SEP"

  status=""
  [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ] && status=" ✗"
  counts=$(git -C "$cwd" --no-optional-locks rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null)
  if [ -n "$counts" ]; then
    behind=$(echo "$counts" | awk '{print $1}')
    ahead=$(echo "$counts" | awk '{print $2}')
    [ "${ahead:-0}" -gt 0 ] 2>/dev/null && status="$status ↑$ahead"
    [ "${behind:-0}" -gt 0 ] 2>/dev/null && status="$status ↓$behind"
  fi

  bg "$AQUA"; fg "$FG0"
  printf ' %s %s%s ' "$GIT_ICON" "$git_branch" "$status"
  last_bg="$AQUA"
fi

fg "$last_bg"; bg "$BG1"; printf '%s' "$SEP"
bg "$BG1"; fg "$FG0"
printf ' %s ' "$(date +%H:%M)"

rst; fg "$BG1"; printf '%s' "$SEP"
rst
