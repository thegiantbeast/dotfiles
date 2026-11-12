# Login zsh: keep the gcloud shim ahead of the SDK binary (re-login on session expiry).
PATH="$HOME/.dotfiles/scripts/gcloud-shim:$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$HOME/.dotfiles/scripts/gcloud-shim" | paste -sd: -)"; export PATH
