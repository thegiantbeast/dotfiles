# === Homebrew ===
eval "$(/opt/homebrew/bin/brew shellenv)"
export HOMEBREW_BUNDLE_NO_LOCK=true
export PATH="/opt/homebrew/opt/grep/libexec/gnubin:$PATH"

# === Editor ===
export EDITOR=vi

# === Node (fnm) ===
# Only init if not already set up by a parent shell — avoids piling up
# orphaned symlinks in ~/.local/state/fnm_multishells/ for every subshell.
if [ -z "$FNM_MULTISHELL_PATH" ] || [ ! -d "$FNM_MULTISHELL_PATH" ]; then
  eval "$(/opt/homebrew/bin/fnm env --use-on-cd --shell zsh)"
fi

# === Google Cloud SDK (PATH only — completion is interactive) ===
if [ -f '/opt/homebrew/share/google-cloud-sdk/path.zsh.inc' ]; then . '/opt/homebrew/share/google-cloud-sdk/path.zsh.inc'; fi

# Make non-interactive bash subshells (e.g. `bash -c '...'` from agents)
# load ~/.bashrc so they inherit Homebrew/fnm/etc.
export BASH_ENV="$HOME/.bashrc"

# Stop here for non-interactive shells — everything below is for humans.
[[ -o interactive ]] || return 0

# === GPG / SSH ===
export GPG_TTY=$(tty)
export SSH_AUTH_SOCK=$(gpgconf --list-dirs agent-ssh-socket)
gpgconf --launch gpg-agent

# === Google Cloud SDK completion ===
if [ -f '/opt/homebrew/share/google-cloud-sdk/completion.zsh.inc' ]; then . '/opt/homebrew/share/google-cloud-sdk/completion.zsh.inc'; fi

# === OrbStack ===
source ~/.orbstack/shell/init.zsh 2>/dev/null || :

# === AI agents — sandboxed via nono ===
claude() {
  local nono_args=(--profile claude --trust-override --allow-cwd -s)
  local git_common
  git_common=$(git rev-parse --git-common-dir 2>/dev/null)
  if [[ -n "$git_common" && "$git_common" != ".git" ]]; then
    nono_args+=(--allow "$(realpath "$git_common")")
  fi
  nono run "${nono_args[@]}" -- claude "$@"
}
codex() {
  local nono_args=(--profile codex --trust-override --allow-cwd -s)
  local git_common
  git_common=$(git rev-parse --git-common-dir 2>/dev/null)
  if [[ -n "$git_common" && "$git_common" != ".git" ]]; then
    nono_args+=(--allow "$(realpath "$git_common")")
  fi
  nono run "${nono_args[@]}" -- codex "$@"
}
alias claude-raw='command claude'
alias codex-raw='command codex'
