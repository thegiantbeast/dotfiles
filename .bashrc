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
  eval "$(/opt/homebrew/bin/fnm env --use-on-cd --shell bash)"
fi

# === Google Cloud SDK (PATH only — completion is interactive) ===
if [ -f '/opt/homebrew/share/google-cloud-sdk/path.bash.inc' ]; then . '/opt/homebrew/share/google-cloud-sdk/path.bash.inc'; fi

# Make non-interactive bash subshells (e.g. `bash -c '...'` from agents)
# also load this file so they inherit Homebrew/fnm/etc.
export BASH_ENV="$HOME/.bashrc"

# Stop here for non-interactive shells — everything below is for humans.
case $- in *i*) ;; *) return 0 ;; esac

# === GPG / SSH ===
export GPG_TTY=$(tty)
export SSH_AUTH_SOCK=$(gpgconf --list-dirs agent-ssh-socket)
gpgconf --launch gpg-agent

# === Google Cloud SDK completion ===
if [ -f '/opt/homebrew/share/google-cloud-sdk/completion.bash.inc' ]; then . '/opt/homebrew/share/google-cloud-sdk/completion.bash.inc'; fi

# === OrbStack ===
source ~/.orbstack/shell/init.bash 2>/dev/null || :

