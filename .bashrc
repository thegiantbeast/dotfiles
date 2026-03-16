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
eval "$(/opt/homebrew/bin/fnm env --use-on-cd --shell bash)"

# === Google Cloud SDK ===
if [ -f '/opt/homebrew/share/google-cloud-sdk/path.bash.inc' ]; then . '/opt/homebrew/share/google-cloud-sdk/path.bash.inc'; fi
if [ -f '/opt/homebrew/share/google-cloud-sdk/completion.bash.inc' ]; then . '/opt/homebrew/share/google-cloud-sdk/completion.bash.inc'; fi

# === OrbStack ===
source ~/.orbstack/shell/init.bash 2>/dev/null || :
