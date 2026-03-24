# === Homebrew ===
eval "$(/opt/homebrew/bin/brew shellenv)"
export HOMEBREW_BUNDLE_NO_LOCK=true
export PATH="/opt/homebrew/opt/grep/libexec/gnubin:$PATH"

# === Editor ===
export EDITOR=vi

# === GPG / SSH ===
export GPG_TTY=$(tty)
export SSH_AUTH_SOCK=$(gpgconf --list-dirs agent-ssh-socket)
gpgconf --launch gpg-agent

# === Node (fnm) ===
eval "$(/opt/homebrew/bin/fnm env --use-on-cd --shell zsh)"

# === Google Cloud SDK ===
if [ -f '/opt/homebrew/share/google-cloud-sdk/path.zsh.inc' ]; then . '/opt/homebrew/share/google-cloud-sdk/path.zsh.inc'; fi
if [ -f '/opt/homebrew/share/google-cloud-sdk/completion.zsh.inc' ]; then . '/opt/homebrew/share/google-cloud-sdk/completion.zsh.inc'; fi

# === OrbStack ===
source ~/.orbstack/shell/init.zsh 2>/dev/null || :

# === AI agents — sandboxed via nono ===
claude() {
  local nono_args=(--profile ai --trust-override --allow-cwd -s)
  local git_common
  git_common=$(git rev-parse --git-common-dir 2>/dev/null)
  if [[ -n "$git_common" && "$git_common" != ".git" ]]; then
    nono_args+=(--allow "$(realpath "$git_common")")
  fi
  nono run "${nono_args[@]}" -- claude "$@"
}
codex() {
  local nono_args=(--profile ai --trust-override --allow-cwd -s)
  local git_common
  git_common=$(git rev-parse --git-common-dir 2>/dev/null)
  if [[ -n "$git_common" && "$git_common" != ".git" ]]; then
    nono_args+=(--allow "$(realpath "$git_common")")
  fi
  nono run "${nono_args[@]}" -- codex "$@"
}
alias claude-raw='command claude'
alias codex-raw='command codex'
