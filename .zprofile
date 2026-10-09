# Login zsh: /etc/zprofile runs path_helper after .zshenv and puts /opt/homebrew/bin first again.
# ~/.dotfiles/scripts/gcloud-shim/gcloud must shadow the SDK binary (re-login on session expiry).
PATH="$HOME/.dotfiles/scripts/gcloud-shim:$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$HOME/.dotfiles/scripts/gcloud-shim" | paste -sd: -)"; export PATH
